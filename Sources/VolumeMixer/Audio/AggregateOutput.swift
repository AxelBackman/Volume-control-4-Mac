import CoreAudio
import Foundation

/// A private aggregate device that pairs one tap with the real output device.
///
/// The tap only produces samples once it is a sub-tap of a running aggregate device; the
/// aggregate's main sub-device is the physical output, so whatever we write in the IO proc
/// goes straight to the speakers.
final class AggregateOutput {
    let deviceID: AudioObjectID
    let uid: String

    private var procID: AudioDeviceIOProcID?
    private var isRunning = false

    static let uidPrefix = "se.qte.volumemixer.agg."

    init(tapUUID: UUID, outputDeviceUID: String, name: String) throws {
        self.uid = Self.uidPrefix + UUID().uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeMixer \(name)",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            // The sub-device brings its own input streams into the aggregate - on a headset
            // that is the microphone, which is why macOS asks about microphone access.
            // kAudioSubDeviceInputChannelsKey looks like the way to drop them but the HAL
            // ignores it on creation (the header calls it a description of state, not a
            // directive), verified on macOS 26.6. What keeps the microphone safe instead: the
            // IO proc skips those channels entirely (see the tap offset in AppTapController)
            // and nothing in this app ever grants itself microphone access.
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var deviceID = AudioObjectID.unknown
        try AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
            .check("create aggregate device for \(name)")
        guard deviceID.isValid else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError,
                                 context: "create aggregate device for \(name)")
        }
        self.deviceID = deviceID
    }

    func start(_ ioBlock: @escaping AudioDeviceIOBlock) throws {
        var procID: AudioDeviceIOProcID?
        try AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil, ioBlock)
            .check("create IO proc")
        guard let procID else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError, context: "create IO proc")
        }
        self.procID = procID

        try AudioDeviceStart(deviceID, procID).check("start device")
        isRunning = true
    }

    func invalidate() {
        if let procID {
            if isRunning { AudioDeviceStop(deviceID, procID) }
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
            isRunning = false
        }
        let status = AudioHardwareDestroyAggregateDevice(deviceID)
        if status != noErr {
            log.error("destroying aggregate \(self.deviceID) failed: \(status.fourCharDescription)")
        }
    }

    /// Removes aggregate devices left behind by a previous crash.
    static func removeOrphans() {
        guard let devices = try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices,
                                                               of: AudioObjectID.self) else { return }
        for device in devices {
            guard let uid = try? device.readString(kAudioDevicePropertyDeviceUID),
                  uid.hasPrefix(uidPrefix) else { continue }
            log.notice("removing orphaned aggregate device \(uid)")
            AudioHardwareDestroyAggregateDevice(device)
        }
    }
}
