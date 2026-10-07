import Foundation
import Darwin
import SystemConfiguration

/// Resolves the best hostname this machine can advertise to peers, in order:
///   1. Tailscale name (works from anywhere on the tailnet)
///   2. Bonjour `<host>.local` (works on the same LAN segment)
///   3. Primary LAN IPv4 (fragile but works on the same LAN)
///   4. "127.0.0.1" (last resort — only useful for self-connection)
enum OwnHostnameResolver {
    private static let snapshot = HostnameSnapshot(initial: TailscaleResolver.cachedHostname()) {
        resolveInBackground()
    }

    static func resolve() -> String {
        snapshot.current()
    }

    private static func resolveInBackground() -> String? {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        if let ts = TailscaleResolver.hostname(deadline: deadline) { return ts }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        if let bonjour = bonjourHostname() { return bonjour }
        if let lan = primaryLanIPv4(deadline: deadline) { return lan }
        return nil
    }

    private static func bonjourHostname() -> String? {
        var name = (SCDynamicStoreCopyLocalHostName(nil) as String? ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // Sanitize: replace spaces with hyphens (Bonjour disallows spaces).
        name = name.replacingOccurrences(of: " ", with: "-")
        return name.hasSuffix(".local") ? name : "\(name).local"
    }

    private static func primaryLanIPv4(deadline: TimeInterval) -> String? {
        guard let output = BoundedHostnameProcess.run(executable: "/sbin/ifconfig", deadline: deadline) else { return nil }

        // Look for "inet 192.168.x.x" / "inet 10.x.x.x" / "inet 172.[16-31].x.x"
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet ") else { continue }
            let parts = trimmed.components(separatedBy: " ")
            guard parts.count >= 2 else { continue }
            let ip = parts[1]
            let octets = ip.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4 else { continue }
            // Skip loopback and Tailscale CGNAT.
            if octets[0] == 127 { continue }
            if octets[0] == 100 && (64...127).contains(octets[1]) { continue }
            // RFC1918 private ranges.
            if octets[0] == 10 { return ip }
            if octets[0] == 192 && octets[1] == 168 { return ip }
            if octets[0] == 172 && (16...31).contains(octets[1]) { return ip }
        }
        return nil
    }
}

/// Resolves the Tailscale hostname with a 3-tier fallback:
///   1. Tailscale CLI (with environment fix for App Store build)
///   2. Network interface reverse DNS lookup
///   3. UserDefaults cache
enum TailscaleResolver {

    private static let cacheKey = "clawgate.tailscaleHostname"

    static func hostname(deadline: TimeInterval) -> String? {
        if let h = hostnameViaCLI(deadline: deadline) { cacheHostname(h); return h }
        if let h = hostnameViaNetwork(deadline: deadline) { cacheHostname(h); return h }
        return cachedHostname()
    }

    // MARK: - Strategy 1: Tailscale CLI

    private static func hostnameViaCLI(deadline: TimeInterval) -> String? {
        let paths = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        guard let cli = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }

        // App Store Tailscale needs SHELL + SHLVL to avoid "GUI failed to start" error
        // when launched from launchd/LoginItem (no shell environment).
        let isAppStoreBuild = cli.hasPrefix("/Applications/Tailscale.app")
        var env: [String: String]? = nil
        if isAppStoreBuild {
            env = [
                "HOME": NSHomeDirectory(),
                "SHELL": "/bin/zsh",
                "SHLVL": "1",
            ]
        }

        guard let output = BoundedHostnameProcess.run(executable: cli, arguments: ["status", "--json"], environment: env, deadline: deadline) else {
            return nil
        }
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backendState = json["BackendState"] as? String,
              backendState == "Running",
              let selfInfo = json["Self"] as? [String: Any],
              let dnsName = selfInfo["DNSName"] as? String else {
            return nil
        }
        return dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
    }

    // MARK: - Strategy 2: ifconfig + reverse DNS

    private static func hostnameViaNetwork(deadline: TimeInterval) -> String? {
        // Find a 100.x.x.x Tailscale IP from network interfaces
        guard let tailscaleIP = findTailscaleIP(deadline: deadline) else { return nil }

        // Reverse DNS lookup
        guard let output = BoundedHostnameProcess.run(executable: "/usr/bin/host", arguments: [tailscaleIP], deadline: deadline) else {
            return nil
        }

        // Parse: "x.x.x.100.in-addr.arpa domain name pointer my-host.example-tailnet.ts.net."
        for line in output.components(separatedBy: "\n") {
            guard line.contains("domain name pointer") else { continue }
            let parts = line.components(separatedBy: " ")
            guard let hostname = parts.last, hostname.contains(".ts.net") else { continue }
            let cleaned = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
            return cleaned
        }
        return nil
    }

    private static func findTailscaleIP(deadline: TimeInterval) -> String? {
        guard let output = BoundedHostnameProcess.run(executable: "/sbin/ifconfig", deadline: deadline) else {
            return nil
        }
        // Look for "inet 100.x.x.x" lines (Tailscale CGNAT range)
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet 100.") else { continue }
            let parts = trimmed.components(separatedBy: " ")
            if parts.count >= 2 {
                return parts[1]
            }
        }
        return nil
    }

    // MARK: - Strategy 3: Cache

    private static func cacheHostname(_ hostname: String) {
        UserDefaults.standard.set(hostname, forKey: cacheKey)
    }

    fileprivate static func cachedHostname() -> String? {
        UserDefaults.standard.string(forKey: cacheKey)
    }

}

/// HTTP callers only take a short lock; all hostname discovery runs off the NIO loop.
final class HostnameSnapshot {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "clawgate.hostname-resolution", qos: .utility)
    private var value: String
    private var refreshing = false
    private var nextRefresh: TimeInterval = 0
    private let refreshInterval: TimeInterval
    private let resolver: () -> String?

    init(initial: String? = nil, refreshInterval: TimeInterval = 60, resolver: @escaping () -> String?) {
        value = initial.flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1"
        self.refreshInterval = refreshInterval
        self.resolver = resolver
    }

    func current() -> String {
        lock.lock()
        let result = value
        let shouldRefresh = !refreshing && ProcessInfo.processInfo.systemUptime >= nextRefresh
        if shouldRefresh { refreshing = true }
        lock.unlock()
        if shouldRefresh {
            queue.async { [self] in
                let resolved = resolver()
                lock.lock()
                if let resolved, !resolved.isEmpty { value = resolved }
                nextRefresh = ProcessInfo.processInfo.systemUptime + refreshInterval
                refreshing = false
                lock.unlock()
            }
        }
        return result
    }
}

/// Drains a nonblocking pipe while the child runs, avoiding pipe-capacity deadlock.
enum BoundedHostnameProcess {
    static func run(executable: String, arguments: [String] = [], environment: [String: String]? = nil,
                    deadline: TimeInterval, outputLimit: Int = 1_048_576) -> String? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdout = Pipe()
        let fd = stdout.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { return nil }
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        stdout.fileHandleForWriting.closeFile()
        defer { stdout.fileHandleForReading.closeFile() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var reachedEOF = false
        var failed = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                guard data.count + count <= outputLimit else { failed = true; break }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                reachedEOF = true
            } else if errno != EAGAIN && errno != EINTR {
                failed = true
                break
            }
            if reachedEOF && !process.isRunning { break }
            if count <= 0 { Thread.sleep(forTimeInterval: 0.005) }
        }
        guard !failed, reachedEOF, !process.isRunning else {
            if process.isRunning {
                process.terminate()
                // Do not wait without a deadline for a child that ignores SIGTERM.
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.isEmpty ? nil : output
    }
}
