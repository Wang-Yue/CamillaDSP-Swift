// CamillaDSP-Swift: RACE processor - Recursive Ambiophonic Crosstalk Eliminator
// Matches Rust CamillaDSP: processors/race.rs

import Foundation

/// Single-sample ring-buffer delay, equivalent to Rust Delay::process_single.
/// The integer delay is the pre-compensated sample count; the fractional part
/// is handled by an optional Thiran allpass biquad (same as DelayFilter).
private final class SingleSampleDelay {
    // Ring buffer for integer delay (nil when delay is 0 samples)
    private var queue: [PrcFmt]?
    private var writeIndex: Int = 0
    // Allpass biquad state for fractional delay
    private var bqB0: PrcFmt = 0
    private var bqB1: PrcFmt = 0
    private var bqB2: PrcFmt = 0
    private var bqA1: PrcFmt = 0
    private var bqA2: PrcFmt = 0
    private var bqX1: PrcFmt = 0
    private var bqX2: PrcFmt = 0
    private var bqY1: PrcFmt = 0
    private var bqY2: PrcFmt = 0
    private var hasBiquad: Bool = false

    init(delaySamples: PrcFmt, subsample: Bool, sampleRate: Int) {
        configure(delaySamples: delaySamples, subsample: subsample, sampleRate: sampleRate)
    }

    /// Process one sample through this delay, returning the delayed output.
    /// Matches Rust `Delay::process_single`.
    @inline(__always)
    func processSingle(_ x: PrcFmt) -> PrcFmt {
        var out = x

        // Integer delay via ring buffer
        if let q = queue {
            let count = q.count
            // Read oldest sample from ring buffer
            let delayed = q[writeIndex]
            // Write current sample to same slot (push_overwrite pattern)
            var mq = q
            mq[writeIndex] = out
            queue = mq
            writeIndex = (writeIndex + 1) % count
            out = delayed
        }

        // Fractional delay via Direct-Form II Transposed biquad
        if hasBiquad {
            let y = bqB0 * out + bqB1 * bqX1 + bqB2 * bqX2
                  - bqA1 * bqY1 - bqA2 * bqY2
            bqX2 = bqX1
            bqX1 = out
            bqY2 = bqY1
            bqY1 = y
            out = y
        }

        return out
    }

    /// Reconfigure the delay (used in updateParameters). Resets state.
    func reconfigure(delaySamples: PrcFmt, subsample: Bool, sampleRate: Int) {
        configure(delaySamples: delaySamples, subsample: subsample, sampleRate: sampleRate)
    }

    // MARK: - Private helpers

    private func configure(delaySamples: PrcFmt, subsample: Bool, sampleRate: Int) {
        // Reset biquad state
        bqX1 = 0; bqX2 = 0; bqY1 = 0; bqY2 = 0
        hasBiquad = false

        if subsample {
            let (integerSamples, b0, b1, b2, a1, a2, hasBq) =
                SingleSampleDelay.buildSubsampleCoefficients(delaySamples: delaySamples)
            queue = integerSamples > 0 ? [PrcFmt](repeating: 0.0, count: integerSamples) : nil
            writeIndex = 0
            if hasBq {
                bqB0 = b0; bqB1 = b1; bqB2 = b2
                bqA1 = a1; bqA2 = a2
                hasBiquad = true
            }
        } else {
            let samples = Int(delaySamples.rounded())
            queue = samples > 0 ? [PrcFmt](repeating: 0.0, count: samples) : nil
            writeIndex = 0
        }
    }

    /// Mirrors Rust `build_subsample_biquad` from Swift DelayFilter.
    /// Returns (integerSamples, b0, b1, b2, a1, a2, hasBiquad).
    private static func buildSubsampleCoefficients(delaySamples: PrcFmt)
        -> (Int, PrcFmt, PrcFmt, PrcFmt, PrcFmt, PrcFmt, Bool)
    {
        if delaySamples < 0.1 {
            return (0, 0, 0, 0, 0, 0, false)
        }
        if delaySamples < 1.1 {
            // 1st order Thiran allpass
            let c = (1.0 - delaySamples) / (1.0 + delaySamples)
            // Rust BiquadCoefficients::new(a1=c, a2=0, b0=c, b1=1, b2=0)
            return (0, c, 1.0, 0.0, c, 0.0, true)
        }
        // 2nd order Thiran allpass
        var samples = delaySamples.rounded(.down)
        var fraction = delaySamples - samples
        samples -= 1.0
        fraction += 1.0
        if fraction < 1.1 {
            samples -= 1.0
            fraction += 1.0
        }
        let c1 = 2.0 * (2.0 - fraction) / (1.0 + fraction)
        let c2 = (2.0 - fraction) / (2.0 + fraction) * (1.0 - fraction) / (1.0 + fraction)
        // Rust BiquadCoefficients::new(a1=c1, a2=c2, b0=c2, b1=c1, b2=1)
        return (Int(samples), c2, c1, 1.0, c1, c2, true)
    }
}

// MARK: - RACE Processor

/// RACE: Recursive Ambiophonic Crosstalk Eliminator.
///
/// Processes two channels (A and B) by recursively feeding a delayed, attenuated,
/// and sign-inverted copy of each channel into the other, cancelling acoustic
/// crosstalk between loudspeakers.
///
/// Algorithm (per sample, matches Rust exactly):
///   added_a  = value_a + feedback_b
///   added_b  = value_b + feedback_a
///   feedback_a = gain(delay_a(added_a))   // applied next iteration
///   feedback_b = gain(delay_b(added_b))
///   output: value_a = added_a, value_b = added_b
///
/// The delay is compensated by one sample period (Rust: subtract 1 sample's
/// worth from the configured delay, clamped to zero).
/// The gain equals  –attenuation_dB, sign-inverted  →  –10^(−att/20).
public final class RACEProcessor: AudioProcessor {
    public let name: String

    // Channel indices (sorted: a < b)
    private var channelA: Int
    private var channelB: Int
    private var channels: Int
    private let sampleRate: Int

    // Recursive state
    private var feedbackA: PrcFmt = 0.0
    private var feedbackB: PrcFmt = 0.0

    // Sub-filters
    private var delayA: SingleSampleDelay
    private var delayB: SingleSampleDelay
    /// Linear gain (negative — attenuates and inverts, matching Rust gain_config)
    private var linearGain: PrcFmt

    // MARK: - Init

    public init(name: String, config: ProcessorConfig, sampleRate: Int) {
        self.name = name
        self.sampleRate = sampleRate
        let p = config.parameters

        let rawChannels = p.channels ?? 2
        self.channels = rawChannels

        let rawA = p.channelA ?? 0
        let rawB = p.channelB ?? 1
        // Sort so channelA < channelB (matches Rust)
        self.channelA = min(rawA, rawB)
        self.channelB = max(rawA, rawB)

        let attenuation = p.attenuation ?? 3.0        // dB
        let delay       = p.delay ?? 0.0              // in delay_unit
        let subsample   = p.subsampleDelay ?? false
        let unit        = DelayUnit(rawValue: p.delayUnit ?? "ms") ?? .ms

        let delaySamples = RACEProcessor.toSamples(delay: delay, unit: unit, sampleRate: sampleRate)
        let compensated  = RACEProcessor.compensate(delaySamples: delaySamples)

        self.delayA = SingleSampleDelay(delaySamples: compensated, subsample: subsample, sampleRate: sampleRate)
        self.delayB = SingleSampleDelay(delaySamples: compensated, subsample: subsample, sampleRate: sampleRate)

        // Rust gain_config: gain = -attenuation dB, inverted = true
        // linearGain = -db_to_linear(-attenuation) = -10^(-attenuation/20) = -10^(attenuation/20)^-1
        // i.e. a negative number with magnitude < 1 for attenuation > 0
        self.linearGain = -PrcFmt.fromDB(-attenuation)
    }

    // MARK: - AudioProcessor

    public func process(chunk: inout AudioChunk) throws {
        let frames = chunk.validFrames
        guard channelA < chunk.channels, channelB < chunk.channels else { return }
        guard frames > 0 else { return }

        // Obtain pointers to the two channel waveforms
        // AudioChunk.waveforms is [[PrcFmt]], indexed by channel
        for i in 0..<frames {
            let va = chunk.waveforms[channelA][i]
            let vb = chunk.waveforms[channelB][i]

            // Rust process_chunk:
            //   added_a = value_a + feedback_b
            //   added_b = value_b + feedback_a
            let addedA = va + feedbackB
            let addedB = vb + feedbackA

            // Update feedback: delay then gain (note: gain is negative)
            feedbackA = linearGain * delayA.processSingle(addedA)
            feedbackB = linearGain * delayB.processSingle(addedB)

            chunk.waveforms[channelA][i] = addedA
            chunk.waveforms[channelB][i] = addedB
        }
    }

    public func updateParameters(_ config: ProcessorConfig) {
        let p = config.parameters

        channels = p.channels ?? channels

        let rawA = p.channelA ?? channelA
        let rawB = p.channelB ?? channelB
        channelA = min(rawA, rawB)
        channelB = max(rawA, rawB)

        let attenuation = p.attenuation ?? 3.0
        let delay       = p.delay ?? 0.0
        let subsample   = p.subsampleDelay ?? false
        let unit        = DelayUnit(rawValue: p.delayUnit ?? "ms") ?? .ms

        let delaySamples = RACEProcessor.toSamples(delay: delay, unit: unit, sampleRate: sampleRate)
        let compensated  = RACEProcessor.compensate(delaySamples: delaySamples)

        delayA.reconfigure(delaySamples: compensated, subsample: subsample, sampleRate: sampleRate)
        delayB.reconfigure(delaySamples: compensated, subsample: subsample, sampleRate: sampleRate)

        linearGain = -PrcFmt.fromDB(-attenuation)

        // Reset feedback state on parameter update (avoids discontinuity on config change)
        feedbackA = 0.0
        feedbackB = 0.0
    }

    // MARK: - Private helpers

    /// Convert a delay value in the given unit to fractional samples.
    /// Matches Rust `delay_config` unit conversions.
    private static func toSamples(delay: PrcFmt, unit: DelayUnit, sampleRate: Int) -> PrcFmt {
        let sr = PrcFmt(sampleRate)
        switch unit {
        case .ms:      return delay / 1000.0 * sr
        case .us:      return delay / 1_000_000.0 * sr
        case .samples: return delay
        case .mm:      return delay / 1000.0 / 343.0 * sr
        }
    }

    /// Subtract one sample period from delaySamples, clamped at zero.
    /// Matches Rust: compensated_delay = (config.delay - sample_period).max(0.0)
    /// converted to samples: that is simply (delaySamples - 1.0).max(0.0).
    private static func compensate(delaySamples: PrcFmt) -> PrcFmt {
        return max(delaySamples - 1.0, 0.0)
    }
}
