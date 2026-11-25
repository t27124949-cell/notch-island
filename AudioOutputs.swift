import CoreAudio
import Foundation

struct AudioOutput {
    let id: AudioDeviceID
    let name: String
}

/// Lists the Mac's sound outputs and switches the default one (speakers, AirPods, other Bluetooth, HDMI…).
enum AudioOutputs {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func list() -> [AudioOutput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in hasOutput(id) ? AudioOutput(id: id, name: name(of: id)) : nil }
    }

    static func currentID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id)
        return id
    }

    static func setDefault(_ id: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = id
        AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &device)
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func name(of id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cfName)
        guard status == noErr, let value = cfName?.takeRetainedValue() else { return "Audio device" }
        return value as String
    }
}
