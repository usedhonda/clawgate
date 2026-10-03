import CryptoKit
import Foundation
import CoreFoundation

/// Pure, inactive admission helper for the existing ambient raw.jsonl format.
/// It does not read files, create IDs, or enqueue records.
enum AudioHubTranscriptWire {
    struct PreparedRecord {
        let sourceRecordRef: String
        let revisionRef: String
        private let body: Body

        fileprivate enum Body {
            case event(metadata: [String: Any], occurredAt: String)
            case gap
        }

        fileprivate init(sourceRecordRef: String, revisionRef: String, body: Body) {
            self.sourceRecordRef = sourceRecordRef
            self.revisionRef = revisionRef
            self.body = body
        }

        var isGap: Bool {
            if case .gap = body { return true }
            return false
        }

        /// Builds immutable bytes after the caller obtains the outbox IDs.
        /// A clock gap has no event body and is represented separately.
        func envelope(sourceUUID: String, externalID: String) throws -> Data? {
            guard !isGap else { return nil }
            guard AudioHubTranscriptWire.isCanonicalUUID(sourceUUID),
                  externalID == AudioHubOutbox.externalID(sourceUUID: sourceUUID,
                                                          sourceRecordRef: sourceRecordRef,
                                                          revision: revisionRef) else {
                throw Error.invalidEnvelopeReferences
            }
            guard case let .event(baseMetadata, occurredAt) = body else { return nil }
            var metadata = baseMetadata
            metadata["schema_version"] = 1
            metadata["source_uuid"] = sourceUUID
            return try JSONSerialization.data(withJSONObject: [
                "source": "clawgate",
                "domain": "audio",
                "kind": "clawgate.audio-transcript.v1",
                "identity": NSNull(),
                "occurred_at": occurredAt,
                "external_id": externalID,
                "metadata": metadata
            ], options: [.sortedKeys])
        }

        /// Body-free control record for a source line whose capture clock is unusable.
        func controlGap() throws -> Data? {
            guard isGap else { return nil }
            return try JSONSerialization.data(withJSONObject: [
                "source_record_ref": sourceRecordRef,
                "revision_ref": revisionRef,
                "reason": "source_clock_unknown",
                "coverage": "excluded"
            ], options: [.sortedKeys])
        }
    }

    enum Error: Swift.Error, Equatable {
        case invalidJSON
        case invalidText
        case invalidReference
        case invalidEnvelopeReferences
        case invalidRawSegment
    }

    static func prepare(raw: Data, sourceSessionID: String, line: Int) throws -> PreparedRecord {
        guard validSession(sourceSessionID), line > 0 else { throw Error.invalidReference }
        let sourceRecordRef = "clawgate:session:\(sourceSessionID):raw:\(line)"
        let revisionRef = "sha256:\(sha256(raw))"
        guard let object = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]),
              let segment = object as? [String: Any] else { throw Error.invalidJSON }
        guard let text = segment["text"] as? String else { throw Error.invalidText }

        let metadata: [String: Any] = [
            "session_id": "clawgate:session:\(sourceSessionID)",
            "source_session_id": sourceSessionID,
            "source_record_ref": sourceRecordRef,
            "revision_ref": revisionRef,
            "text": text,
            "raw_segment": segment,
            "privacy_flags": segment["privacy_flags"] ?? NSNull(),
            "speaker_identity_confidence": "unverified"
        ]
        guard JSONSerialization.isValidJSONObject(metadata) else { throw Error.invalidRawSegment }

        guard let captured = number(segment["capturedAt"]), validEpoch(captured) else {
            return PreparedRecord(sourceRecordRef: sourceRecordRef, revisionRef: revisionRef, body: .gap)
        }
        return PreparedRecord(sourceRecordRef: sourceRecordRef, revisionRef: revisionRef,
                              body: .event(metadata: metadata, occurredAt: iso8601(captured)))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }

    private static func validEpoch(_ value: Double) -> Bool {
        value.isFinite && value >= -62_135_596_800 && value <= 253_402_300_799
    }

    private static func iso8601(_ epoch: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        if epoch.rounded() != epoch { formatter.formatOptions.insert(.withFractionalSeconds) }
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    private static func validSession(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains(where: {
            $0 == "/" || $0 == "\\" || $0 == ":" || CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        })
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
