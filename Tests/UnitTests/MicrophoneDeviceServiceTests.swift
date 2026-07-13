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

    func testCaptureManagerFailsSoftWhenPreferredDeviceCannotResolve() {
        var logs: [String] = []
        let resolved = AmbientCaptureManager.resolvePreferredDeviceIDForCapture(
            uid: "clawgate.tests.missing-mic-device",
            resolver: { _ in nil },
            log: { logs.append($0) }
        )

        XCTAssertNil(resolved)
        XCTAssertEqual(logs, ["ambient capture selected mic not found; using system default"])
    }

    func testCaptureManagerResolvesPreferredDeviceWhenAvailable() {
        let expected = AudioDeviceID(42)
        let resolved = AmbientCaptureManager.resolvePreferredDeviceIDForCapture(
            uid: "clawgate.tests.mic-device",
            resolver: { uid in uid == "clawgate.tests.mic-device" ? expected : nil },
            log: { _ in XCTFail("resolver success should not log fallback") }
        )

        XCTAssertEqual(resolved, expected)
    }
}
