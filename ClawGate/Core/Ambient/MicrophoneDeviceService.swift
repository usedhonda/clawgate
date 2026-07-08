import AVFoundation
import CoreAudio
import Foundation

enum MicrophoneDeviceService {
    struct MicrophoneDevice: Identifiable, Equatable {
        let uid: String
        let name: String

        var id: String { uid }
    }

    static func listInputDevices() -> [MicrophoneDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        var seen = Set<String>()
        return session.devices.compactMap { device in
            guard !device.uniqueID.isEmpty, seen.insert(device.uniqueID).inserted else { return nil }
            return MicrophoneDevice(uid: device.uniqueID, name: device.localizedName)
        }
        .sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder == .orderedSame { return $0.uid < $1.uid }
            return nameOrder == .orderedAscending
        }
    }

    static func resolveAudioDeviceID(uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return nil }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return nil }

        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidValue: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = AudioObjectGetPropertyData(
                deviceID,
                &uidAddress,
                0,
                nil,
                &uidSize,
                &uidValue
            )
            if status == noErr, uidValue?.takeRetainedValue() as String? == uid {
                return deviceID
            }
        }
        return nil
    }
}
