import Foundation

/// Maps an arbitrary process executable path to the application bundle that owns it.
///
/// Browsers and Electron apps play audio from helper processes that live deep inside the
/// main bundle (`Google Chrome.app/Contents/Frameworks/.../Google Chrome Helper.app/...`).
/// Grouping on the *outermost* `.app` in the path puts those helpers under the app the
/// user recognises.
public enum AppGrouping {

    /// The outermost `.app` bundle containing `executablePath`, or nil for unbundled binaries.
    public static func owningBundlePath(forExecutablePath executablePath: String) -> String? {
        let components = executablePath.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return components[...index].joined(separator: "/")
    }

    /// Fallback display name derived from a bundle path: `/Applications/Spotify.app` -> `Spotify`.
    public static func displayName(forBundlePath bundlePath: String) -> String {
        let last = bundlePath.split(separator: "/").last.map(String.init) ?? bundlePath
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }
}
