import Foundation

/// Resolves the Tailscale hostname with a 3-tier fallback:
///   1. Tailscale CLI (with environment fix for App Store build)
///   2. Network interface reverse DNS lookup
///   3. UserDefaults cache
enum TailscaleResolver {

    private static let cacheKey = "clawgate.tailscaleHostname"

    static func hostname() -> String? {
        if let h = hostnameViaCLI() { cacheHostname(h); return h }
        if let h = hostnameViaNetwork() { cacheHostname(h); return h }
        return cachedHostname()
    }

    // MARK: - Strategy 1: Tailscale CLI

    private static func hostnameViaCLI() -> String? {
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

        guard let output = runProcess(executable: cli, arguments: ["status", "--json"], environment: env) else {
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

    private static func hostnameViaNetwork() -> String? {
        // Find a 100.x.x.x Tailscale IP from network interfaces
        guard let tailscaleIP = findTailscaleIP() else { return nil }

        // Reverse DNS lookup
        guard let output = runProcess(executable: "/usr/bin/host", arguments: [tailscaleIP], environment: nil) else {
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

    private static func findTailscaleIP() -> String? {
        guard let output = runProcess(executable: "/sbin/ifconfig", arguments: [], environment: nil) else {
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

    private static func cachedHostname() -> String? {
        UserDefaults.standard.string(forKey: cacheKey)
    }

    // MARK: - Process Helper

    private static func runProcess(executable: String, arguments: [String], environment: [String: String]?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.isEmpty ? nil : output
    }
}
