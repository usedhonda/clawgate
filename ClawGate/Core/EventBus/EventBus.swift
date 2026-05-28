import Foundation

struct BridgeEvent: Codable {
    let id: Int64
    let type: String
    let adapter: String
    let payload: [String: String]
    let observedAt: String
}

final class EventBus {
    private struct Subscriber {
        let id: UUID
        let callback: (BridgeEvent) -> Void
    }

    private struct PersistedCounter: Codable {
        let nextID: Int64
    }

    private let lock = NSLock()
    private var events: [BridgeEvent] = []
    private var nextID: Int64 = 1
    private var subscribers: [UUID: Subscriber] = [:]
    private let maxEvents = 1000
    private var _lastAppendAt: Date?
    private let nextIDPersistenceURL: URL?

    var lastAppendAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _lastAppendAt
    }

    init(persistenceDirectory: URL? = nil) {
        // nextID persistence prevents cursor desync across ClawGate restarts.
        // Downstream Gateway plugin polls /v1/poll?since=N; if we reset nextID
        // to 1 on every restart, the plugin's stale cursor would silently drop
        // every new event. See memory feedback_clawgate_cursor_stuck (2026-05-28).
        if let dir = persistenceDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("eventbus-next-id.json")
            self.nextIDPersistenceURL = url
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(PersistedCounter.self, from: data),
               decoded.nextID > 0 {
                self.nextID = decoded.nextID
            }
        } else {
            self.nextIDPersistenceURL = nil
        }
    }

    @discardableResult
    func append(type: String, adapter: String, payload: [String: String]) -> BridgeEvent {
        lock.lock()

        let event = BridgeEvent(
            id: nextID,
            type: type,
            adapter: adapter,
            payload: payload,
            observedAt: ISO8601DateFormatter().string(from: Date())
        )

        nextID += 1
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        _lastAppendAt = Date()
        persistNextIDLocked()

        let callbacks = subscribers.values.map(\.callback)
        lock.unlock()

        for callback in callbacks {
            callback(event)
        }

        return event
    }

    private func persistNextIDLocked() {
        guard let url = nextIDPersistenceURL else { return }
        let payload = PersistedCounter(nextID: nextID)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func poll(since: Int64?) -> (events: [BridgeEvent], nextCursor: Int64) {
        lock.lock()
        defer { lock.unlock() }

        let filtered: [BridgeEvent]
        if let since {
            filtered = events.filter { $0.id > since }
        } else {
            filtered = events
        }

        return (filtered, nextID - 1)
    }

    @discardableResult
    func subscribe(_ callback: @escaping (BridgeEvent) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        subscribers[id] = Subscriber(id: id, callback: callback)
        lock.unlock()
        return id
    }

    func unsubscribe(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }
}
