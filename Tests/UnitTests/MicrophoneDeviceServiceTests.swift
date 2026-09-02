import CoreAudio
import XCTest
@testable import ClawGate

final class MicrophoneDeviceServiceTests: XCTestCase {
    func testResolveAudioDeviceIDReturnsNilForMissingUID() {
        XCTAssertNil(MicrophoneDeviceService.resolveAudioDeviceID(uid: "clawgate.tests.missing-mic-device"))
    }

    func testResolveSystemDefaultInputDeviceNameFallsBackWhenDefaultInputMissing() {
        let defaultName = MicrophoneDeviceService.resolveSystemDefaultInputDeviceName(
            defaultInputDeviceID: { nil },
            resolveAudioDeviceName: { _ in "should not be called" }
        )
        XCTAssertNil(defaultName)
    }

    func testResolveSystemDefaultInputDeviceNameUsesInjectedDependencies() {
        var calledDefaultIDResolver = false
        var calledNameResolver = false
        let defaultName = MicrophoneDeviceService.resolveSystemDefaultInputDeviceName(
            defaultInputDeviceID: {
                calledDefaultIDResolver = true
                return AudioDeviceID(42)
            },
            resolveAudioDeviceName: { deviceID in
                calledNameResolver = true
                XCTAssertEqual(deviceID, 42)
                return "USB Mic"
            }
        )
        XCTAssertTrue(calledDefaultIDResolver)
        XCTAssertTrue(calledNameResolver)
        XCTAssertEqual(defaultName, "USB Mic")
    }

    func testSystemDefaultMenuTitleFormatsName() {
        XCTAssertEqual(MicrophoneDeviceService.systemDefaultMenuTitle(for: "Built-in Microphone"), "System Default (Built-in Microphone)")
        XCTAssertEqual(MicrophoneDeviceService.systemDefaultMenuTitle(for: nil), "System Default")
    }

    /// The selected microphone not being present has always meant "use the
    /// system default", quietly. That is the only start failure handled by
    /// falling back; anything else is a failed start and is reported as one.
    func testMissingSelectedMicFallsBackToSystemDefault() {
        XCTAssertTrue(AmbientCaptureManager.shouldFallBackToDefault(
            afterStartFailure: AmbientCaptureBackend.BackendError.deviceNotFound("clawgate.tests.missing-mic-device"),
            requestedUID: "clawgate.tests.missing-mic-device"
        ))
    }

    func testOtherStartFailuresDoNotFallBack() {
        XCTAssertFalse(AmbientCaptureManager.shouldFallBackToDefault(
            afterStartFailure: AmbientCaptureBackend.BackendError.cannotAddOutput,
            requestedUID: "clawgate.tests.mic-device"
        ))
        XCTAssertFalse(AmbientCaptureManager.shouldFallBackToDefault(
            afterStartFailure: AmbientCaptureBackend.BackendError.noDefaultInput,
            requestedUID: "clawgate.tests.mic-device"
        ))
    }

    /// With nothing selected there is nothing to fall back from.
    func testNoSelectionNeverFallsBack() {
        XCTAssertFalse(AmbientCaptureManager.shouldFallBackToDefault(
            afterStartFailure: AmbientCaptureBackend.BackendError.deviceNotFound(""),
            requestedUID: nil
        ))
    }
}
