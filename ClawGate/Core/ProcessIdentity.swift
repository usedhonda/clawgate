import Foundation

/// Who this running process is, for diagnostics that span a restart.
///
/// Any counter that starts at zero when the app launches — a reconnect
/// generation, an in-memory ring buffer — reads the same whether it stayed
/// quiet or whether the process restarted underneath it. "Nothing went wrong"
/// and "the evidence was thrown away" must not look alike, so every such
/// reading is reported next to this pair.
enum ProcessIdentity {
    static let pid = ProcessInfo.processInfo.processIdentifier

    /// Asked of the kernel, not taken as `Date()` on first touch: a lazily
    /// initialised `static let` is initialised the first time something reads
    /// it, which for a diagnostics field means it equals the first event's own
    /// timestamp and answers nothing. Falls back to now if the call fails —
    /// wrong, but harmless, and this is diagnostics only.
    static let startedAt: Date = kernelStartTime(pid: pid) ?? Date()

    private static func kernelStartTime(pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        guard started.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(started.tv_sec)
                    + Double(started.tv_usec) / 1_000_000)
    }
}
