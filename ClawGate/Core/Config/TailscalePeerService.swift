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

        var peers: [TailscalePeer] = []

        if let selfNode = root["Self"] as? [String: Any],
           let selfPeer = parsePeer(selfNode) {
            peers.append(selfPeer)
        }

        if let peerMap = root["Peer"] as? [String: Any] {
            peers.append(contentsOf: peerMap.compactMap { _, value in
                guard let peer = value as? [String: Any] else { return nil }
                return parsePeer(peer)
            })
        }

        // Deduplicate by hostname because some environments can surface overlaps.
        peers = Dictionary(grouping: peers, by: { $0.hostname })
            .values
            .compactMap { group in
                group.sorted { lhs, rhs in
                    if lhs.online != rhs.online {
                        return lhs.online && !rhs.online
                    }
                    return !lhs.ip.isEmpty && rhs.ip.isEmpty
                }.first
            }

        return peers.sorted {
            if $0.online != $1.online {
                return $0.online && !$1.online
            }
            return $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending
        }
    }

    private static func parsePeer(_ peer: [String: Any]) -> TailscalePeer? {
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
}
