import Foundation

/// Real-time safe gain smoothing.
///
/// Jumping straight to a new gain produces a step discontinuity in the waveform, which is
/// audible as a click. Moving at most `maxDelta` per sample spreads the change over a few
/// milliseconds instead.
public enum GainRamp {

    /// Per-sample increment that covers the full 0...1 gain range in `rampSeconds`.
    public static func maxDelta(rampSeconds: Double, sampleRate: Double) -> Float {
        let samples = max(rampSeconds * sampleRate, 1)
        return Float(1.0 / samples)
    }

    @inlinable
    @inline(__always)
    public static func advance(_ current: Float, toward target: Float, maxDelta: Float) -> Float {
        if current < target { return min(current + maxDelta, target) }
        if current > target { return max(current - maxDelta, target) }
        return target
    }

    /// Number of samples `advance` needs to get from `current` to `target`.
    public static func samplesToReach(from current: Float, to target: Float, maxDelta: Float) -> Int {
        guard maxDelta > 0 else { return .max }
        return Int((abs(target - current) / maxDelta).rounded(.up))
    }
}
