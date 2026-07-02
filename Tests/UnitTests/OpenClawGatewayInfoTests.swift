import XCTest
@testable import ClawGate

/// Characterization tests for OpenClawGatewayInfo.load — pins the shared parse
/// contract of ~/.openclaw/openclaw.json (token / port / raw host) that both
/// BridgeCore.openclawInfo and OpenClawWSClient.readOpenClawGatewayConfig rely on.
final class OpenClawGatewayInfoTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-gateway-info-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeFixture(_ json: String) throws -> String {
        let path = tmpDir.appendingPathComponent("openclaw.json").path
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testValidConfig() throws {
        let path = try writeFixture(#"""
        { "gateway": { "host": "example-host.example.com", "port": 12345,
          "auth": { "token": "test-token" } } }
        """#)
        let info = try XCTUnwrap(OpenClawGatewayInfo.load(path: path))
        XCTAssertEqual(info.token, "test-token")
        XCTAssertEqual(info.port, 12345)
        XCTAssertEqual(info.host, "example-host.example.com")
    }

    func testMissingPortFallsBackToDefault() throws {
        let path = try writeFixture(#"""
        { "gateway": { "host": "example-host.example.com",
          "auth": { "token": "test-token" } } }
        """#)
        let info = try XCTUnwrap(OpenClawGatewayInfo.load(path: path))
        XCTAssertEqual(info.port, AppConfig.defaultOpenClawPort)
    }

    func testMissingHostReturnsNil() throws {
        let path = try writeFixture(#"""
        { "gateway": { "port": 12345, "auth": { "token": "test-token" } } }
        """#)
        let info = try XCTUnwrap(OpenClawGatewayInfo.load(path: path))
        XCTAssertNil(info.host)
    }

    func testEmptyHostStaysEmpty() throws {
        let path = try writeFixture(#"""
        { "gateway": { "host": "", "port": 12345,
          "auth": { "token": "test-token" } } }
        """#)
        let info = try XCTUnwrap(OpenClawGatewayInfo.load(path: path))
        XCTAssertEqual(info.host, "")
    }

    func testEmptyTokenReturnsNil() throws {
        let path = try writeFixture(#"""
        { "gateway": { "host": "example-host.example.com", "port": 12345,
          "auth": { "token": "" } } }
        """#)
        XCTAssertNil(OpenClawGatewayInfo.load(path: path))
    }

    func testMissingFileReturnsNil() {
        let path = tmpDir.appendingPathComponent("does-not-exist.json").path
        XCTAssertNil(OpenClawGatewayInfo.load(path: path))
    }

    func testMalformedJSONReturnsNil() throws {
        let path = try writeFixture("{ not valid json ")
        XCTAssertNil(OpenClawGatewayInfo.load(path: path))
    }
}
