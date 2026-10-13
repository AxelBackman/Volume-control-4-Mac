import CoreAudio
import Foundation

/// A Core Audio process tap over every audio process belonging to one app.
///
/// `mutedWhenTapped` pulls the app's audio out of the normal output path: the samples arrive
/// through the tap instead, and it is on us to render them back out. If the tap dies the
/// original path is restored automatically.
final class ProcessTap {
    let tapID: AudioObjectID
    let uuid: UUID
    let format: AudioStreamBasicDescription

    init(processObjectIDs: [AudioObjectID], name: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = "VolumeMixer: \(name)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID.unknown
        try AudioHardwareCreateProcessTap(description, &tapID).check("create tap for \(name)")
        guard tapID.isValid else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError, context: "create tap for \(name)")
        }

        self.tapID = tapID
        self.uuid = description.uuid
        self.format = try tapID.read(kAudioTapPropertyFormat,
                                     as: AudioStreamBasicDescription.self,
                                     context: "read tap format")

        log.debug("tap \(tapID) for \(name): \(self.format.mChannelsPerFrame)ch @ \(self.format.mSampleRate)Hz")
    }

    func invalidate() {
        let status = AudioHardwareDestroyProcessTap(tapID)
        if status != noErr {
            log.error("destroying tap \(self.tapID) failed: \(status.fourCharDescription)")
        }
    }
}
