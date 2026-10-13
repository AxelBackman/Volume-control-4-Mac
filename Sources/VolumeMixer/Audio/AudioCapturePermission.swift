import AppKit
import Foundation

/// Checks and requests the "System Audio Recording Only" TCC permission.
///
/// macOS has no public API for this permission, only an implicit prompt the first time a tap
/// is started. Asking TCC directly lets us tell "denied" apart from "silent app", which
/// matters because `mutedWhenTapped` keeps muting an app whether or not we get its samples.
/// Everything here degrades gracefully: if the private symbols ever disappear the status is
/// `.unknown` and the mixer falls back to letting the system prompt on its own.
enum AudioCapturePermission {

    enum Status {
        case granted
        case denied
        case unknown
    }

    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LAZY)
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    static var isAvailable: Bool {
        symbol("TCCAccessPreflight", as: PreflightFunc.self) != nil
    }

    static func preflight() -> Status {
        guard let preflight = symbol("TCCAccessPreflight", as: PreflightFunc.self) else {
            return .unknown
        }
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(completion: @escaping (Status) -> Void) {
        guard let request = symbol("TCCAccessRequest", as: RequestFunc.self) else {
            completion(.unknown)
            return
        }
        request(service, nil) { granted in
            completion(granted ? .granted : .denied)
        }
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
