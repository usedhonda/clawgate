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

    // MARK: - Helpers

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
