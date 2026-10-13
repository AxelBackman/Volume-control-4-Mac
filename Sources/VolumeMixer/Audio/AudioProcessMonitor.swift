import AppKit
import CoreAudio
import Darwin
import Foundation
import VolumeMixerCore

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let executablePath: String?
    /// The process has an output stream open, whether or not sound is coming out of it.
    var hasOutputStream: Bool
    var isRunningOutput: Bool
}

/// One row in the mixer: an app plus every audio process that belongs to it.
struct AudioAppGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let bundlePath: String?
    /// Empty once the app has released its audio stream; the row stays until the app quits.
    var processObjectIDs: [AudioObjectID]
    /// Every pid this app has had an audio process on, with the executable path it had at the
    /// time. macOS recycles pids, so the path is what proves it is still the same process.
    var pids: [pid_t: String]
    var hasStream: Bool
    var isPlaying: Bool
}

/// Watches coreaudiod's process list and reports the apps the mixer should show.
///
/// An app enters the list the first time it opens an output stream and stays there until its
/// process exits, the way the Windows volume mixer behaves. System agents qualify too, so the
/// alert sounds get a row of their own and obey the master slider; they never quit, so those
/// rows stay for the session. coreaudiod drops a process object
/// as soon as the app releases the stream (Spotify does this on pause), so liveness is tracked
/// from the pids instead.
///
/// Reading any of this needs no privileges - the audio capture permission is only required
/// once we create a tap.
final class AudioProcessMonitor {
    private let queue: DispatchQueue
    private var listListener: PropertyListener?
    private var runningListeners: [AudioObjectID: PropertyListener] = [:]
    private var pollTimer: DispatchSourceTimer?

    private var known: [String: AudioAppGroup] = [:]
    private var lastGroups: [AudioAppGroup] = []
    private var metadata: [AudioObjectID: ProcessMetadata] = [:]

    /// Property listeners on `kAudioProcessPropertyIsRunningOutput` do not fire reliably, so
    /// the state is polled as well. One list read plus two property reads per process is cheap
    /// enough at this rate.
    private let pollInterval: TimeInterval = 1

    /// Called on `queue` whenever the visible set of apps changes.
    var onChange: (([AudioAppGroup]) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        pollTimer = timer

        listListener = PropertyListener(objectID: .system,
                                        selector: kAudioHardwarePropertyProcessObjectList,
                                        queue: queue) { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        listListener = nil
        runningListeners.removeAll()
        pollTimer?.cancel()
        pollTimer = nil
    }

    func refresh() {
        dispatchPrecondition(condition: .onQueue(queue))

        let processObjects: [AudioObjectID]
        do {
            processObjects = try AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList)
        } catch {
            log.error("could not read process list: \(error.localizedDescription)")
            return
        }

        for objectID in processObjects where runningListeners[objectID] == nil {
            runningListeners[objectID] = PropertyListener(objectID: objectID,
                                                          selector: kAudioProcessPropertyIsRunningOutput,
                                                          queue: queue) { [weak self] in
                self?.refresh()
            }
        }
        let live = Set(processObjects)
        runningListeners = runningListeners.filter { live.contains($0.key) }
        metadata = metadata.filter { live.contains($0.key) }

        let processes = processObjects.compactMap(describe)
        if Self.diagnosticsEnabled { Self.dump(processes) }

        merge(Self.group(processes))

        let visible = known.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        guard visible != lastGroups else { return }
        lastGroups = visible
        onChange?(visible)
    }

    // MARK: - Remembering apps

    private func merge(_ current: [AudioAppGroup]) {
        var seen: Set<String> = []

        for group in current {
            seen.insert(group.id)
            if var entry = known[group.id] {
                entry.processObjectIDs = group.processObjectIDs
                entry.pids.merge(group.pids) { _, new in new }
                entry.hasStream = group.hasStream
                entry.isPlaying = group.isPlaying
                known[group.id] = entry
            } else if group.hasStream {
                // An app earns its row by opening an output stream at least once.
                known[group.id] = group
            }
        }

        for (id, var entry) in known where !seen.contains(id) {
            entry.processObjectIDs = []
            entry.hasStream = false
            entry.isPlaying = false
            known[id] = entry
        }

        // Dropping the dead pids as they are checked keeps the set the size of what is
        // actually running; merging without pruning would grow it for the whole session, and
        // every entry costs a syscall on every refresh.
        known = known.compactMapValues { group in
            var group = group
            group.pids = group.pids.filter { Self.isProcessAlive(pid: $0.key, path: $0.value) }
            return group.pids.isEmpty ? nil : group
        }
    }

    private static func isProcessAlive(pid: pid_t, path: String) -> Bool {
        guard !path.isEmpty else {
            // EPERM means the process exists but belongs to someone else.
            return kill(pid, 0) == 0 || errno == EPERM
        }
        // A recycled pid belongs to a different binary, so the path has to match too.
        return executablePath(for: pid) == path
    }

    // MARK: - Reading a single process object

    private static let ownPID = getpid()

    private struct ProcessMetadata {
        let pid: pid_t
        let bundleID: String?
        let executablePath: String?
    }

    private func describe(_ objectID: AudioObjectID) -> AudioProcess? {
        let info: ProcessMetadata
        if let cached = metadata[objectID] {
            info = cached
        } else {
            guard let pid: pid_t = try? objectID.read(kAudioProcessPropertyPID) else { return nil }
            // Daemons report an empty bundle ID rather than none, and an empty string is a
            // perfectly good dictionary key - every unbundled process would collapse into one
            // group named after whichever got there first.
            let rawBundleID = try? objectID.readString(kAudioProcessPropertyBundleID)
            info = ProcessMetadata(pid: pid,
                                   bundleID: (rawBundleID?.isEmpty ?? true) ? nil : rawBundleID,
                                   executablePath: Self.executablePath(for: pid))
            metadata[objectID] = info
        }
        // Tapping ourselves would mute our own alerts and risks a feedback path.
        guard info.pid != Self.ownPID else { return nil }

        let isRunningOutput = ((try? objectID.read(kAudioProcessPropertyIsRunningOutput,
                                                   as: UInt32.self)) ?? 0) != 0
        let outputDevices: [AudioObjectID] = (try? objectID.readArray(kAudioProcessPropertyDevices,
                                                                      scope: kAudioObjectPropertyScopeOutput)) ?? []
        return AudioProcess(objectID: objectID,
                            pid: info.pid,
                            bundleID: info.bundleID,
                            executablePath: info.executablePath,
                            hasOutputStream: !outputDevices.isEmpty,
                            isRunningOutput: isRunningOutput)
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Grouping

    private static func group(_ processes: [AudioProcess]) -> [AudioAppGroup] {
        var byKey: [String: AudioAppGroup] = [:]

        for process in processes {
            let bundlePath = process.executablePath.flatMap(AppGrouping.owningBundlePath(forExecutablePath:))
            // Unbundled binaries group by executable path so repeat invocations share a row.
            let key = bundlePath ?? process.executablePath ?? process.bundleID ?? "pid:\(process.pid)"

            if byKey[key] != nil {
                byKey[key]?.processObjectIDs.append(process.objectID)
                byKey[key]?.pids[process.pid] = process.executablePath ?? ""
                if process.isRunningOutput { byKey[key]?.isPlaying = true }
                if process.hasOutputStream { byKey[key]?.hasStream = true }
            } else {
                byKey[key] = AudioAppGroup(id: key,
                                           name: displayName(bundlePath: bundlePath, process: process),
                                           bundlePath: bundlePath,
                                           processObjectIDs: [process.objectID],
                                           pids: [process.pid: process.executablePath ?? ""],
                                           hasStream: process.hasOutputStream,
                                           isPlaying: process.isRunningOutput)
            }
        }

        return Array(byKey.values)
    }

    private static func displayName(bundlePath: String?, process: AudioProcess) -> String {
        if let bundlePath {
            if let info = Bundle(path: bundlePath)?.infoDictionary,
               let name = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
               !name.isEmpty {
                return name
            }
            return AppGrouping.displayName(forBundlePath: bundlePath)
        }
        if let executablePath = process.executablePath {
            let name = (executablePath as NSString).lastPathComponent
            // The server behind alert sounds and UI feedback - "System Sounds" is what the
            // Windows mixer calls the same thing.
            return name == "systemsoundserverd" ? "System Sounds" : name
        }
        return process.bundleID ?? "PID \(process.pid)"
    }

    // MARK: - Diagnostics

    private static let diagnosticsEnabled = ProcessInfo.processInfo.environment["VOLUMEMIXER_DEBUG"] == "1"
    private static var lastDumpSignature = ""

    private static func dump(_ processes: [AudioProcess]) {
        let signature = processes.map { "\($0.pid):\($0.hasOutputStream):\($0.isRunningOutput)" }.joined()
        guard signature != lastDumpSignature else { return }
        lastDumpSignature = signature

        log.notice("--- \(processes.count, privacy: .public) audio process(es) ---")
        for process in processes where process.hasOutputStream || process.isRunningOutput {
            let path = process.executablePath ?? "?"
            log.notice("  pid=\(process.pid, privacy: .public) out=\(process.hasOutputStream, privacy: .public) playing=\(process.isRunningOutput, privacy: .public) path=\(path, privacy: .public)")
        }
    }
}
