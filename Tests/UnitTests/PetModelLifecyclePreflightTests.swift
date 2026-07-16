import XCTest

@testable import ClawGate

final class PetModelLifecyclePreflightTests: XCTestCase {
    private var originalLogStoreDir = ""

    override func setUp() {
        super.setUp()
        PetLogStore.testIsolationSemaphore.wait()
        originalLogStoreDir = PetLogStore.dir
        PetLogStore.dir = NSTemporaryDirectory() + "clawgate-test-logs-"
            + UUID().uuidString
        do {
            try FileManager.default.createDirectory(
                atPath: PetLogStore.dir,
                withIntermediateDirectories: true
            )
        } catch {
            XCTFail("Failed to prepare isolated PetLogStore dir: \(error)")
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: PetLogStore.dir)
        PetLogStore.dir = originalLogStoreDir
        PetLogStore.testIsolationSemaphore.signal()
        super.tearDown()
    }

    func testNonLogSummonDoesNotBlockLogAfterReconnect() {
        let model = PetModel()
        model.handleEvent(.connected(sessionId: "session-1", sessionKey: "ws-key-1"))
        model.setSessionKeyForTesting("ws-key-1")
        waitForMain()

        model.pendingSummonSource = "log_scene_naming"
        model.pendingSummonRunId = nil

        XCTAssertTrue(model.isSummonBusy, "scene naming should enter summon path")

        model.handleEvent(.disconnected(reason: nil))
        waitForMain()

        // Reconnect to a fresh gateway path; old behavior could keep non-log summon
        // state and make log summon appear busy on first click after reconnect.
        model.handleEvent(.connected(sessionId: "session-2", sessionKey: "ws-key-2"))
        waitForMain()
        model.setSessionKeyForTesting("ws-key-2")
        model.suppressLogSendForTesting = true
        waitForMain()
        XCTAssertFalse(
            model.isSummonBusy,
            "non-log summon should have been cleared on disconnect to avoid stale blocking"
        )

        model.sendLogInstruction(envelope: makeLogEnvelope())

        let logErrorEntries = model.logReplies.filter { $0.source == "log" }
        XCTAssertEqual(logErrorEntries.count, 0)

        let userEntries = model.logReplies.filter { $0.source == "log_user" }
        XCTAssertEqual(userEntries.count, 1)
        XCTAssertTrue(userEntries.first?.text.contains("今の会話要約を作って") ?? false)
    }

    private func waitForMain() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func makeLogEnvelope() -> PetLogQueryEnvelope {
        PetLogQueryEnvelope(
            requestId: UUID().uuidString,
            actionId: "action-1",
            instruction: "今の会話要約を作って",
            queryTimestamp: Date(),
            anchorTimestamp: Date(),
            scopeOverride: nil,
            coverageStart: nil,
            coverageEnd: nil,
            completeBeforeAnchor: true,
            segments: []
        )
    }
}
