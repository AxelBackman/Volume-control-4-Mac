import CoreAudio
import Foundation

/// Queries about the physical output device the mixer has to feed.
enum SystemOutput {

    static func defaultOutputDeviceID() throws -> AudioObjectID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice,
                                      as: AudioObjectID.self,
                                      context: "read default output device")
    }

    static func uid(of device: AudioObjectID) throws -> String {
        try device.readString(kAudioDevicePropertyDeviceUID)
    }

    static func name(of device: AudioObjectID) -> String {
        (try? device.readString(kAudioObjectPropertyName)) ?? "Unknown device"
    }

    static func nominalSampleRate(of device: AudioObjectID) throws -> Double {
        try device.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self)
    }

    // MARK: - Device volume

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        address(kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: kAudioObjectPropertyElementMain)
    }

    /// Whether the device exposes a software volume control. Many USB headsets - the Arctis
    /// range among them - do their volume in hardware and expose nothing here.
    static func hasSoftwareVolume(_ device: AudioObjectID) -> Bool {
        var addr = volumeAddress()
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func volume(of device: AudioObjectID) -> Float? {
        try? device.read(kAudioDevicePropertyVolumeScalar,
                         scope: kAudioDevicePropertyScopeOutput,
                         as: Float32.self)
    }

    static func setVolume(_ volume: Float, on device: AudioObjectID) {
        var addr = volumeAddress()
        var value = Float32(max(0, min(1, volume)))
        let status = AudioObjectSetPropertyData(device, &addr, 0, nil,
                                                UInt32(MemoryLayout<Float32>.size), &value)
        if status != noErr {
            log.error("setting device volume failed: \(status.fourCharDescription)")
        }
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        ((try? device.read(kAudioDevicePropertyMute,
                           scope: kAudioDevicePropertyScopeOutput,
                           as: UInt32.self)) ?? 0) != 0
    }

    static func hasMute(_ device: AudioObjectID) -> Bool {
        var addr = address(kAudioDevicePropertyMute,
                           scope: kAudioDevicePropertyScopeOutput,
                           element: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func setMuted(_ muted: Bool, on device: AudioObjectID) {
        var addr = address(kAudioDevicePropertyMute,
                           scope: kAudioDevicePropertyScopeOutput,
                           element: kAudioObjectPropertyElementMain)
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &addr, 0, nil,
                                                UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr {
            log.error("setting device mute failed: \(status.fourCharDescription)")
        }
    }

    struct LatencyReport {
        var bufferFrames: UInt32
        var deviceLatency: UInt32
        var safetyOffset: UInt32
        var streamLatency: UInt32

        var totalFrames: UInt32 { bufferFrames + deviceLatency + safetyOffset + streamLatency }
        func milliseconds(at sampleRate: Double) -> Double {
            sampleRate > 0 ? Double(totalFrames) / sampleRate * 1000 : 0
        }
    }

    /// Everything the HAL charges for output on a device, in frames.
    static func latencyReport(of device: AudioObjectID) -> LatencyReport {
        let scope = kAudioDevicePropertyScopeOutput
        var report = LatencyReport(
            bufferFrames: (try? device.read(kAudioDevicePropertyBufferFrameSize, scope: scope, as: UInt32.self)) ?? 0,
            deviceLatency: (try? device.read(kAudioDevicePropertyLatency, scope: scope, as: UInt32.self)) ?? 0,
            safetyOffset: (try? device.read(kAudioDevicePropertySafetyOffset, scope: scope, as: UInt32.self)) ?? 0,
            streamLatency: 0
        )
        if let streams: [AudioObjectID] = try? device.readArray(kAudioDevicePropertyStreams, scope: scope),
           let first = streams.first {
            report.streamLatency = (try? first.read(kAudioStreamPropertyLatency, as: UInt32.self)) ?? 0
        }
        return report
    }

    static func transportType(of device: AudioObjectID) -> UInt32 {
        (try? device.read(kAudioDevicePropertyTransportType, as: UInt32.self)) ?? 0
    }

    /// Nesting one aggregate device inside another is not supported by the HAL, so the mixer
    /// cannot run when the user's output is already an aggregate or a virtual driver.
    static func isNestable(_ device: AudioObjectID) -> Bool {
        let type = transportType(of: device)
        return type != kAudioDeviceTransportTypeAggregate && type != kAudioDeviceTransportTypeVirtual
    }
}
