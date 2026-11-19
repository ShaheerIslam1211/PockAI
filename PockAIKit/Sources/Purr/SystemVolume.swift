import AppKit
import CoreAudio
import AudioToolbox
import Foundation

// System output volume and mute straight from Core Audio, with change notifications
// (replaces AppleScript polling, which compiled a script every couple of seconds).
enum SystemVolume {
    private static var device: AudioObjectID {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return dev
    }

    private static var volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    static func read() -> (level: Int, muted: Bool) {
        let dev = device
        var vol = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(dev, &volumeAddress, 0, nil, &size, &vol)
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(dev, &muteAddress, 0, nil, &size, &mute)
        return (Int((vol * 100).rounded()), mute != 0)
    }

    static func set(level: Int) {
        let dev = device
        var vol = Float32(max(0, min(100, level))) / 100
        AudioObjectSetPropertyData(dev, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
        setMuted(level == 0)
    }

    static func setMuted(_ muted: Bool) {
        let dev = device
        var mute = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(dev, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute)
    }

    // Calls `changed` on the main queue whenever volume, mute or the output device changes.
    private static var watchedDevice = AudioObjectID(kAudioObjectUnknown)
    private static var onChange: (() -> Void)?
    private static let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange?() }
    private static let deviceListener: AudioObjectPropertyListenerBlock = { _, _ in
        rewatch()
        onChange?()
    }

    static func observe(_ changed: @escaping () -> Void) {
        onChange = changed
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, deviceListener)
        rewatch()
    }

    private static func rewatch() {
        if watchedDevice != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(watchedDevice, &volumeAddress, .main, listener)
            AudioObjectRemovePropertyListenerBlock(watchedDevice, &muteAddress, .main, listener)
        }
        watchedDevice = device
        AudioObjectAddPropertyListenerBlock(watchedDevice, &volumeAddress, .main, listener)
        AudioObjectAddPropertyListenerBlock(watchedDevice, &muteAddress, .main, listener)
    }
}
