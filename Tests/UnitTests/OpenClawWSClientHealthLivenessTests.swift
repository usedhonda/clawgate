import XCTest
@testable import ClawGate

/// Guards the raw-WS-ping -> health req/res liveness migration (mirrored from
/// VibeTerm OpenClawWebSocketClient.swift per docs/refactor/20-untouchable-map.md
/// U4). The Gateway ignores raw WS ping frames by contract
/// (oc-general docs/contracts/ws-event-contract.md:60-69) — a raw-ping deadline
/// is a guaranteed, self-inflicted ~25-30s reconnect churn (docs/log/codex/184).
final class OpenClawWSClientHealthLivenessTests: XCTestCase {

    /// Static guard: the raw WS ping API must never be reintroduced. The
    /// Gateway silently drops it, so any reintroduction reproduces the
    /// chronic ping-timeout churn this migration fixed.
    func testNoRawWebSocketPingUsage() throws {
        let path = "\(sourceRoot())/ClawGate/Core/OpenClaw/OpenClawWSClient.swift"
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(source.contains(".sendPing("), "raw WS ping must not be reintroduced — Gateway ignores it by contract")
        XCTAssertFalse(source.contains("pongReceiveHandler"), "raw WS pong handling must not be reintroduced")
    }

    func testStaleGenerationHealthTimeoutIsIgnored() async throws {
        let client = OpenClawWSClient()
        await client.setConnectionGeneration(5)
        let requestId = "req-stale"

        let resultTask = Task<Error?, Never> {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task {
                        await client.seedHealthAck(requestId: requestId, continuation: continuation)
                        // Old generation (3) — must early-return without touching the ack.
                        await client.handleHealthTimeout(generation: 3, requestId: requestId)
                        // Resolve the still-pending continuation from the test side so the
                        // outer await doesn't hang; the assertion is on gen/ack survival below.
                        await client.failPendingHealthAckForTest(requestId: requestId)
                    }
                }
                return nil
            } catch {
                return error
            }
        }
        _ = await resultTask.value

        let genAfter = await client.connectionGeneration
        XCTAssertEqual(genAfter, 5, "a stale-generation timeout must not teardown the current connection")
    }

    func testHealthTimeoutVetoedByRecentFrame() async throws {
        let client = OpenClawWSClient()
        await client.setConnectionGeneration(1)
        await client.setLastFrameReceivedAt(Date())
        let requestId = "req-fresh"

        let resultTask = Task<Error?, Never> {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task {
                        await client.seedHealthAck(requestId: requestId, continuation: continuation)
                        await client.handleHealthTimeout(generation: 1, requestId: requestId)
                    }
                }
                return nil
            } catch {
                return error
            }
        }
        let error = await resultTask.value

        XCTAssertNotNil(error, "the ack still fails so the caller doesn't hang")
        let genAfter = await client.connectionGeneration
        XCTAssertEqual(genAfter, 1, "a recent frame must veto the kill — connection must survive")
        let consecutiveAfter = await client.consecutiveHealthTimeouts
        XCTAssertEqual(consecutiveAfter, 0, "veto path must not increment the consecutive-timeout counter")
    }

    func testHealthTimeoutRequiresTwoConsecutiveBeforeTeardown() async throws {
        let client = OpenClawWSClient()
        await client.setConnectionGeneration(1)
        await client.setLastFrameReceivedAt(Date.distantPast) // no recent frame -> no veto

        // First timeout: counted, but must not kill yet.
        await withHealthAckContinuation(client: client, requestId: "req-1") { requestId in
            await client.handleHealthTimeout(generation: 1, requestId: requestId)
        }
        var genAfterFirst = await client.connectionGeneration
        XCTAssertEqual(genAfterFirst, 1, "first timeout alone must not teardown a live connection")
        let consecutive = await client.consecutiveHealthTimeouts
        XCTAssertEqual(consecutive, 1)

        // Second consecutive timeout: must teardown (generation bumps).
        await withHealthAckContinuation(client: client, requestId: "req-2") { requestId in
            await client.handleHealthTimeout(generation: 1, requestId: requestId)
        }
        genAfterFirst = await client.connectionGeneration
        XCTAssertEqual(genAfterFirst, 2, "second consecutive timeout must teardown (generation bumps)")
    }

    func testHealthSuccessResetsConsecutiveTimeoutCounter() async throws {
        let client = OpenClawWSClient()
        await client.setConnectionGeneration(9)
        await client.setLastFrameReceivedAt(Date.distantPast)

        await withHealthAckContinuation(client: client, requestId: "req-1") { requestId in
            await client.handleHealthTimeout(generation: 9, requestId: requestId)
        }
        var consecutive = await client.consecutiveHealthTimeouts
        XCTAssertEqual(consecutive, 1)

        await client.handleHealthSuccess(generation: 9)
        consecutive = await client.consecutiveHealthTimeouts
        XCTAssertEqual(consecutive, 0, "a successful health round-trip must reset the consecutive-timeout counter")
    }


    func testReadinessRejectsConcurrentConnectAndReleasesFailedAttempt() async {
        let entered = expectation(description: "first readiness probe suspended")
        let probe = ControlledReadinessProbe(suspendedAttempts: 1) { _ in entered.fulfill() }
        let client = OpenClawWSClient(readinessProbe: { _ in try await probe.wait() })
        let first = Task { await self.connectionError(client) }
        await fulfillment(of: [entered], timeout: 5)

        let overlappingError = await connectionError(client)
        XCTAssertTrue(isConnectionRejection(overlappingError),
                      "a second connect must be rejected before another readiness probe")
        let probeCount = await probe.attemptCount
        XCTAssertEqual(probeCount, 1)

        await probe.resolve(1, with: .failure(ReadinessFailure.notReady))
        let firstError = await first.value
        XCTAssertEqual(firstError as? ReadinessFailure, .notReady)

        // A failed attempt releases its reservation. The retry reaches the
        // synthetic probe and fails there without opening a WebSocket.
        let retryError = await connectionError(client)
        XCTAssertEqual(retryError as? ReadinessFailure, .unexpectedProbe)
        let state = await client.snapshot()
        XCTAssertEqual(state.connectAttempts, 2)
        XCTAssertFalse(state.connected)
        XCTAssertNil(state.connectedAt)
        await client.disconnect()
    }

    func testCancelledReadinessCannotOpenSocketWhenProbeCompletesLate() async {
        let entered = expectation(description: "readiness probe suspended")
        let probe = ControlledReadinessProbe(suspendedAttempts: 1) { _ in entered.fulfill() }
        let client = OpenClawWSClient(readinessProbe: { _ in try await probe.wait() })
        let attempt = Task { await self.connectionError(client) }
        await fulfillment(of: [entered], timeout: 5)

        attempt.cancel()
        // Deliberately ignore cancellation inside the controlled probe, like a
        // readiness response already queued when cancellation arrives.
        await probe.resolve(1, with: .success(()))
        let error = await attempt.value
        XCTAssertTrue(error is CancellationError)
        let state = await client.snapshot()
        XCTAssertFalse(state.connected)
        XCTAssertNil(state.connectedAt)
        XCTAssertEqual(state.closeFramesSent, 0)
        await client.disconnect()
    }

    func testDisconnectedReadinessCannotConsumeOrReleaseReplacementAttempt() async {
        let oldEntered = expectation(description: "old readiness probe suspended")
        let newEntered = expectation(description: "replacement readiness probe suspended")
        let probe = ControlledReadinessProbe(suspendedAttempts: 2) { attempt in
            if attempt == 1 { oldEntered.fulfill() } else { newEntered.fulfill() }
        }
        let client = OpenClawWSClient(readinessProbe: { _ in try await probe.wait() })
        let old = Task { await self.connectionError(client) }
        await fulfillment(of: [oldEntered], timeout: 5)
        await client.disconnect()
        let replacement = Task { await self.connectionError(client) }
        await fulfillment(of: [newEntered], timeout: 5)
        let currentGeneration = await client.connectionGeneration

        await probe.resolve(1, with: .success(()))
        let oldError = await old.value
        XCTAssertTrue(oldError is CancellationError)
        let state = await client.snapshot()
        XCTAssertEqual(state.generation, currentGeneration)
        XCTAssertFalse(state.connected)
        XCTAssertNil(state.connectedAt)

        let overlappingError = await connectionError(client)
        XCTAssertTrue(isConnectionRejection(overlappingError),
                      "a stale completion must not release the replacement reservation")
        let probeCount = await probe.attemptCount
        XCTAssertEqual(probeCount, 2)
        await probe.resolve(2, with: .failure(ReadinessFailure.notReady))
        let replacementError = await replacement.value
        XCTAssertEqual(replacementError as? ReadinessFailure, .notReady)
        await client.disconnect()
    }

    // MARK: - Helpers

    private func connectionError(_ client: OpenClawWSClient) async -> Error? {
        do {
            _ = try await client.connect(url: URL(string: "ws://127.0.0.1:1/")!, token: "test-token")
            return nil
        } catch {
            return error
        }
    }

    private func isConnectionRejection(_ error: Error?) -> Bool {
        guard let error = error as? OpenClawError else { return false }
        if case .connectionFailed = error { return true }
        return false
    }

    private func withHealthAckContinuation(
        client: OpenClawWSClient, requestId: String, _ body: @escaping (String) async -> Void
    ) async {
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task {
                await client.seedHealthAck(requestId: requestId, continuation: continuation)
                await body(requestId)
            }
        }
    }

    private func sourceRoot() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }
}


private enum ReadinessFailure: Error, Equatable { case notReady, unexpectedProbe }

/// Controls readiness completions instead of sleeping or using a live server.
/// Unexpected extra probes fail immediately rather than wait on an unowned
/// continuation.
private actor ControlledReadinessProbe {
    private let suspendedAttempts: Int
    private let onEntered: @Sendable (Int) -> Void
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private(set) var attemptCount = 0

    init(suspendedAttempts: Int, onEntered: @escaping @Sendable (Int) -> Void) {
        self.suspendedAttempts = suspendedAttempts
        self.onEntered = onEntered
    }

    func wait() async throws {
        attemptCount += 1
        let attempt = attemptCount
        guard attempt <= suspendedAttempts else { throw ReadinessFailure.unexpectedProbe }
        try await withCheckedThrowingContinuation { continuation in
            pending[attempt] = continuation
            onEntered(attempt)
        }
    }

    func resolve(_ attempt: Int, with result: Result<Void, Error>) {
        pending.removeValue(forKey: attempt)?.resume(with: result)
    }
}

extension OpenClawWSClient {
    func setConnectionGeneration(_ value: UInt64) { connectionGeneration = value }
    func setLastFrameReceivedAt(_ value: Date) { lastFrameReceivedAt = value }
    func seedHealthAck(requestId: String, continuation: CheckedContinuation<Void, Error>) {
        inFlightHealthAcks[requestId] = continuation
    }
    func failPendingHealthAckForTest(requestId: String) {
        inFlightHealthAcks.removeValue(forKey: requestId)?.resume(throwing: OpenClawError.timeout)
    }
}
