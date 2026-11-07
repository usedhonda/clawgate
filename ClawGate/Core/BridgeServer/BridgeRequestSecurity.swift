import Darwin
import Foundation
import NIOCore
import NIOHTTP1

/// Browser admission is independent of source-IP admission: a hostile website
/// can make requests to a service on the visitor's own loopback interface.
enum BridgeRequestSecurity {
    static func isChromeExtensionOrigin(_ origin: String) -> Bool {
        let prefix = "chrome-extension://"
        guard origin.hasPrefix(prefix) else { return false }
        let id = origin.dropFirst(prefix.count)
        return id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains($0) }
    }

    static func allowsBrowserHeaders(_ headers: HTTPHeaders) -> Bool {
        let origins = headers["Origin"]
        if !origins.isEmpty {
            // An unpacked extension has a different ID on each installation.
            // Accept any valid extension origin, never an ordinary web origin.
            return origins.count == 1 && isChromeExtensionOrigin(origins[0])
        }

        // Same-origin GETs can omit Origin, including after DNS rebinding.
        // Native callers omit these headers. Privileged extension fetches may
        // omit Origin and use Sec-Fetch-Site: none, mode cors, destination empty.
        for (name, allowed) in [
            ("Sec-Fetch-Site", ["none"]),
            ("Sec-Fetch-Mode", ["cors", "same-origin"]),
            ("Sec-Fetch-Dest", ["empty"]),
        ] {
            let values = headers[name]
            if !values.isEmpty && (values.count != 1 || !allowed.contains(values[0])) {
                return false
            }
        }
        return true
    }

    static func allowsHost(_ headers: HTTPHeaders, localHostnames: [String]) -> Bool {
        let values = headers["Host"]
        guard values.count == 1, let host = authorityHost(values[0]) else { return false }
        if host == "localhost" { return true }
        // IP literals cannot be rebound through DNS. This does not replace the
        // source-IP filter, which still checks the connected socket's peer.
        if (try? SocketAddress(ipAddress: host, port: 0)) != nil { return true }
        return localHostnames.contains { normalizedHostname($0) == host }
    }

    static func localHostnames() -> [String] {
        var names = kernelHostnames
        let resolved = normalizedHostname(OwnHostnameResolver.resolve())
        names.append(resolved)
        if resolved.hasSuffix(".ts.net"), let short = resolved.split(separator: ".").first {
            names.append(String(short)) // Tailscale MagicDNS short name.
        }
        return names
    }

    private static let kernelHostnames: [String] = {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count) == 0 else { return [] }
        let hostname = normalizedHostname(String(cString: buffer))
        guard !hostname.isEmpty else { return [] }
        if hostname.hasSuffix(".local") {
            return [hostname, String(hostname.dropLast(6))]
        }
        return [hostname, hostname + ".local"]
    }()

    private static func normalizedHostname(_ hostname: String) -> String {
        var result = hostname.lowercased()
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }

    private static func authorityHost(_ authority: String) -> String? {
        guard !authority.isEmpty,
              !authority.contains(where: { $0.isWhitespace || "/\\@?#,%".contains($0) }) else { return nil }
        let host: String
        let port: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let suffix = authority[authority.index(after: close)...]
            if suffix.isEmpty {
                port = nil
            } else {
                guard suffix.first == ":" else { return nil }
                port = suffix.dropFirst()
            }
            guard host.contains(":"), (try? SocketAddress(ipAddress: host, port: 0)) != nil else { return nil }
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2, let first = parts.first, !first.isEmpty else { return nil }
            host = String(first)
            port = parts.count == 2 ? parts[1] : nil
        }
        if let port {
            guard !port.isEmpty, port.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(port), (1...65535).contains(number) else { return nil }
        }
        return normalizedHostname(host)
    }
}
