import CoreAudio

/// The microphone a recording came from.
public struct InputDevice: Sendable, Equatable {
    public enum Transport: String, Sendable, Equatable {
        case builtIn = "built-in"
        case bluetooth = "Bluetooth"
        case usb = "USB"
        case virtual
        case aggregate
        case other
    }

    public var name: String
    public var transport: Transport
    /// The device's own format, before conversion to 16 kHz mono.
    public var sampleRate: Double
    public var channelCount: Int

    /// Opening a Bluetooth headset's mic switches it to the low-quality call profile
    /// (BUILD_PLAN.md §5, gotcha 11).
    public var isBluetooth: Bool { transport == .bluetooth }

    /// The system default input, which `AVAudioEngine` records from.
    static func systemDefault(sampleRate: Double, channelCount: Int) -> InputDevice {
        let id = CoreAudioQuery.defaultInputDevice()
        return InputDevice(
            name: id.flatMap(CoreAudioQuery.name(of:)) ?? "Default input",
            transport: id.flatMap(CoreAudioQuery.transportType(of:)).map(Transport.init(coreAudio:)) ?? .other,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }
}

private extension InputDevice.Transport {
    init(coreAudio type: UInt32) {
        switch type {
        case UInt32(kAudioDeviceTransportTypeBuiltIn): self = .builtIn
        case UInt32(kAudioDeviceTransportTypeBluetooth), UInt32(kAudioDeviceTransportTypeBluetoothLE): self = .bluetooth
        case UInt32(kAudioDeviceTransportTypeUSB): self = .usb
        case UInt32(kAudioDeviceTransportTypeVirtual): self = .virtual
        case UInt32(kAudioDeviceTransportTypeAggregate), UInt32(kAudioDeviceTransportTypeAutoAggregate): self = .aggregate
        default: self = .other
        }
    }
}

private enum CoreAudioQuery {
    static func defaultInputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    static func transportType(of device: AudioDeviceID) -> UInt32? {
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &type)
        return status == noErr ? type : nil
    }
}
