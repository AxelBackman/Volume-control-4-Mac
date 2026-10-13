import Atomics
import AudioToolbox
import CoreAudio
import Foundation
import VolumeMixerCore

/// State the IO proc mutates. Kept in manually managed memory so the real-time thread never
/// touches a Swift object (no ARC, no exclusivity checks, no allocation).
private struct RenderState {
    var currentGain: Float
    var maxDelta: Float
}

/// Resolves a flat channel index to its sample pointer, interleaving stride and the number of
/// frames its buffer actually holds, so the IO proc works with both interleaved and
/// non-interleaved buffer layouts and never runs off the end of a short buffer.
@inline(__always)
private func channelPointer(_ list: UnsafeMutableAudioBufferListPointer,
                            _ channel: Int) -> (UnsafeMutablePointer<Float>, Int, Int)? {
    var remaining = channel
    for index in 0..<list.count {
        let buffer = list[index]
        let channels = Int(buffer.mNumberChannels)
        if remaining < channels {
            guard let data = buffer.mData else { return nil }
            let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            return (data.assumingMemoryBound(to: Float.self) + remaining, channels, frames)
        }
        remaining -= channels
    }
    return nil
}

@inline(__always)
private func totalChannels(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
    var total = 0
    for index in 0..<list.count { total += Int(list[index].mNumberChannels) }
    return total
}

@inline(__always)
private func frameCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
    guard list.count > 0 else { return 0 }
    let buffer = list[0]
    let channels = Int(buffer.mNumberChannels)
    guard channels > 0 else { return 0 }
    return Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
}

/// Owns everything needed to control one app's volume: the tap, the aggregate device that
/// renders it, and the real-time state shared with the IO proc.
final class AppTapController {
    let groupID: String
    let groupName: String
    /// The process objects the tap was built from. A tap's process list is fixed at creation,
    /// so the controller has to be rebuilt when the app opens audio from a new process.
    let processObjectIDs: Set<AudioObjectID>

    private let tap: ProcessTap
    private let aggregate: AggregateOutput
    private let state: UnsafeMutablePointer<RenderState>
    private let targetGain = UnsafeAtomic<UInt32>.create(Float(1).bitPattern)
    private let peakLevel = UnsafeAtomic<UInt32>.create(0)
    private let sawAudio = UnsafeAtomic<Bool>.create(false)

    // RT-safe diagnostics: the IO proc only stores numbers, the engine reads and logs them.
    private let ioCycles = UnsafeAtomic<UInt64>.create(0)
    private let lastFrames = UnsafeAtomic<UInt32>.create(0)
    private let lastInputLayout = UnsafeAtomic<UInt32>.create(0)   // buffers << 16 | channels
    private let lastOutputLayout = UnsafeAtomic<UInt32>.create(0)
    private let lastBail = UnsafeAtomic<UInt32>.create(0)
    private let lastInputPeak = UnsafeAtomic<UInt32>.create(0)

    private var invalidated = false

    init(group: AudioAppGroup,
         outputDeviceUID: String,
         sampleRate: Double,
         initialGain: Float) throws {
        self.groupID = group.id
        self.groupName = group.name
        self.processObjectIDs = Set(group.processObjectIDs)

        state = .allocate(capacity: 1)
        state.initialize(to: RenderState(
            currentGain: initialGain,
            maxDelta: GainRamp.maxDelta(rampSeconds: 0.02, sampleRate: sampleRate)
        ))
        targetGain.store(initialGain.bitPattern, ordering: .relaxed)

        do {
            tap = try ProcessTap(processObjectIDs: group.processObjectIDs, name: group.name)
        } catch {
            state.deallocate()
            targetGain.destroy(); peakLevel.destroy(); sawAudio.destroy()
            ioCycles.destroy(); lastFrames.destroy(); lastInputLayout.destroy()
            lastOutputLayout.destroy(); lastBail.destroy(); lastInputPeak.destroy()
            throw error
        }

        do {
            aggregate = try AggregateOutput(tapUUID: tap.uuid,
                                            outputDeviceUID: outputDeviceUID,
                                            name: group.name)
        } catch {
            tap.invalidate()
            state.deallocate()
            targetGain.destroy(); peakLevel.destroy(); sawAudio.destroy()
            ioCycles.destroy(); lastFrames.destroy(); lastInputLayout.destroy()
            lastOutputLayout.destroy(); lastBail.destroy(); lastInputPeak.destroy()
            throw error
        }

        do {
            try aggregate.start(makeIOBlock())
        } catch {
            aggregate.invalidate()
            tap.invalidate()
            state.deallocate()
            destroyAtomics()
            throw error
        }
    }

    // MARK: - Control (any thread)

    func setGain(_ gain: Float) {
        targetGain.store(max(0, min(1, gain)).bitPattern, ordering: .relaxed)
    }

    /// Peak since the last call, for the level meter.
    func consumePeak() -> Float {
        Float(bitPattern: peakLevel.exchange(0, ordering: .relaxed))
    }

    /// False means the tap has never delivered a non-silent sample - the signal that the
    /// system audio permission was denied and the app is being muted for nothing.
    var hasProducedAudio: Bool {
        sawAudio.load(ordering: .relaxed)
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true

        // Order matters: stopping IO first guarantees the IO proc is no longer reading the
        // memory we are about to free.
        aggregate.invalidate()
        tap.invalidate()
        state.deallocate()
        destroyAtomics()
    }

    private func destroyAtomics() {
        targetGain.destroy()
        peakLevel.destroy()
        sawAudio.destroy()
        ioCycles.destroy()
        lastFrames.destroy()
        lastInputLayout.destroy()
        lastOutputLayout.destroy()
        lastBail.destroy()
        lastInputPeak.destroy()
    }

    struct Diagnostics {
        var cycles: UInt64
        var frames: UInt32
        var inputBuffers: UInt32
        var inputChannels: UInt32
        var outputBuffers: UInt32
        var outputChannels: UInt32
        var bail: UInt32
        var inputPeak: Float
    }

    var diagnostics: Diagnostics {
        let input = lastInputLayout.load(ordering: .relaxed)
        let output = lastOutputLayout.load(ordering: .relaxed)
        return Diagnostics(cycles: ioCycles.load(ordering: .relaxed),
                           frames: lastFrames.load(ordering: .relaxed),
                           inputBuffers: input >> 16,
                           inputChannels: input & 0xffff,
                           outputBuffers: output >> 16,
                           outputChannels: output & 0xffff,
                           bail: lastBail.load(ordering: .relaxed),
                           inputPeak: Float(bitPattern: lastInputPeak.load(ordering: .relaxed)))
    }

    // MARK: - Real-time rendering

    private func makeIOBlock() -> AudioDeviceIOBlock {
        // Capture plain pointers and numbers only - the block must not touch `self`.
        let tapChannels = max(1, min(2, Int(tap.format.mChannelsPerFrame)))
        let state = self.state
        let targetGain = self.targetGain
        let peakLevel = self.peakLevel
        let sawAudio = self.sawAudio
        let ioCycles = self.ioCycles
        let lastFrames = self.lastFrames
        let lastInputLayout = self.lastInputLayout
        let lastOutputLayout = self.lastOutputLayout
        let lastBail = self.lastBail
        let lastInputPeak = self.lastInputPeak

        return { _, inInputData, _, outOutputData, _ in
            ioCycles.wrappingIncrement(ordering: .relaxed)
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let output = UnsafeMutableAudioBufferListPointer(outOutputData)

            // The HAL does not hand us zeroed output buffers.
            for index in 0..<output.count {
                if let data = output[index].mData {
                    memset(data, 0, Int(output[index].mDataByteSize))
                }
            }

            var frames = frameCount(output)
            let inputChannels = totalChannels(input)
            let outputChannels = totalChannels(output)

            // An aggregate device lists its sub-device's input streams before the taps, so on a
            // headset the first input channels are the microphone. The tap's channels are the
            // last ones.
            let inputOffset = max(0, inputChannels - tapChannels)
            let channels = min(tapChannels, min(inputChannels - inputOffset, outputChannels))

            lastFrames.store(UInt32(frames), ordering: .relaxed)
            lastInputLayout.store(UInt32(input.count) << 16 | UInt32(inputChannels), ordering: .relaxed)
            lastOutputLayout.store(UInt32(output.count) << 16 | UInt32(outputChannels), ordering: .relaxed)

            guard frames > 0 else { lastBail.store(1, ordering: .relaxed); return }
            guard channels > 0 else { lastBail.store(2, ordering: .relaxed); return }

            guard let (source0, sourceStride0, sourceFrames0) = channelPointer(input, inputOffset),
                  let (dest0, destStride0, destFrames0) = channelPointer(output, 0) else {
                lastBail.store(3, ordering: .relaxed)
                return
            }

            // The input side comes from the tap, not from the output device, so its buffers are
            // not guaranteed to carry as many frames as the output asks for.
            frames = min(frames, min(sourceFrames0, destFrames0))

            var source1: UnsafeMutablePointer<Float>?
            var sourceStride1 = 1
            var dest1: UnsafeMutablePointer<Float>?
            var destStride1 = 1
            if channels > 1 {
                if let pair = channelPointer(input, inputOffset + 1) {
                    source1 = pair.0; sourceStride1 = pair.1; frames = min(frames, pair.2)
                }
                if let pair = channelPointer(output, 1) {
                    dest1 = pair.0; destStride1 = pair.1; frames = min(frames, pair.2)
                }
            }

            guard frames > 0 else { lastBail.store(4, ordering: .relaxed); return }
            lastBail.store(0, ordering: .relaxed)

            let target = Float(bitPattern: targetGain.load(ordering: .relaxed))
            let maxDelta = state.pointee.maxDelta
            var gain = state.pointee.currentGain
            var outputPeak: Float = 0
            var inputPeak: Float = 0

            if let source1, let dest1 {
                for frame in 0..<frames {
                    gain = GainRamp.advance(gain, toward: target, maxDelta: maxDelta)
                    let rawLeft = source0[frame * sourceStride0]
                    let rawRight = source1[frame * sourceStride1]
                    let left = rawLeft * gain
                    let right = rawRight * gain
                    dest0[frame * destStride0] = left
                    dest1[frame * destStride1] = right
                    let raw = max(abs(rawLeft), abs(rawRight))
                    if raw > inputPeak { inputPeak = raw }
                    let scaled = max(abs(left), abs(right))
                    if scaled > outputPeak { outputPeak = scaled }
                }
            } else {
                for frame in 0..<frames {
                    gain = GainRamp.advance(gain, toward: target, maxDelta: maxDelta)
                    let raw = source0[frame * sourceStride0]
                    let sample = raw * gain
                    dest0[frame * destStride0] = sample
                    if abs(raw) > inputPeak { inputPeak = abs(raw) }
                    if abs(sample) > outputPeak { outputPeak = abs(sample) }
                }
            }

            state.pointee.currentGain = gain

            // The meter shows what is actually heard; the permission failsafe needs the
            // pre-gain signal, otherwise an app muted by the user looks like a dead tap.
            let previous = Float(bitPattern: peakLevel.load(ordering: .relaxed))
            if outputPeak > previous { peakLevel.store(outputPeak.bitPattern, ordering: .relaxed) }
            if inputPeak > Float(bitPattern: lastInputPeak.load(ordering: .relaxed)) {
                lastInputPeak.store(inputPeak.bitPattern, ordering: .relaxed)
            }
            if inputPeak > 0 && !sawAudio.load(ordering: .relaxed) {
                sawAudio.store(true, ordering: .relaxed)
            }
        }
    }
}
