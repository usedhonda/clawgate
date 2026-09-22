import XCTest
@testable import ClawGate

/// `JevKeyStore` reads/writes the on-disk 0o600 credential file. Every test
/// uses a fake key and a temp path — never `~/.clawgate/secrets/`.
final class JevKeyStoreTests: XCTestCase {
    private func makeStore() -> (JevKeyStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-keystore-tests-\(UUID().uuidString)", isDirectory: true)
        var store = JevKeyStore()
        store.path = dir.appendingPathComponent("typesafe.json").path
        return (store, dir)
    }

    override func tearDown() {
        super.tearDown()
    }

    func testSaveThenLoadRoundTrips() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save("test-key-1234")
        XCTAssertEqual(try store.load(), "test-key-1234")
        XCTAssertTrue(store.isConfigured)
    }

    func testTheSavedFileIsOwnerReadWriteOnly() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save("test-key-1234")
        let attrs = try FileManager.default.attributesOfItem(atPath: store.path)
        let mode = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testSavingAnEmptyKeyDeletesTheFile() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save("test-key-1234")
        XCTAssertTrue(store.isConfigured)
        try store.save("   ")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        XCTAssertFalse(store.isConfigured)
    }

    func testLoadingAMissingFileThrowsKeyUnreadable() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? JevError, .keyUnreadable)
        }
    }

    func testTheFileHoldsTheKeyButTheTagDoesNot() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save("test-key-1234")
        let data = try XCTUnwrap(FileManager.default.contents(atPath: store.path))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("test-key-1234"))

        let tag = JevKeyStore.tag(of: "test-key-1234")
        XCTAssertFalse(tag.contains("test-key-1234"))
    }
}
