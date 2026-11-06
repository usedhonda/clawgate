import Foundation

/// Explicitly finish a selected integration. Destination ledgers own retries;
/// no source record is hidden until both exact superseded receipts are durable.
enum MeetingMinutesIntegrationFinalization {
    enum Failure: Error, LocalizedError {
        case generationRequired, changed, deliveryPending
        var errorDescription: String? {
            switch self {
            case .generationRequired: return "選んだ保存版から議事録を生成してから、まとめてください"
            case .changed: return "議事録または統合資料が変わりました。現在の版を確認してください"
            case .deliveryPending: return "両方の配信先で保存を確認できていません。元の会議は一覧に残しています"
            }
        }
    }
    struct Plan {
        let selection: MeetingMinutesIntegrationSelection
        let target: MeetingMinutesPublication.SupersededBy
        let targetPayloadSHA256: String
        var sources: [MeetingMinutesIntegrationSelection.Source] {
            selection.sources.filter { $0.record.id != selection.targetMeetingID }
        }
    }

    static func prepare(targetID: String, store: MeetingStore) throws -> Plan {
        guard let selection = try MeetingMinutesIntegrationSelection.load(targetID: targetID, store: store),
              let targetRecord = store.load(id: targetID), targetRecord.minutesState == "ready",
              let job = MeetingMinutesJob.load(store: store, id: targetID),
              job.completed.count == job.envelopes.count, !job.envelopes.isEmpty,
              let accepted = store.loadAcceptedMinutes(id: targetID),
              accepted.fingerprint == job.fingerprint else { throw Failure.generationRequired }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let selectionHash = MeetingMinutesPublication.digest(try encoder.encode(selection))
        guard job.envelopes.allSatisfy({ $0.integrationSelectionFingerprint == selectionHash }) else {
            throw Failure.generationRequired
        }
        for source in selection.sources where source.record.id != targetID {
            guard let current = store.load(id: source.record.id), current.minutesState != "pending",
                  current.mergedIntoMeetingID == nil || current.mergedIntoMeetingID == targetID else {
                throw Failure.changed
            }
            let file = source.authority == "accepted" ? "minutes-accepted.json" : "minutes.json"
            let bytes = try Data(contentsOf: store.directory(for: source.record.id).appendingPathComponent(file))
            guard MeetingMinutesPublication.digest(bytes) == source.revision else { throw Failure.changed }
        }
        let data = try Data(contentsOf: store.directory(for: targetID).appendingPathComponent("minutes-accepted.json"))
        let snapshot = try MeetingMinutesKnowledgeSnapshot(acceptedData: data, record: targetRecord)
        return Plan(selection: selection, target: .init(sourceUUID: selection.sourceUUID,
            meetingID: targetID, outputRevision: snapshot.outputRevision),
            targetPayloadSHA256: MeetingMinutesPublication.digest(try encoder.encode(snapshot)))
    }

    private static func ledger(_ plan: Plan, store: MeetingStore, hub: Bool) throws -> MeetingMinutesKnowledgeOutbox {
        let result = try MeetingMinutesKnowledgeOutbox(store: store,
            maxMetadataBytes: MeetingMinutesHubPublisher.maxMetadataBytes,
            directoryName: hub ? "knowledge-outbox-hub" : "knowledge-outbox",
            sourceUUID: plan.target.sourceUUID, compactsWhenStored: hub)
        guard result.sourceUUID == plan.target.sourceUUID else { throw Failure.changed }
        return result
    }

    static func requireTargetReceipts(_ plan: Plan, store: MeetingStore) throws {
        for hub in [false, true] {
            guard let head = try ledger(plan, store: store, hub: hub).head(meetingID: plan.target.meetingID),
                  head.operation == .upsert, head.supersededBy == nil,
                  head.outputRevision == plan.target.outputRevision,
                  head.payloadSHA256 == plan.targetPayloadSHA256,
                  head.receipt?.isCurrent == true,
                  head.receipt?.status == .searchable || hub && head.receipt?.status == .stored else {
                throw Failure.deliveryPending
            }
        }
    }

    static func finish(targetID: String, store: MeetingStore,
                       primary: MeetingMinutesPublisher, hub: MeetingMinutesHubPublisher) async throws {
        let plan = try prepare(targetID: targetID, store: store)
        try requireTargetReceipts(plan, store: store)
        // Historical-only sources are enrolled only by this explicit selection.
        for source in plan.sources {
            try await primary.acceptSelectedSource(source)
            try await hub.acceptSelectedSource(source)
        }
        for source in plan.sources {
            let fresh = try prepare(targetID: targetID, store: store)
            guard fresh.target == plan.target else { throw Failure.changed }
            try requireTargetReceipts(plan, store: store)
            let payload = try source.snapshotData()
            for isHub in [false, true] {
                guard let head = try ledger(plan, store: store, hub: isHub).head(meetingID: source.record.id),
                      head.operation == .upsert,
                      head.payloadSHA256 == MeetingMinutesPublication.digest(payload),
                      head.receipt?.isCurrent == true,
                      let receipt = head.receipt,
                      [.stored, .searchable, .superseded].contains(receipt.status) else {
                    throw Failure.deliveryPending
                }
                if isHub {
                    try await hub.stageSupersession(snapshotData: payload, meetingID: source.record.id,
                        expectedOrdinal: head.ordinal, target: plan.target)
                } else {
                    try await primary.stageSupersession(snapshotData: payload, meetingID: source.record.id,
                        expectedOrdinal: head.ordinal, target: plan.target)
                }
            }
        }
        try complete(plan, store: store)
    }

    static func complete(_ plan: Plan, store: MeetingStore) throws {
        try MeetingMinutesJob.withRevisionLock(store: store, id: plan.target.meetingID) {
            try completeLocked(plan, store: store)
        }
    }

    private static func completeLocked(_ plan: Plan, store: MeetingStore) throws {
        let fresh = try prepare(targetID: plan.target.meetingID, store: store)
        guard fresh.target == plan.target else { throw Failure.changed }
        try requireTargetReceipts(plan, store: store)
        for source in plan.sources {
            for hub in [false, true] {
                guard let head = try ledger(plan, store: store, hub: hub).head(meetingID: source.record.id),
                      head.supersededBy == plan.target, head.receipt?.status == .superseded,
                      head.receipt?.isCurrent == true,
                      head.payloadSHA256 == MeetingMinutesPublication.digest(try source.snapshotData()) else {
                    throw Failure.deliveryPending
                }
            }
        }
        for source in plan.sources {
            try MeetingMinutesJob.withRevisionLock(store: store, id: source.record.id) {
                guard var record = store.load(id: source.record.id), record.minutesState != "pending",
                      record.mergedIntoMeetingID == nil || record.mergedIntoMeetingID == plan.target.meetingID else {
                    throw Failure.changed
                }
                let file = source.authority == "accepted" ? "minutes-accepted.json" : "minutes.json"
                let bytes = try Data(contentsOf: store.directory(for: record.id).appendingPathComponent(file))
                guard MeetingMinutesPublication.digest(bytes) == source.revision else { throw Failure.changed }
                record.mergedIntoMeetingID = plan.target.meetingID
                store.save(record)
                guard store.load(id: record.id)?.mergedIntoMeetingID == plan.target.meetingID else {
                    throw Failure.changed
                }
            }
        }
    }
}
