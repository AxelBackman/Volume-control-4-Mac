import AppKit
import CoreAudio
import Foundation

struct MixerAppSnapshot: Identifiable, Equatable {
    let id: String
    let name: String
    let bundlePath: String?
    var volume: Float
    var isMuted: Bool
    var level: Float
    var isTapped: Bool
    var isPlaying: Bool
    var hasStream: Bool
}

struct EngineStatus: Equatable {
    var permission: PermissionState = .unknown
    var outputDeviceName: String = ""
    var message: String?
    var masterVolume: Float = 1
    var masterMuted: Bool = false
    /// True when the slider drives the output device itself, so it matches the volume keys and
    /// Control Center. False means the device has no software volume and the mixer applies the
    /// master gain to each tapped app instead.
    var masterIsSystemVolume: Bool = false

    enum PermissionState: Equatable {
        case granted
        case denied
        case unknown
    }
}

/// Owns the audio side of the mixer. Everything here runs on one serial queue; results are
/// handed to the UI on the main queue.
final class MixerEngine {
    private let queue = DispatchQueue(label: "se.qte.volumemixer.audio")
    private let monitor: AudioProcessMonitor

    private var controllers: [String: AppTapController] = [:]
    private var groups: [AudioAppGroup] = []
    private var volumes: [String: Float] = [:]
    private var muted: Set<String> = []
    private var levels: [String: Float] = [:]

    private var outputDeviceID: AudioObjectID = .unknown
    private var outputDeviceUID: String = ""
    private var outputSampleRate: Double = 48_000

    private var masterVolume: Float = 1
    private var masterMuted = false
    /// Whether the mute button drives the device's own mute control. A device can expose a
    /// settable volume without a mute (plenty do), and then muting has to happen in the mixer
    /// even though the slider does not.
    private var masterMuteIsSystem = false
    private var deviceVolumeListener: PropertyListener?
    private var deviceMuteListener: PropertyListener?
    private var defaultDeviceListener: PropertyListener?
    private var sampleRateListener: PropertyListener?
    private var levelTimer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?
    private var ticks = 0
    private var stalled: [String: (cycles: UInt64, strikes: Int)] = [:]

    private var status = EngineStatus()
    private var permissionMessage: String?
    private var deviceMessage: String?
    private var tapsAllowed = false
    private var failsafeArmed = false
    private var failsafeDeadline: Date?

    /// Called on the main queue.
    var onUpdate: (([MixerAppSnapshot]) -> Void)?
    var onStatus: ((EngineStatus) -> Void)?

    init() {
        monitor = AudioProcessMonitor(queue: queue)
    }

    // MARK: - Lifecycle

    func start() {
        queue.async {
            AggregateOutput.removeOrphans()

            self.monitor.onChange = { [weak self] groups in
                self?.groupsChanged(groups)
            }
            self.observeOutputDevice()
            self.observeWake()
            self.resolveOutputDevice()
            self.startLevelTimer()
            self.monitor.start()
            self.evaluatePermission()
        }
    }

    /// Tears everything down synchronously - app teardown must not race the IO threads.
    func stop() {
        queue.sync {
            self.levelTimer?.cancel()
            self.levelTimer = nil
            self.monitor.stop()
            self.defaultDeviceListener = nil
            self.sampleRateListener = nil
            self.deviceVolumeListener = nil
            self.deviceMuteListener = nil
            if let wakeObserver = self.wakeObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
                self.wakeObserver = nil
            }
            for controller in self.controllers.values { controller.invalidate() }
            self.controllers.removeAll()
        }
    }

    // MARK: - Controls

    func setVolume(_ volume: Float, for id: String) {
        queue.async {
            self.volumes[id] = volume
            self.applyGain(for: id)
            self.publish()
        }
    }

    func setMasterVolume(_ volume: Float) {
        queue.async {
            self.masterVolume = max(0, min(1, volume))
            if self.status.masterIsSystemVolume {
                SystemOutput.setVolume(self.masterVolume, on: self.outputDeviceID)
            } else {
                for id in self.controllers.keys { self.applyGain(for: id) }
            }
            self.status.masterVolume = self.masterVolume
            self.publish()
        }
    }

    func setMasterMuted(_ muted: Bool) {
        queue.async {
            self.masterMuted = muted
            if self.masterMuteIsSystem {
                SystemOutput.setMuted(muted, on: self.outputDeviceID)
            } else {
                for id in self.controllers.keys { self.applyGain(for: id) }
            }
            self.status.masterMuted = muted
            self.publish()
        }
    }

    /// The volume keys and Control Center change the device behind our back; mirror it.
    private func readDeviceVolume() {
        guard status.masterIsSystemVolume else { return }
        if let volume = SystemOutput.volume(of: outputDeviceID) {
            masterVolume = volume
            status.masterVolume = volume
        }
        guard masterMuteIsSystem else { return }
        let muted = SystemOutput.isMuted(outputDeviceID)
        masterMuted = muted
        status.masterMuted = muted
    }

    func setMuted(_ isMuted: Bool, for id: String) {
        queue.async {
            if isMuted { self.muted.insert(id) } else { self.muted.remove(id) }
            self.applyGain(for: id)
            self.publish()
        }
    }

    // MARK: - Permission

    private func evaluatePermission() {
        let status = AudioCapturePermission.preflight()
        switch status {
        case .granted:
            applyPermission(.granted)
        case .denied:
            applyPermission(.denied)
        case .unknown where AudioCapturePermission.isAvailable:
            // Never asked before - let the user decide before we mute anything.
            AudioCapturePermission.request { [weak self] result in
                self?.queue.async { self?.applyPermission(result) }
            }
        case .unknown:
            // No way to ask; create taps and let the silence failsafe catch a denial.
            applyPermission(.unknown)
        }
    }

    private func applyPermission(_ permission: AudioCapturePermission.Status) {
        switch permission {
        case .granted:
            status.permission = .granted
            permissionMessage = nil
            tapsAllowed = true
            failsafeArmed = false
            failsafeDeadline = nil
        case .denied:
            status.permission = .denied
            permissionMessage = "VolumeMixer needs the System Audio Recording permission."
            tapsAllowed = false
            failsafeArmed = false
            failsafeDeadline = nil
            for controller in controllers.values { controller.invalidate() }
            controllers.removeAll()
        case .unknown:
            status.permission = .unknown
            tapsAllowed = true
            failsafeArmed = true
            failsafeDeadline = nil
        }
        syncControllers()
        publish()
    }

    /// Without TCC we can only detect a denial by noticing that no tap ever delivered audio
    /// while apps were playing. Hitting that means every tapped app is being muted for
    /// nothing, so everything is torn down.
    ///
    /// The clock only runs while a tapped app is actually playing: taps created before
    /// anything plays prove nothing, and judging them would both disarm the check forever and
    /// tear down working taps for an app that merely holds a silent stream open.
    private func checkFailsafe() {
        guard failsafeArmed else { return }

        let tappedAndPlaying = groups.contains { controllers[$0.id] != nil && $0.isPlaying }
        guard tappedAndPlaying else {
            failsafeDeadline = nil
            return
        }
        guard let deadline = failsafeDeadline else {
            failsafeDeadline = Date().addingTimeInterval(10)
            return
        }
        guard Date() >= deadline else { return }

        failsafeDeadline = nil
        guard controllers.values.allSatisfy({ !$0.hasProducedAudio }) else {
            failsafeArmed = false
            return
        }

        log.error("no tap produced audio within 10s - assuming the capture permission was denied")
        failsafeArmed = false
        tapsAllowed = false
        for controller in controllers.values { controller.invalidate() }
        controllers.removeAll()
        status.permission = .denied
        permissionMessage = "No audio reached VolumeMixer. Grant System Audio Recording and reopen."
        publish()
    }

    // MARK: - Output device

    /// Sleep can leave an aggregate device behind that no longer drives anything. Rebuilding
    /// on wake costs a short gap and is the only way back to working audio.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.queue.async {
                log.notice("woke from sleep - rebuilding taps")
                self?.rebuildEverything()
            }
        }
    }

    /// A tap whose IO proc has stopped running produces silence while still muting the app,
    /// which is the worst possible failure. Catch it and rebuild.
    private func checkStalledControllers() {
        let playing = Set(groups.filter(\.isPlaying).map(\.id))

        for (id, controller) in controllers {
            let cycles = controller.diagnostics.cycles
            guard playing.contains(id) else {
                stalled[id] = (cycles, 0)
                continue
            }
            let previous = stalled[id]
            if let previous, previous.cycles == cycles {
                let strikes = previous.strikes + 1
                stalled[id] = (cycles, strikes)
                if strikes >= 3 {
                    log.error("IO proc for \(controller.groupName, privacy: .public) stalled - rebuilding")
                    controller.invalidate()
                    controllers.removeValue(forKey: id)
                    stalled.removeValue(forKey: id)
                }
            } else {
                stalled[id] = (cycles, 0)
            }
        }
        stalled = stalled.filter { controllers[$0.key] != nil }
        syncControllers()
    }

    private func observeOutputDevice() {
        defaultDeviceListener = PropertyListener(objectID: .system,
                                                 selector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 queue: queue) { [weak self] in
            self?.outputDeviceChanged()
        }
    }

    private func resolveOutputDevice() {
        do {
            let device = try SystemOutput.defaultOutputDeviceID()
            outputDeviceID = device
            outputDeviceUID = try SystemOutput.uid(of: device)
            outputSampleRate = try SystemOutput.nominalSampleRate(of: device)
            status.outputDeviceName = SystemOutput.name(of: device)

            deviceMessage = SystemOutput.isNestable(device)
                ? nil
                : "Output device \"\(status.outputDeviceName)\" is a virtual device; per-app volume is unavailable."

            status.masterIsSystemVolume = SystemOutput.hasSoftwareVolume(device)
            masterMuteIsSystem = status.masterIsSystemVolume && SystemOutput.hasMute(device)

            if status.masterIsSystemVolume {
                readDeviceVolume()
                deviceVolumeListener = PropertyListener(objectID: device,
                                                        selector: kAudioDevicePropertyVolumeScalar,
                                                        scope: kAudioDevicePropertyScopeOutput,
                                                        queue: queue) { [weak self] in
                    self?.readDeviceVolume()
                    self?.publish()
                }
            } else {
                deviceVolumeListener = nil
                status.masterVolume = masterVolume
            }

            if masterMuteIsSystem {
                deviceMuteListener = PropertyListener(objectID: device,
                                                      selector: kAudioDevicePropertyMute,
                                                      scope: kAudioDevicePropertyScopeOutput,
                                                      queue: queue) { [weak self] in
                    self?.readDeviceVolume()
                    self?.publish()
                }
            } else {
                deviceMuteListener = nil
                status.masterMuted = masterMuted
            }

            sampleRateListener = PropertyListener(objectID: device,
                                                  selector: kAudioDevicePropertyNominalSampleRate,
                                                  queue: queue) { [weak self] in
                self?.outputDeviceChanged()
            }
        } catch {
            outputDeviceID = .unknown
            outputDeviceUID = ""
            deviceVolumeListener = nil
            deviceMuteListener = nil
            masterMuteIsSystem = false
            status.masterIsSystemVolume = false
            // The listener belongs to a device we can no longer read, and the header would
            // otherwise keep naming it.
            sampleRateListener = nil
            status.outputDeviceName = ""
            deviceMessage = "Could not read the output device: \(error.localizedDescription)"
            log.error("resolving output device failed: \(error.localizedDescription)")
        }
    }

    private func outputDeviceChanged() {
        log.notice("output device or sample rate changed - rebuilding taps")
        rebuildEverything()
    }

    private func rebuildEverything() {
        for controller in controllers.values { controller.invalidate() }
        controllers.removeAll()
        stalled.removeAll()
        resolveOutputDevice()
        syncControllers()
        publish()
    }

    // MARK: - Controllers

    private func groupsChanged(_ groups: [AudioAppGroup]) {
        self.groups = groups
        syncControllers()
        publish()
    }

    private func syncControllers() {
        let tappable = groups.filter { $0.hasStream && !$0.processObjectIDs.isEmpty }
        let wanted = Set(tappable.map(\.id))

        for (id, controller) in controllers where !wanted.contains(id) {
            controller.invalidate()
            controllers.removeValue(forKey: id)
        }

        // A tap captures a fixed set of process objects. When an app starts playing from a
        // process the tap does not cover - a second audio tab in Chrome, say - that audio
        // bypasses the mixer entirely, so the tap has to be rebuilt around the new list.
        for group in tappable {
            guard let controller = controllers[group.id],
                  !Set(group.processObjectIDs).isSubset(of: controller.processObjectIDs) else { continue }
            log.notice("rebuilding tap for \(group.name, privacy: .public) - new audio process(es)")
            controller.invalidate()
            controllers.removeValue(forKey: group.id)
        }

        guard tapsAllowed,
              outputDeviceID.isValid,
              !outputDeviceUID.isEmpty,
              SystemOutput.isNestable(outputDeviceID) else { return }

        for group in tappable {
            guard controllers[group.id] == nil else { continue }
            do {
                controllers[group.id] = try AppTapController(group: group,
                                                             outputDeviceID: outputDeviceID,
                                                             outputDeviceUID: outputDeviceUID,
                                                             sampleRate: outputSampleRate,
                                                             initialGain: gain(for: group.id))
                log.notice("tapping \(group.name, privacy: .public)")
            } catch {
                log.error("could not tap \(group.name): \(error.localizedDescription)")
            }
        }
    }

    private func gain(for id: String) -> Float {
        guard !masterMuted || masterMuteIsSystem else { return 0 }
        let app = muted.contains(id) ? 0 : (volumes[id] ?? 1)
        // When the device drives the master, it attenuates everything downstream already.
        return status.masterIsSystemVolume ? app : app * masterVolume
    }

    private func applyGain(for id: String) {
        controllers[id]?.setGain(gain(for: id))
    }

    // MARK: - Publishing

    private func startLevelTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.ticks += 1
            self.checkFailsafe()
            if self.ticks % 20 == 0 {
                self.checkStalledControllers()
                self.logDiagnostics()
            }
            self.publish(samplingLevels: true)
        }
        timer.resume()
        levelTimer = timer
    }

    /// Once a second, dump what the IO procs are actually seeing. Opt-in via
    /// `VOLUMEMIXER_DEBUG=1` so a normal run keeps the log quiet.
    private static let diagnosticsEnabled = ProcessInfo.processInfo.environment["VOLUMEMIXER_DEBUG"] == "1"

    private func logDiagnostics() {
        guard Self.diagnosticsEnabled else { return }
        log.notice("output=\(self.status.outputDeviceName, privacy: .public) uid=\(self.outputDeviceUID, privacy: .public) rate=\(self.outputSampleRate, privacy: .public) apps=\(self.groups.count, privacy: .public) tapped=\(self.controllers.count, privacy: .public) master=\(self.status.masterIsSystemVolume ? "system" : "mixer", privacy: .public)/\(self.status.masterVolume, privacy: .public)")
        for controller in controllers.values {
            let d = controller.diagnostics
            log.notice("  \(controller.groupName, privacy: .public): cycles=\(d.cycles, privacy: .public) frames=\(d.frames, privacy: .public) in=\(d.inputBuffers, privacy: .public)buf/\(d.inputChannels, privacy: .public)ch out=\(d.outputBuffers, privacy: .public)buf/\(d.outputChannels, privacy: .public)ch bail=\(d.bail, privacy: .public) inPeak=\(d.inputPeak, privacy: .public)")
        }
    }

    /// Reading a controller's peak resets it, so only the level timer may sample: a publish
    /// triggered by a slider drag would otherwise drain every meter between ticks.
    private func publish(samplingLevels: Bool = false) {
        if samplingLevels {
            var sampled: [String: Float] = [:]
            for (id, controller) in controllers { sampled[id] = controller.consumePeak() }
            levels = sampled
        }
        let snapshots = groups.map { group in
            MixerAppSnapshot(id: group.id,
                             name: group.name,
                             bundlePath: group.bundlePath,
                             volume: volumes[group.id] ?? 1,
                             isMuted: muted.contains(group.id),
                             level: levels[group.id] ?? 0,
                             isTapped: controllers[group.id] != nil,
                             isPlaying: group.isPlaying,
                             hasStream: group.hasStream)
        }
        var status = self.status
        status.message = permissionMessage ?? deviceMessage
        DispatchQueue.main.async {
            self.onUpdate?(snapshots)
            self.onStatus?(status)
        }
    }
}
