import XCTest
@testable import ClawGate

/// Characterization tests for AppConfig.runtimeRole / isClientRole
/// (ClawGate/Core/Ambient/RuntimeRole.swift).
///
/// Role is derived purely from openclawHost: a loopback host resolves to
/// `.server` (ambient capture OFF, fail-closed), any other host to `.client`.
/// These tests pin the CURRENT loopback set ["127.0.0.1","localhost","::1",
/// "0.0.0.0","::"] and its exact-match / trim / lowercase semantics so the
/// planned single-source-of-truth refactor (TD-09) can't silently change them.
final class RuntimeRoleTests: XCTestCase {

    private func role(forHost host: String) -> NodeRole {
        var cfg = AppConfig.default
        cfg.openclawHost = host
        return cfg.runtimeRole
    }

    private func isClient(forHost host: String) -> Bool {
        var cfg = AppConfig.default
        cfg.openclawHost = host
        return cfg.isClientRole
    }

    // MARK: - Loopback hosts resolve to .server

    func testEachLoopbackHostResolvesToServer() {
        for host in ["127.0.0.1", "localhost", "::1", "0.0.0.0", "::"] {
            XCTAssertEqual(role(forHost: host), .server, "host=\(host)")
            XCTAssertFalse(isClient(forHost: host), "host=\(host)")
        }
    }

    func testLoopbackHostIsCaseInsensitive() {
        // Only "localhost" carries letters; it must still match when uppercased.
        XCTAssertEqual(role(forHost: "LOCALHOST"), .server)
        XCTAssertEqual(role(forHost: "LocalHost"), .server)
    }

    func testLoopbackHostIsTrimmedBeforeMatching() {
        XCTAssertEqual(role(forHost: "  localhost  "), .server)
        XCTAssertEqual(role(forHost: "\t127.0.0.1\n"), .server)
        XCTAssertEqual(role(forHost: " ::1 "), .server)
    }

    // MARK: - Empty / whitespace resolve to .server (fail-closed)

    func testEmptyHostResolvesToServer() {
        XCTAssertEqual(role(forHost: ""), .server)
        XCTAssertFalse(isClient(forHost: ""))
    }

    func testWhitespaceOnlyHostResolvesToServer() {
        XCTAssertEqual(role(forHost: "   "), .server)
        XCTAssertEqual(role(forHost: "\n\t"), .server)
    }

    // MARK: - Non-loopback hosts resolve to .client

    func testRemoteHostsResolveToClient() {
        // Documentation-only addresses (RFC 5737 TEST-NET, RFC 3849 IPv6 doc,
        // example.com) — never real infra.
        for host in ["example-host.example.com", "192.0.2.1", "203.0.113.5", "2001:db8::1"] {
            XCTAssertEqual(role(forHost: host), .client, "host=\(host)")
            XCTAssertTrue(isClient(forHost: host), "host=\(host)")
        }
    }

    func testRemoteHostCaseIsLoweredButStaysClient() {
        // Lowercasing a remote host must not accidentally turn it loopback.
        XCTAssertEqual(role(forHost: "Example-Host.Example.COM"), .client)
    }

    // MARK: - Exact-match semantics (the TD-09 sharp edge)

    func testLoopbackWithPortSuffixIsNotLoopback() {
        // The set matches the whole trimmed host, so a port suffix defeats it.
        XCTAssertEqual(role(forHost: "127.0.0.1:18789"), .client)
        XCTAssertEqual(role(forHost: "localhost:8080"), .client)
    }

    func testLoopbackAsSubdomainIsNotLoopback() {
        XCTAssertEqual(role(forHost: "localhost.example.com"), .client)
        XCTAssertEqual(role(forHost: "127.0.0.1.example.com"), .client)
    }

    // MARK: - runtimeRole ignores the persisted nodeRole field

    func testRuntimeRoleIgnoresPersistedNodeRole() {
        var serverCfg = AppConfig.default
        serverCfg.nodeRole = .server
        serverCfg.openclawHost = "example-host.example.com"
        XCTAssertEqual(serverCfg.runtimeRole, .client, "remote host wins over nodeRole=.server")

        var clientCfg = AppConfig.default
        clientCfg.nodeRole = .client
        clientCfg.openclawHost = "127.0.0.1"
        XCTAssertEqual(clientCfg.runtimeRole, .server, "loopback host wins over nodeRole=.client")
    }
}
