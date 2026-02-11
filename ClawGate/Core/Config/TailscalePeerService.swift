import Foundation

struct TailscalePeer: Identifiable, Equatable {
    let id: String
    let hostname: String
    let ip: String
    let online: Bool
}

enum TailscalePeerService {
    private static let binaryCandidates = [
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    static func loadPeers() -> [TailscalePeer] {
        guard let cli = binaryCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return []
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "--json"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else { return [] }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let backendState = root["BackendState"] as? String,
            backendState == "Running"
        else {
            return []
        }

        guard let peerMap = root["Peer"] as? [String: Any] else { return [] }

        let peers: [TailscalePeer] = peerMap.compactMap { _, value in
            guard let peer = value as? [String: Any] else { return nil }
            let dnsName = (peer["DNSName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedHost = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
            guard !normalizedHost.isEmpty else { return nil }

            let online = peer["Online"] as? Bool ?? false
            let ip = (peer["TailscaleIPs"] as? [String])?.first ?? ""
            return TailscalePeer(
                id: normalizedHost,
                hostname: normalizedHost,
                ip: ip,
                online: online
            )
        }

        return peers.sorted {
            if $0.online != $1.online {
                return $0.online && !$1.online
            }
            return $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending
        }
    }
}
