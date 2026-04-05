// CamillaDSP-Swift: Delay filter - introduces latency via ring buffer
// Supports sub-sample fractional delay via Thiran allpass interpolation
// Faithfully matches the Rust CamillaDSP implementation in basicfilters.rs

import Foundation

/// Builds the subsample biquad allpass and returns (integerDelaySamples, optionalBiquad).
/// Matches Rust `build_subsample_biquad` exactly.
private func buildSubsampleBiquad(delay: PrcFmt, sampleRate: Int) -> (Int, BiquadFilter?) {
    // delay is less than 0.1 samples, ignore
    if delay < 0.1 {
        return (0, nil)
    }
    // delay is less than 1.1 samples, use first order allpass
    if delay < 1.1 {
        let coeff = (1.0 - delay) / (1.0 + delay)
        // 1st order Thiran allpass
        // Rust: BiquadCoefficients::new(coeff, 0.0, coeff, 1.0, 0.0)
        // Rust new(a1, a2, b0, b1, b2)
        let coeffs = BiquadCoefficients(b0: coeff, b1: 1.0, b2: 0.0, a1: coeff, a2: 0.0)
        return (0, BiquadFilter(name: "subsample", coefficients: coeffs, sampleRate: sampleRate))
    }

    // delay is large enough to use a second order allpass
    var samples = delay.rounded(.down) // floor
    var fraction = delay - samples
    // adjust fraction and samples to keep fraction between 1.1 and 2.1
    samples -= 1.0
    fraction += 1.0
    if fraction < 1.1 {
        samples -= 1.0
        fraction += 1.0
    }
    // 2nd order Thiran allpass
    // Rust: coeff1 = 2.0 * (2.0 - fraction) / (1.0 + fraction)
    // Rust: coeff2 = (2.0 - fraction) / (2.0 + fraction) * (1.0 - fraction) / (1.0 + fraction)
    // Rust: BiquadCoefficients::new(coeff1, coeff2, coeff2, coeff1, 1.0)
    // Rust new(a1, a2, b0, b1, b2) → a1=coeff1, a2=coeff2, b0=coeff2, b1=coeff1, b2=1.0
    let coeff1 = 2.0 * (2.0 - fraction) / (1.0 + fraction)
    let coeff2 = (2.0 - fraction) / (2.0 + fraction) * (1.0 - fraction) / (1.0 + fraction)
    let coeffs = BiquadCoefficients(b0: coeff2, b1: coeff1, b2: 1.0, a1: coeff1, a2: coeff2)
    return (
        Int(samples),
        BiquadFilter(name: "subsample", coefficients: coeffs, sampleRate: sampleRate)
    )
}

public final class DelayFilter: Filter {
    public let name: String
    private let sampleRate: Int

    // Ring buffer for integer delay (matches Rust: ringbuf filled with zeros, capacity = integerdelay)
    private var queue: [PrcFmt]?
    private var readIndex: Int = 0

    // Allpass biquad for fractional delay
    private var biquad: BiquadFilter?

    public init(name: String, config: FilterConfig, sampleRate: Int) {
        self.name = name
        self.sampleRate = sampleRate

        let params = config.parameters
        let delay = params.delay ?? 0.0
        let unit = params.unit ?? .ms
        let subsample = params.subsample ?? false

        let delaySamples = DelayFilter.computeDelaySamples(delay: delay, unit: unit, sampleRate: sampleRate)
        let (integerDelay, bq) = DelayFilter.buildDelay(
            name: name, delaySamples: delaySamples, subsample: subsample, sampleRate: sampleRate
        )
        self.queue = integerDelay > 0 ? [PrcFmt](repeating: 0.0, count: integerDelay) : nil
        self.readIndex = 0
        self.biquad = bq
    }

    /// Direct initializer matching Rust `Delay::new(name, samplerate, delay, subsample)`
    public init(name: String, sampleRate: Int, delaySamples: PrcFmt, subsample: Bool) {
        self.name = name
        self.sampleRate = sampleRate

        let (integerDelay, bq) = DelayFilter.buildDelay(
            name: name, delaySamples: delaySamples, subsample: subsample, sampleRate: sampleRate
        )
        self.queue = integerDelay > 0 ? [PrcFmt](repeating: 0.0, count: integerDelay) : nil
        self.readIndex = 0
        self.biquad = bq
    }

    private static func computeDelaySamples(delay: PrcFmt, unit: DelayUnit, sampleRate: Int) -> PrcFmt {
        switch unit {
        case .ms:
            return delay / 1000.0 * PrcFmt(sampleRate)
        case .us:
            return delay / 1_000_000.0 * PrcFmt(sampleRate)
        case .samples:
            return delay
        case .mm:
            return delay / 1000.0 * PrcFmt(sampleRate) / 343.0
        }
    }

    private static func buildDelay(
        name: String, delaySamples: PrcFmt, subsample: Bool, sampleRate: Int
    ) -> (Int, BiquadFilter?) {
        if subsample {
            let (samples, bq) = buildSubsampleBiquad(delay: delaySamples, sampleRate: sampleRate)
            return (samples, bq)
        } else {
            let samples = Int(delaySamples.rounded())
            return (samples, nil)
        }
    }

    public func process(waveform: inout [PrcFmt]) throws {
        // Integer delay via ring buffer (push_overwrite pattern from Rust)
        if var q = queue {
            let count = q.count
            var ri = readIndex
            for i in 0..<waveform.count {
                let delayed = q[ri]
                q[ri] = waveform[i]
                waveform[i] = delayed
                ri = (ri + 1) % count
            }
            readIndex = ri
            queue = q
        }
        // Fractional delay via allpass biquad
        if let bq = biquad {
            try bq.process(waveform: &waveform)
        }
    }

    public func updateParameters(_ config: FilterConfig) {
        let params = config.parameters
        let delay = params.delay ?? 0.0
        let unit = params.unit ?? .ms
        let subsample = params.subsample ?? false

        let delaySamples = DelayFilter.computeDelaySamples(delay: delay, unit: unit, sampleRate: sampleRate)
        let (integerDelay, bq) = DelayFilter.buildDelay(
            name: name, delaySamples: delaySamples, subsample: subsample, sampleRate: sampleRate
        )
        self.queue = integerDelay > 0 ? [PrcFmt](repeating: 0.0, count: integerDelay) : nil
        self.readIndex = 0
        self.biquad = bq
    }
}
