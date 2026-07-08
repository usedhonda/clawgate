import CoreAudio
import XCTest
@testable import ClawGate

final class MicrophoneDeviceServiceTests: XCTestCase {
    func testResolveAudioDeviceIDReturnsNilForMissingUID() {
        XCTAssertNil(MicrophoneDeviceService.resolveAudioDeviceID(uid: "clawgate.tests.missing-mic-device"))
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
