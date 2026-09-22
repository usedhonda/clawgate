import Foundation

/// A non-latching circuit breaker for the Jev API: three consecutive failures
/// open it, but only for 30 minutes, and only failures move the needle.
///
/// It does not latch because a stuck-open breaker after a transient TypeSafe
/// outage would silently disable every ambient-window question until someone
/// notices and clears state by hand; letting the window close itself means a
/// real outage still gets tried again automatically once it is plausible the
/// service recovered, while three failures in a row inside the window still
/// stop a hot loop from hammering a downed endpoint. A caller that skips a
/// call because the breaker is open does not record that skip as an
/// attempt — recording it would extend the open window indefinitely (every
/// skip becomes a fresh "failure" to look back from), which is exactly the
/// latch this type exists to avoid.
struct JevBreaker {
    static let tripFailures = 3
    static let openMinutes = 30.0
    static let maxKept = 50
    private static let defaultsKey = "clawgate.jev.breaker"

    struct Attempt: Equatable {
        var at: Date
        var ok: Bool
    }

    var defaults: UserDefaults = .standard

    /// True when the most recent `tripFailures` attempts were all failures
    /// and the latest of them happened within `openMinutes` of `now`.
    func shouldSkip(now: Date = Date()) -> Bool {
        let list = attempts()
        guard list.count >= Self.tripFailures else { return false }
        let latest = list.suffix(Self.tripFailures)
        guard latest.allSatisfy({ !$0.ok }), let lastFailure = latest.last?.at else { return false }
        return now.timeIntervalSince(lastFailure) <= Self.openMinutes * 60
    }

    mutating func record(ok: Bool, at: Date = Date()) {
        var list = attempts()
        list.append(Attempt(at: at, ok: ok))
        if list.count > Self.maxKept {
            list.removeFirst(list.count - Self.maxKept)
        }
        persist(list)
    }

    private func attempts() -> [Attempt] {
        guard let raw = defaults.array(forKey: Self.defaultsKey) as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let at = entry["at"] as? Double, let ok = entry["ok"] as? Bool else { return nil }
            return Attempt(at: Date(timeIntervalSince1970: at), ok: ok)
        }
    }

    private func persist(_ list: [Attempt]) {
        let raw = list.map { ["at": $0.at.timeIntervalSince1970, "ok": $0.ok] as [String: Any] }
        defaults.set(raw, forKey: Self.defaultsKey)
    }
}
