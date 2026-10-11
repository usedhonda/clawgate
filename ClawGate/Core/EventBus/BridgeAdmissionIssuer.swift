import CryptoKit
import Foundation
import Darwin

enum BridgeAdmissionProvenance: String, Codable {
    case watcherAccepted = "watcher_accepted"
    case debugInjected = "debug_injected"
    case unknown
}

struct BridgeAdmission: Codable, Equatable {
    let admissionId: String
    let generation: String
    let eventId: Int64
    let eventType: String
    let adapter: String
    let observedAt: String
    let provenance: BridgeAdmissionProvenance
    let issuerKeyId: String?
    let failureReason: String?

    enum CodingKeys: String, CodingKey {
        case admissionId = "admission_id"
        case generation
        case eventId = "event_id"
        case eventType = "event_type"
        case adapter
        case observedAt = "observed_at"
        case provenance
        case issuerKeyId = "issuer_key_id"
        case failureReason = "failure_reason"
    }
}

/// Bridge-owned, body-free admission identity and exact poll response signer.
/// Missing private material intentionally degrades events to `unknown`.
final class BridgeAdmissionIssuer {
    private struct PersistedRecord: Codable { let admission: BridgeAdmission }
    private struct Generation: Codable { let value: String; let issuerKeyId: String }
    private struct Limits: Decodable {
        let maxRecords: Int
        let maxBytes: Int
        enum CodingKeys: String, CodingKey { case maxRecords = "max_records", maxBytes = "max_bytes" }
    }
    private let lock = NSLock()
    private let recordsURL: URL
    private let keyURL: URL
    private let generationURL: URL
    private let maxRecords: Int
    private let maxBytes: Int
    private let key: Curve25519.Signing.PrivateKey?
    private let generation: String
    private let issuerKeyId: String?
    private var records: [PersistedRecord] = []
    private var unavailableReason: String?
    private var journalBytes = 0

    convenience init?(provisionedDirectory directory: URL) {
        let limits = directory.appendingPathComponent("limits.json")
        do {
            try Self.validatePath(limits, directory: false, create: false)
            let size = (try FileManager.default.attributesOfItem(atPath: limits.path)[.size] as? NSNumber)?.intValue ?? -1
            guard size > 0, size <= 4096 else { return nil }
            let data = try Data(contentsOf: limits)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["max_records", "max_bytes"]) else { return nil }
            let decoded = try JSONDecoder().decode(Limits.self, from: data)
            guard decoded.maxRecords > 0, decoded.maxBytes > 0 else { return nil }
            self.init(directory: directory, maxRecords: decoded.maxRecords, maxBytes: decoded.maxBytes)
        } catch { return nil }
    }

    init(directory: URL, maxRecords: Int, maxBytes: Int, initializeForTesting: Bool = false) {
        self.recordsURL = directory.appendingPathComponent("admissions.jsonl")
        self.keyURL = directory.appendingPathComponent("issuer.key")
        self.generationURL = directory.appendingPathComponent("generation.json")
        self.maxRecords = maxRecords
        self.maxBytes = maxBytes
        var loadedKey: Curve25519.Signing.PrivateKey?
        var reason: String?
        var loadedGeneration = ""
        do {
            try Self.validatePath(directory, directory: true, create: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
            if let mode = attrs[.posixPermissions] as? NSNumber, mode.intValue & 0o077 != 0 { throw NSError(domain: "issuer", code: 1) }
            if let owner = attrs[.ownerAccountID] as? NSNumber, owner.uintValue != UInt32(getuid()) { throw NSError(domain: "issuer", code: 14) }
            guard maxRecords > 0, maxBytes > 0 else { throw NSError(domain: "issuer", code: 2) }
            if FileManager.default.fileExists(atPath: keyURL.path) {
                try Self.validatePath(keyURL, directory: false, create: false)
                let keyAttrs = try FileManager.default.attributesOfItem(atPath: keyURL.path)
                if (((keyAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644) & 0o077) != 0 { throw NSError(domain: "issuer", code: 3) }
                if let owner = keyAttrs[.ownerAccountID] as? NSNumber, owner.uintValue != UInt32(getuid()) { throw NSError(domain: "issuer", code: 15) }
                let raw = try Data(contentsOf: keyURL, options: [.mappedIfSafe])
                loadedKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            } else { throw NSError(domain: "issuer", code: 4) }
            let recordsExist = FileManager.default.fileExists(atPath: recordsURL.path)
            let generationExist = FileManager.default.fileExists(atPath: generationURL.path)
            if generationExist { try Self.validatePath(generationURL, directory: false, create: false) }
            if recordsExist { try Self.validatePath(recordsURL, directory: false, create: false) }
            if generationExist, let data = try? Data(contentsOf: generationURL), let decoded = try? JSONDecoder().decode(Generation.self, from: data), decoded.issuerKeyId == Self.keyId(for: loadedKey!.publicKey.rawRepresentation) {
                loadedGeneration = decoded.value
            } else if generationExist || recordsExist {
                throw NSError(domain: "issuer", code: 13)
            } else {
                // Production provisioning must establish the pair explicitly. A lost
                // pair under an existing key must never mint a fresh generation.
                guard initializeForTesting else { throw NSError(domain: "issuer", code: 18) }
                loadedGeneration = UUID().uuidString.lowercased()
                let data = try JSONEncoder().encode(Generation(value: loadedGeneration, issuerKeyId: Self.keyId(for: loadedKey!.publicKey.rawRepresentation)))
                try Self.atomicWrite(data, to: generationURL)
                try Self.atomicWrite(Data(), to: recordsURL)
            }
            let size = (try FileManager.default.attributesOfItem(atPath: recordsURL.path)[.size] as? NSNumber)?.intValue ?? -1
            guard size >= 0, size <= maxBytes else { throw NSError(domain: "issuer", code: 16) }
            let data = try Data(contentsOf: recordsURL)
            guard data.count == size, data.isEmpty || data.last == 10 else { throw NSError(domain: "issuer", code: 16) }
            journalBytes = size
            records = try data.split(separator: 10).map { try JSONDecoder().decode(PersistedRecord.self, from: Data($0)) }
            let keyID = Self.keyId(for: loadedKey!.publicKey.rawRepresentation)
            guard records.count <= maxRecords, data.count <= maxBytes, Set(records.map { $0.admission.admissionId }).count == records.count,
                  UUID(uuidString: loadedGeneration) != nil,
                  records.allSatisfy({ $0.admission.generation == loadedGeneration && $0.admission.issuerKeyId == keyID && UUID(uuidString: $0.admission.admissionId) != nil && $0.admission.eventId > 0 && !$0.admission.eventType.isEmpty && !$0.admission.adapter.isEmpty && !$0.admission.observedAt.isEmpty }) else { throw NSError(domain: "issuer", code: 17) }
        } catch { reason = "issuer_unavailable" }
        self.key = loadedKey
        self.generation = loadedGeneration.isEmpty ? UUID().uuidString.lowercased() : loadedGeneration
        self.issuerKeyId = loadedKey.map { Self.keyId(for: $0.publicKey.rawRepresentation) }
        self.unavailableReason = reason
    }

    static func keyId(for publicKey: Data) -> String { SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined() }
    static func canonicalBytes(method: String, uri: String, challenge: String, status: Int, keyId: String, body: Data) -> Data {
        var bytes = Data("clawgate.poll.v1".utf8)
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        for value in [method, uri, challenge, String(status), keyId, bodyHash] {
            var length = UInt32(value.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: value.utf8)
        }
        return bytes
    }
    static func validChallenge(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    func admission(eventId: Int64, type: String, adapter: String, observedAt: String, provenance: BridgeAdmissionProvenance) -> BridgeAdmission {
        lock.lock(); defer { lock.unlock() }
        let admissionID = UUID().uuidString.lowercased()
        // Invalid metadata cannot survive a reload: the journal loader rejects
        // empty fields (and non-positive event IDs) for every durable record.
        // Keep the event visible to callers, but never append a record that
        // would poison the whole journal.
        guard eventId > 0, !type.isEmpty, !adapter.isEmpty, !observedAt.isEmpty else {
            return BridgeAdmission(admissionId: admissionID, generation: generation, eventId: eventId, eventType: type, adapter: adapter, observedAt: observedAt, provenance: .unknown, issuerKeyId: issuerKeyId, failureReason: "invalid_metadata")
        }
        let failure = unavailableReason ?? (records.count >= maxRecords ? "issuer_capacity" : nil)
        guard failure == nil else {
            return BridgeAdmission(admissionId: admissionID, generation: generation, eventId: eventId, eventType: type, adapter: adapter, observedAt: observedAt, provenance: .unknown, issuerKeyId: issuerKeyId, failureReason: failure)
        }
        let admission = BridgeAdmission(admissionId: admissionID, generation: generation, eventId: eventId, eventType: type, adapter: adapter, observedAt: observedAt, provenance: provenance, issuerKeyId: issuerKeyId, failureReason: nil)
        guard let recordData = try? JSONEncoder().encode(PersistedRecord(admission: admission)) else {
            unavailableReason = "issuer_store_encode_failed"
            return BridgeAdmission(admissionId: admission.admissionId, generation: generation, eventId: eventId, eventType: type, adapter: adapter, observedAt: observedAt, provenance: .unknown, issuerKeyId: issuerKeyId, failureReason: unavailableReason)
        }
        let line = recordData + Data([10])
        guard line.count <= maxBytes - journalBytes else {
            return BridgeAdmission(admissionId: admission.admissionId, generation: generation, eventId: eventId, eventType: type, adapter: adapter, observedAt: observedAt, provenance: .unknown, issuerKeyId: issuerKeyId, failureReason: "issuer_capacity")
        }
        guard Self.appendDurably(line, to: recordsURL, expectedBytes: journalBytes) else {
            unavailableReason = "issuer_store_write_failed"
            return BridgeAdmission(admissionId: admission.admissionId, generation: generation, eventId: eventId, eventType: type, adapter: adapter, observedAt: observedAt, provenance: .unknown, issuerKeyId: issuerKeyId, failureReason: unavailableReason)
        }
        journalBytes += line.count
        records.append(PersistedRecord(admission: admission))
        return admission
    }

    private static func validatePath(_ url: URL, directory: Bool, create: Bool) throws {
        let fm = FileManager.default
        var node = url
        if !create && !fm.fileExists(atPath: node.path) { throw NSError(domain: "issuer", code: 20) }
        while node.path != "/" {
            if fm.fileExists(atPath: node.path) {
                if (try? fm.destinationOfSymbolicLink(atPath: node.path)) != nil { throw NSError(domain: "issuer", code: 21) }
                let attrs = try fm.attributesOfItem(atPath: node.path)
                let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
                if node == url, let owner = attrs[.ownerAccountID] as? NSNumber, owner.uintValue != UInt32(getuid()) { throw NSError(domain: "issuer", code: 22) }
                if node == url {
                    if directory && !((attrs[.type] as? FileAttributeType) == .typeDirectory) { throw NSError(domain: "issuer", code: 23) }
                    if !directory && !((attrs[.type] as? FileAttributeType) == .typeRegular) { throw NSError(domain: "issuer", code: 24) }
                    if mode & 0o077 != 0 { throw NSError(domain: "issuer", code: 25) }
                }
            }
            node.deleteLastPathComponent()
        }
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: "issuer", code: 30) }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard written > 0 else { throw NSError(domain: "issuer", code: 31) }
                    offset += written
                }
            }
            guard fsync(fd) == 0 else { throw NSError(domain: "issuer", code: 32) }
            guard close(fd) == 0 else { throw NSError(domain: "issuer", code: 33) }
        } catch { close(fd); try? FileManager.default.removeItem(at: temp); throw error }
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temp, backupItemName: nil, options: .usingNewMetadataOnly) }
        else { try FileManager.default.moveItem(at: temp, to: url) }
        chmod(url.path, 0o600)
        let directoryFD = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard directoryFD >= 0, fsync(directoryFD) == 0, close(directoryFD) == 0 else { throw NSError(domain: "issuer", code: 34) }
    }

    private static func appendDurably(_ data: Data, to url: URL, expectedBytes: Int) -> Bool {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return false }
        defer { flock(fd, LOCK_UN) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size == expectedBytes else { return false }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard written > 0 else { throw NSError(domain: "issuer", code: 35) }
                    offset += written
                }
            }
            return fsync(fd) == 0
        } catch { return false }
    }

    func sign(method: String, uri: String, challenge: String, status: Int, body: Data) -> (keyId: String, signature: Data)? {
        guard Self.validChallenge(challenge), let key, let keyId = issuerKeyId else { return nil }
        let bytes = Self.canonicalBytes(method: method, uri: uri, challenge: challenge, status: status, keyId: keyId, body: body)
        guard let signature = try? key.signature(for: bytes) else { return nil }
        return (keyId, signature)
    }
}
