import XCTest
@testable import ClawGate

/// The microphone ClawGate asks for and the one AVAudioEngine records from can
/// differ. On 2026-09-02 the built-in microphone was selected and persisted,
/// yet the live input moved back to the system default -- AirPods -- and the
/// AirPods dropped to hands-free mono. Nothing reported it.
///
/// These tests pin the two decisions that make that visible and recoverable:
/// how requested-versus-actual is classified, and when the health monitor acts.
final class AmbientInputDeviceDriftTests: XCTestCase {

    // MARK: - Classification

    /// Nothing selected: the system default is used on purpose, never "drift".
    func testNoRequestIsNotDrift() {
        XCTAssertEqual(
            AmbientCaptureManager.classifyDeviceApplication(requestedUID: nil, actualUID: "BuiltInMicrophoneDevice"),
            .notRequested
        )
        XCTAssertEqual(
            AmbientCaptureManager.classifyDeviceApplication(requestedUID: "", actualUID: "BuiltInMicrophoneDevice"),
            .notRequested
        )
    }

    func testEngineOnRequestedDeviceIsMatched() {
        XCTAssertEqual(
            AmbientCaptureManager.classifyDeviceApplication(
                requestedUID: "BuiltInMicrophoneDevice",
                actualUID: "BuiltInMicrophoneDevice"
            ),
            .matched
        )
    }

    /// The incident shape: built-in requested, engine on the headset.
    func testEngineOnAnotherDeviceIsDrift() {
        XCTAssertEqual(
            AmbientCaptureManager.classifyDeviceApplication(
                requestedUID: "BuiltInMicrophoneDevice",
                actualUID: "00-11-22-33-44-55:input"
            ),
            .drifted
        )
    }

    /// A requested device the engine cannot even report is not a match.
    func testUnreadableActualDeviceIsDriftWhenSomethingWasRequested() {
        XCTAssertEqual(
            AmbientCaptureManager.classifyDeviceApplication(requestedUID: "BuiltInMicrophoneDevice", actualUID: nil),
            .drifted
        )
    }

    // MARK: - Health monitor decision

    private func status(
        streaming: Bool = true,
        captureState: String = "capturing",
        liveness: String = "live",
        drifted: Bool = false,
        requested: String? = "BuiltInMicrophoneDevice",
        actualName: String? = "MacBook Pro Microphone"
    ) -> AmbientController.Status {
        AmbientController.Status(
            role: "client",
            available: true,
            captureState: captureState,
            streaming: streaming,
            micAuthorization: "authorized",
            whisperAvailable: true,
            diarizerAvailable: true,
            sessionID: "ctx-test",
            segmentsTotal: 0,
            segmentsSkipped: 0,
            pendingChunks: 0,
            lastText: nil,
            lastError: nil,
            ingestSent: 0,
            ingestLastError: nil,
            captureLiveness: liveness,
            secondsSinceLastTap: liveness == "wedged" ? 45 : 0,
            secondsSinceLastChunk: 0,
            chunksSurfaced: 3,
            recoveryCount: 0,
            lastRecoveryReason: nil,
            requestedInputDeviceUID: requested,
            actualInputDeviceUID: drifted ? "00-11-22-33-44-55:input" : requested,
            actualInputDeviceName: actualName,
            inputDeviceDrifted: drifted
        )
    }

    func testHealthyCaptureNeedsNoRecovery() {
        XCTAssertNil(AmbientHealthMonitor.recoveryReason(for: status()))
    }

    /// The pre-existing behaviour: a stale tap is still recovered.
    func testWedgedCaptureIsRecovered() {
        let reason = AmbientHealthMonitor.recoveryReason(for: status(liveness: "wedged"))
        XCTAssertEqual(reason, "health-monitor: tap stale 45s")
    }

    /// Audio still flows, so this is not a wedge -- but it is the wrong audio.
    func testDriftedInputIsRecoveredEvenWhileLive() {
        let reason = AmbientHealthMonitor.recoveryReason(
            for: status(liveness: "live", drifted: true, actualName: "AirPods")
        )
        XCTAssertEqual(
            reason,
            "health-monitor: input drifted (requested BuiltInMicrophoneDevice, engine on AirPods)"
        )
    }

    func testDriftReasonFallsBackToUIDWhenNameUnknown() {
        let reason = AmbientHealthMonitor.recoveryReason(
            for: status(liveness: "live", drifted: true, actualName: nil)
        )
        XCTAssertEqual(
            reason,
            "health-monitor: input drifted (requested BuiltInMicrophoneDevice, engine on 00-11-22-33-44-55:input)"
        )
    }

    /// Liveness is only measured while streaming, so a stale tap on a stopped
    /// stream means nothing and must not trigger a recover.
    func testWedgeIsIgnoredWhenNotStreaming() {
        XCTAssertNil(AmbientHealthMonitor.recoveryReason(for: status(streaming: false, liveness: "wedged")))
    }

    /// The stream can stop while the microphone stays open. Drift then is still
    /// the wrong microphone -- and still AirPods in mono -- so it is recovered.
    func testDriftIsRecoveredWhileCapturingEvenWithStreamStopped() {
        let reason = AmbientHealthMonitor.recoveryReason(
            for: status(streaming: false, drifted: true, actualName: "AirPods")
        )
        XCTAssertEqual(
            reason,
            "health-monitor: input drifted (requested BuiltInMicrophoneDevice, engine on AirPods)"
        )
    }

    /// With the microphone closed there is no live device to be wrong.
    func testNothingIsRecoveredWhenNotCapturing() {
        XCTAssertNil(AmbientHealthMonitor.recoveryReason(
            for: status(streaming: false, captureState: "idle", drifted: true)
        ))
        XCTAssertNil(AmbientHealthMonitor.recoveryReason(
            for: status(streaming: false, captureState: "paused", drifted: true)
        ))
    }
}
