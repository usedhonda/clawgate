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

    private let lock = NSLock()
    private var events: [BridgeEvent] = []
    private var nextID: Int64 = 1
    private var subscribers: [UUID: Subscriber] = [:]
    private let maxEvents = 1000

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

        let callbacks = subscribers.values.map(\.callback)
        lock.unlock()

        for callback in callbacks {
            callback(event)
        }

        return event
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
