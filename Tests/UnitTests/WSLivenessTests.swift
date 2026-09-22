import XCTest
@testable import ClawGate

/// Guards the frame-freshness watchdog and stuck-`.connecting` force-reconnect
/// added after the 2026-09-22 incident: the Gateway can terminate a socket
/// without that termination ever surfacing as a receive() failure, leaving
/// `isConnected` (and, on the PetModel side, `.connecting`) true forever while
/// nothing arrives. Measured 18- and 78-minute silent holes; a real calendar
/// reminder was lost in one. These tests are pure predicate checks — no
/// wall-clock dependency, no live socket.
final class WSLivenessTests: XCTestCase {

    // MARK: - OpenClawWSClient.isStale

    func testIsStaleFalseWellUnderThreshold() {
        XCTAssertFalse(OpenClawWSClient.isStale(lastFrameAge: 10))
    }

    func testIsStaleFalseJustUnderThreshold() {
        XCTAssertFalse(OpenClawWSClient.isStale(lastFrameAge: 44))
    }

    func testIsStaleTrueJustOverThreshold() {
        XCTAssertTrue(OpenClawWSClient.isStale(lastFrameAge: 46))
    }

    func testIsStaleTrueWellOverThreshold() {
        XCTAssertTrue(OpenClawWSClient.isStale(lastFrameAge: 600))
    }

    // MARK: - PetModel.shouldForceReconnect

    func testShouldForceReconnectFalseAtThirtySeconds() {
        let now = Date()
        XCTAssertFalse(PetModel.shouldForceReconnect(
            isConnecting: true,
            connectingSince: now.addingTimeInterval(-30),
            now: now
        ))
    }

    func testShouldForceReconnectTrueAtOneHundredTwentySeconds() {
        let now = Date()
        XCTAssertTrue(PetModel.shouldForceReconnect(
            isConnecting: true,
            connectingSince: now.addingTimeInterval(-120),
            now: now
        ))
    }

    func testShouldForceReconnectFalseWhenNotConnectingEvenWithOldTimestamp() {
        let now = Date()
        XCTAssertFalse(PetModel.shouldForceReconnect(
            isConnecting: false,
            connectingSince: now.addingTimeInterval(-3600),
            now: now
        ))
    }

    func testShouldForceReconnectFalseWhenConnectingSinceIsNil() {
        let now = Date()
        XCTAssertFalse(PetModel.shouldForceReconnect(
            isConnecting: true,
            connectingSince: nil,
            now: now
        ))
    }

    // MARK: - WSClientSnapshot JSON round-trip

    func testWSClientSnapshotRoundTripPreservesAllFields() throws {
        let original = OpenClawWSClient.WSClientSnapshot(
            role: "pet",
            connected: true,
            generation: 7,
            connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastFrameAgeSeconds: 12.5,
            pid: 4242,
            processStartedAt: Date(timeIntervalSince1970: 1_699_999_000),
            connectAttempts: 4,
            closeFramesSent: 3
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenClawWSClient.WSClientSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testWSClientSnapshotRoundTripPreservesNilFrameAge() throws {
        let original = OpenClawWSClient.WSClientSnapshot(
            role: "ingest",
            connected: false,
            generation: 0,
            connectedAt: nil,
            lastFrameAgeSeconds: nil,
            pid: 1,
            processStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            connectAttempts: 0,
            closeFramesSent: 0
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenClawWSClient.WSClientSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.lastFrameAgeSeconds)
    }

    // MARK: - Gateway socket URLSession timeouts (2026-09-22 heartbeat-timeout fix)

    /// Guards against silently reintroducing a short HTTP-style timeout pair
    /// (15s/60s) on a socket meant to stay open for hours between the
    /// Gateway's 25s pings. See the comments above these constants in
    /// OpenClawWSClient.swift for the measurement that motivated the values.
    func testWebSocketInactivityTimeoutIsWellAboveGatewayPingCadence() {
        XCTAssertGreaterThanOrEqual(OpenClawWSClient.webSocketInactivityTimeout, 300)
    }

    func testWebSocketLifetimeCapIsEffectivelyUnbounded() {
        // Larger than any plausible connection lifetime (10+ years), so it
        // cannot act as a periodic forced-disconnect timer in practice.
        XCTAssertGreaterThan(OpenClawWSClient.webSocketLifetimeCap, 60 * 60 * 24 * 365 * 5)
    }
}
