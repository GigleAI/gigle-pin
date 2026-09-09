import CoreAudio
import Foundation

/// Where the computer's sound is coming out, and therefore whether the microphone can hear it.
///
/// **The question is not "headphones?" — it is "is there air between the speaker and the mic?"**
/// Recording the microphone and the computer's audio together over loudspeakers records the same
/// sound twice: once clean, straight from ScreenCaptureKit, and once through the room, five to
/// twenty milliseconds later and carrying the room with it. `AudioMixdown` then sums the two tracks
/// and the result is comb filtering — hollow, distant, "speaking into a bucket". Nothing howls,
/// because the microphone is never played back; it is simply doubled.
///
/// So this reports **only what it is sure of**, and everything else is silence:
///   - built-in speakers, or a display over HDMI / DisplayPort → there is air, say so
///   - the built-in device switched to the headphone jack (`hdpn`) → no air
///   - Bluetooth → almost always earbuds; a Bluetooth speaker exists but is rare enough that
///     warning everyone with AirPods costs more than it saves
///   - **USB → unknown.** A USB headset and a USB desk speaker are indistinguishable here.
///   - **virtual devices → no air at all.** This is not a corner case: a working machine can carry
///     nine of them (Zoom, Teams, WeMeet, Lark, BlackHole, screen-share tools). Sound routed into
///     one of those never reaches a microphone.
///
/// Silence when unsure is the same rule the hotkey conflict list follows: a warning that fires when
/// it cannot tell teaches people to ignore warnings, and then the one that matters is ignored too.
enum AudioRoute {

    /// True only when the computer's sound is audibly coming out of a loudspeaker in the room.
    static var isLoudspeakerAudible: Bool {
        guard let dev = defaultOutput() else { return false }
        guard playsIntoTheRoom(dev) else { return false }
        // Muted or silent is the same as headphones for our purposes: nothing for the microphone to
        // pick up. Devices that expose no volume control are treated as audible — not knowing the
        // volume is not a reason to assume it is zero.
        if let muted = u32(dev, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput), muted == 1 {
            return false
        }
        if let v = volume(dev), v <= 0.01 { return false }
        return true
    }

    /// What the current output is, for `pin://version` — so a check can confirm the detection ran
    /// and what it decided, rather than inferring it from whether a tip happened to appear.
    static func describe() -> String {
        guard let dev = defaultOutput() else { return "unknown" }
        let transport = fourCC(u32(dev, kAudioDevicePropertyTransportType) ?? 0)
        let source = u32(dev, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
            .map { fourCC($0) } ?? "-"
        return "\(transport)/\(source)\(isLoudspeakerAudible ? " loudspeaker" : "")"
    }

    // MARK: - CoreAudio

    private static func playsIntoTheRoom(_ dev: AudioObjectID) -> Bool {
        switch u32(dev, kAudioDevicePropertyTransportType) ?? 0 {
        case kAudioDeviceTransportTypeBuiltIn:
            // The built-in device is both the speakers and the headphone jack; the data source says
            // which one is live. `ispk` is the internal speaker. A built-in device that does not
            // report a source is a speaker as far as we know.
            guard let src = u32(dev, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
            else { return true }
            return fourCC(src) != "hdpn"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return true
        default:
            return false
        }
    }

    private static func defaultOutput() -> AudioObjectID? {
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return nil }
        return dev
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func u32(_ dev: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(selector, scope: scope)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func volume(_ dev: AudioObjectID) -> Float32? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
                     UInt8((value >> 8) & 255), UInt8(value & 255)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
    }
}
