import Foundation
import VolumeMixerCore

// XCTest and swift-testing both ship with Xcode, not with the Command Line Tools, so the
// pure-logic checks run as a plain executable instead: `make test`.

var failures = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual == expected {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label): expected \(expected), got \(actual)")
        failures += 1
    }
}

print("AppGrouping")

expect(AppGrouping.owningBundlePath(forExecutablePath: "/Applications/Spotify.app/Contents/MacOS/Spotify"),
       "/Applications/Spotify.app",
       "plain app maps to its own bundle")

expect(AppGrouping.owningBundlePath(forExecutablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/120/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"),
       "/Applications/Google Chrome.app",
       "nested helper maps to the outermost bundle")

expect(AppGrouping.owningBundlePath(forExecutablePath: "/usr/bin/afplay"),
       nil,
       "unbundled binary has no owning app")

expect(AppGrouping.displayName(forBundlePath: "/Applications/Google Chrome.app"),
       "Google Chrome",
       "display name strips the extension")

print("GainRamp")

let delta = GainRamp.maxDelta(rampSeconds: 0.02, sampleRate: 48_000)

var down: Float = 1
for _ in 0..<1000 { down = GainRamp.advance(down, toward: 0, maxDelta: delta) }
expect(down, 0, "ramp reaches zero without overshooting")

expect(GainRamp.samplesToReach(from: 0, to: 1, maxDelta: delta), 960, "20 ms sweep at 48 kHz is 960 samples")

var up: Float = 0
for _ in 0..<10 { up = GainRamp.advance(up, toward: 0.5, maxDelta: 0.3) }
expect(up, 0.5, "ramping up never exceeds the target")

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
