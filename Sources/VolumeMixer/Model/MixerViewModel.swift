import AppKit
import Observation
import SwiftUI

struct MixerRow: Identifiable, Equatable {
    let id: String
    let name: String
    let bundlePath: String?
    let isTapped: Bool
    let isPlaying: Bool
    let hasStream: Bool
    let level: Float
    var volume: Float
    var isMuted: Bool
}

@MainActor
@Observable
final class MixerViewModel {
    private(set) var rows: [MixerRow] = []
    private(set) var status = EngineStatus()

    /// Mirrors the service state in stored form: a computed property reading `LoginItem`
    /// directly is invisible to observation, so the checkbox would not track the real state -
    /// least of all when registering throws and the state never changed.
    private(set) var isLaunchAtLoginEnabled = LoginItem.isEnabled

    var launchAtLogin: Bool {
        get { isLaunchAtLoginEnabled }
        set {
            do { try LoginItem.setEnabled(newValue) }
            catch { log.error("login item: \(error.localizedDescription)") }
            isLaunchAtLoginEnabled = LoginItem.isEnabled
        }
    }

    private let engine = MixerEngine()
    private var volumes: [String: Float] = [:]
    private var mutes: Set<String> = []
    private var levels: [String: Float] = [:]
    /// Filled lazily from `body` while a row is being rendered, so it must not take part in
    /// observation: a tracked write during a view update invalidates the view that is drawing.
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

    init() {
        engine.onUpdate = { [weak self] snapshots in
            MainActor.assumeIsolated { self?.apply(snapshots) }
        }
        engine.onStatus = { [weak self] status in
            MainActor.assumeIsolated { self?.apply(status) }
        }
    }

    func start() { engine.start() }
    func stop() { engine.stop() }

    func icon(for row: MixerRow) -> NSImage? {
        guard let path = row.bundlePath else { return nil }
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 24, height: 24)
        iconCache[path] = icon
        return icon
    }

    /// The engine republishes its own state every 50 ms, so a status already in flight when
    /// the user grabs the master slider carries the previous value and the knob snaps back.
    /// Our value wins until the engine echoes it, then the device is the source of truth again
    /// - which is what lets the volume keys move the slider.
    private var pendingMasterVolume: (value: Float, deadline: Date)?
    private var pendingMasterMute: (value: Bool, deadline: Date)?
    private let echoTimeout: TimeInterval = 0.5

    var masterVolume: Float { pendingMasterVolume?.value ?? status.masterVolume }
    var masterMuted: Bool { pendingMasterMute?.value ?? status.masterMuted }

    func setMasterVolume(_ volume: Float) {
        pendingMasterVolume = (volume, Date().addingTimeInterval(echoTimeout))
        engine.setMasterVolume(volume)
    }

    func toggleMasterMute() {
        let muted = !masterMuted
        pendingMasterMute = (muted, Date().addingTimeInterval(echoTimeout))
        engine.setMasterMuted(muted)
    }

    private func apply(_ newStatus: EngineStatus) {
        let now = Date()
        if let pending = pendingMasterVolume,
           abs(newStatus.masterVolume - pending.value) < 0.0005 || now > pending.deadline {
            pendingMasterVolume = nil
        }
        if let pending = pendingMasterMute,
           newStatus.masterMuted == pending.value || now > pending.deadline {
            pendingMasterMute = nil
        }
        status = newStatus
    }

    func setVolume(_ volume: Float, for id: String) {
        volumes[id] = volume
        engine.setVolume(volume, for: id)
        refreshRows()
    }

    func toggleMute(for id: String) {
        let isMuted = !mutes.contains(id)
        if isMuted { mutes.insert(id) } else { mutes.remove(id) }
        engine.setMuted(isMuted, for: id)
        refreshRows()
    }

    func openPermissionSettings() { AudioCapturePermission.openSystemSettings() }

    // MARK: - Private

    private var lastSnapshots: [MixerAppSnapshot] = []

    private func apply(_ snapshots: [MixerAppSnapshot]) {
        lastSnapshots = snapshots

        // Fast attack, slow release: a peak meter that drops instantly is unreadable.
        var updated: [String: Float] = [:]
        for snapshot in snapshots {
            let previous = levels[snapshot.id] ?? 0
            updated[snapshot.id] = max(snapshot.level, previous * 0.8)
        }
        levels = updated

        refreshRows()
    }

    private static let diagnosticsEnabled = ProcessInfo.processInfo.environment["VOLUMEMIXER_DEBUG"] == "1"
    private var loggedRowCount = -1

    private func refreshRows() {
        if Self.diagnosticsEnabled && lastSnapshots.count != loggedRowCount {
            loggedRowCount = lastSnapshots.count
            log.notice("view model has \(self.lastSnapshots.count, privacy: .public) row(s)")
        }
        rows = lastSnapshots.map { snapshot in
            MixerRow(id: snapshot.id,
                     name: snapshot.name,
                     bundlePath: snapshot.bundlePath,
                     isTapped: snapshot.isTapped,
                     isPlaying: snapshot.isPlaying,
                     hasStream: snapshot.hasStream,
                     level: levels[snapshot.id] ?? 0,
                     volume: volumes[snapshot.id] ?? 1,
                     isMuted: mutes.contains(snapshot.id))
        }
    }
}
