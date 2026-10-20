import CoreAudio
import Foundation

/// Reads and writes the system output volume through CoreAudio.
///
/// The Python version shelled out to `osascript`; going straight to the HAL keeps
/// it in-process and avoids an AppleEvents round trip at the moment we most want
/// things to be snappy.
enum SystemVolume {

    /// Current output volume in 0...1, or nil if the default device has no
    /// settable volume (some aggregate and digital-out devices don't).
    static func current() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        for element in volumeElements(of: device) {
            if let level = scalar(device: device, element: element) { return level }
        }
        return nil
    }

    /// Sets output volume (0...1) and clears mute. Returns false if nothing took.
    @discardableResult
    static func set(_ level: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        let clamped = max(0, min(1, level))
        var wroteSomething = false
        for element in volumeElements(of: device) {
            if setScalar(clamped, device: device, element: element) { wroteSomething = true }
        }
        setMuted(false, device: device)
        return wroteSomething
    }

    // MARK: - Device

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return (status == noErr && device != kAudioObjectUnknown) ? device : nil
    }

    /// The main element first, then the left/right channels. Devices expose one
    /// or the other, so every caller walks the whole list.
    private static func volumeElements(of device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        [kAudioObjectPropertyElementMain, 1, 2]
    }

    // MARK: - Volume

    private static func volumeAddress(_ element: AudioObjectPropertyElement)
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func scalar(
        device: AudioDeviceID, element: AudioObjectPropertyElement
    ) -> Float? {
        var address = volumeAddress(element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var level = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level)
        return status == noErr ? level : nil
    }

    private static func setScalar(
        _ level: Float, device: AudioDeviceID, element: AudioObjectPropertyElement
    ) -> Bool {
        var address = volumeAddress(element)
        guard AudioObjectHasProperty(device, &address) else { return false }

        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue
        else { return false }

        var value = level
        let size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    // MARK: - Mute

    private static func setMuted(_ muted: Bool, device: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return }

        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue
        else { return }

        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }
}
