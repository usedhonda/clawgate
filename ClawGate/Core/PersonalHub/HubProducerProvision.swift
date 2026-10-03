import Foundation
import Darwin

/// Source-specific private setup, deliberately separate from Gateway settings.
struct HubProducerProvision: Decodable {
    let schema_version: Int
    let source: String
    let base_url: String
    let bearer_token: String
    let allowed_domains: [String]

    enum Failure: Error { case invalidProvision, unsafeFile, invalidReceipt, invalidObservation }

    static func location(source: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawgate/hub-provision", isDirectory: true)
            .appendingPathComponent("\(source).json")
    }

    static func load(source: String, from path: URL? = nil) throws -> HubProducerProvision? {
        guard ["line", "clawgate"].contains(source) else { throw Failure.invalidProvision }
        let path = path ?? location(source: source)
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure.unsafeFile
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o777) == 0o600, info.st_uid == getuid(),
              info.st_size > 0, info.st_size <= 65536 else { throw Failure.unsafeFile }
        let data = try file.read(upToCount: 65537) ?? Data()
        guard data.count <= 65536 else { throw Failure.unsafeFile }
        return try parse(data, source: source)
    }

    static func parse(_ data: Data, source: String) throws -> HubProducerProvision {
        let value = try JSONDecoder().decode(Self.self, from: data)
        let expected = source == "line" ? ["line"] : source == "clawgate" ? ["audio"] : []
        guard !expected.isEmpty, value.schema_version == 1, value.source == source,
              value.allowed_domains.sorted() == expected,
              !value.bearer_token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.bearer_token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: value.base_url), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.path),
              parts.url != nil else { throw Failure.invalidProvision }
        return value
    }

    func endpoint(_ path: String) -> URL {
        // Only fixed internal paths are supplied by this producer.
        URL(string: base_url)!.appendingPathComponent(path)
    }

    func acceptsCapabilities(_ data: Data) -> Bool {
        struct Capability: Decodable {
            let version: Int
            let source: String
            let domains: [String]
            let storage_receipt_version: Int
            let max_event_bytes: Int
            let max_chunk_bytes: Int
            let finalize_replay_safe: Bool
        }
        guard data.count <= 65536, let value = try? JSONDecoder().decode(Capability.self, from: data) else { return false }
        return value.version == 1 && value.source == source && value.domains.sorted() == allowed_domains.sorted()
            && value.storage_receipt_version == 1 && value.max_event_bytes == 20 * 1024 * 1024
            && value.max_chunk_bytes == 4 * 1024 * 1024 && value.finalize_replay_safe
    }
}

/// Metadata-only acknowledgement. Audio originals require a separate contract.
struct HubMetadataReceipt: Decodable {
    let receipt_version: Int
    let source: String
    let external_id: String
    let event_id: String
    let sha256: String?
    let byte_length: Int
    let ingest_sequence: Int64

    static func validatedData(response: Data, source: String, externalID: String) throws -> Data {
        guard response.count <= 65536,
              let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let receipt = object["storage_receipt"] as? [String: Any],
              Set(receipt.keys) == Set(["receipt_version", "source", "external_id", "event_id", "sha256", "byte_length", "ingest_sequence"]),
              receipt["sha256"] is NSNull else { throw HubProducerProvision.Failure.invalidReceipt }
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        let parsed = try JSONDecoder().decode(Self.self, from: data)
        guard parsed.receipt_version == 1, parsed.source == source, parsed.external_id == externalID,
              UUID(uuidString: parsed.event_id)?.uuidString.lowercased() == parsed.event_id,
              parsed.sha256 == nil, parsed.byte_length == 0, parsed.ingest_sequence > 0,
              parsed.ingest_sequence <= 9_007_199_254_740_991 else { throw HubProducerProvision.Failure.invalidReceipt }
        return data
    }
}
