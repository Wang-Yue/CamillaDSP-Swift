// CamillaDSP-Swift: Filter protocol - processes a single channel's waveform

import Foundation

/// Protocol for all audio filters. Filters operate on one channel at a time.
public protocol Filter: AnyObject {
    /// Process a waveform buffer in-place
    func process(waveform: inout [PrcFmt]) throws
    /// Update filter parameters from configuration
    func updateParameters(_ config: FilterConfig)
    /// Filter name for identification
    var name: String { get }
}

/// Per-filter config validation, dispatched by filter type
public enum FilterValidator {
    public static func validate(_ config: FilterConfig, sampleRate: Int) throws {
        let fs = Double(sampleRate)
        let nyquist = fs / 2.0
        let params = config.parameters

        switch config.type {
        case .biquad:
            try validateBiquad(params, nyquist: nyquist, sampleRate: sampleRate)
        case .biquadCombo:
            try validateBiquadCombo(params, nyquist: nyquist)
        case .gain:
            try validateGain(params)
        case .volume:
            try validateVolume(params)
        case .delay:
            try validateDelay(params)
        case .loudness:
            try validateLoudness(params)
        case .conv:
            break  // validated at load time (file read)
        case .diffEq:
            break  // no validation (matches Rust: TODO stability check)
        case .dither:
            try validateDither(params)
        case .limiter:
            break  // no validation (matches Rust: always OK)
        }
    }

    // MARK: - Biquad

    private static func validateBiquad(_ p: FilterParameters, nyquist: Double, sampleRate: Int) throws {
        let subtype = BiquadType(rawValue: p.subtype ?? "Peaking") ?? .peaking

        switch subtype {
        case .free:
            break  // no freq/Q validation for free-form coefficients
        case .linkwitzTransform:
            if let f = p.freqAct { try checkFreq(f, nyquist: nyquist, label: "freq_act") }
            if let f = p.freqTarget { try checkFreq(f, nyquist: nyquist, label: "freq_target") }
            if let q = p.qAct { try checkPositive(q, label: "q_act") }
            if let q = p.qTarget { try checkPositive(q, label: "q_target") }
        case .generalNotch:
            if let f = p.freqPole { try checkFreq(f, nyquist: nyquist, label: "freq_pole") }
            if let f = p.freqNotch { try checkFreq(f, nyquist: nyquist, label: "freq_notch") }
            if let q = p.q { try checkPositive(q, label: "Q") }
        default:
            if let freq = p.freq {
                try checkFreq(freq, nyquist: nyquist, label: "freq")
            }
            if let q = p.q {
                try checkPositive(q, label: "Q")
            }
            if let slope = p.slope {
                try checkPositive(slope, label: "slope")
                guard slope <= 12.0 else {
                    throw ConfigError.invalidFilter("slope must be <= 12.0 dB/oct, got \(slope)")
                }
            }
            if let bw = p.bandwidth {
                try checkPositive(bw, label: "bandwidth")
            }
        }

        // Stability check: try computing coefficients
        if let coeffs = try? BiquadFilter.computeCoefficients(p, sampleRate: sampleRate) {
            let a1 = coeffs.a1, a2 = coeffs.a2
            // Check poles inside unit circle
            if abs(a2) >= 1.0 || abs(a1) >= 1.0 + a2 {
                throw ConfigError.invalidFilter("Unstable biquad filter specified")
            }
        }
    }

    // MARK: - BiquadCombo

    private static func validateBiquadCombo(_ p: FilterParameters, nyquist: Double) throws {
        guard let comboType = p.comboType else {
            throw ConfigError.invalidFilter("BiquadCombo missing 'type'")
        }

        switch comboType {
        case .linkwitzRileyHighpass, .linkwitzRileyLowpass:
            if let freq = p.freq {
                guard freq > 0 else {
                    throw ConfigError.invalidFilter("Frequency must be > 0")
                }
                guard freq < nyquist else {
                    throw ConfigError.invalidFilter("Frequency must be < samplerate/2")
                }
            }
            if let order = p.order {
                guard order > 0 && order % 2 == 0 else {
                    throw ConfigError.invalidFilter("LR order must be an even non-zero number")
                }
            }

        case .butterworthHighpass, .butterworthLowpass:
            if let freq = p.freq {
                guard freq > 0 else {
                    throw ConfigError.invalidFilter("Frequency must be > 0")
                }
                guard freq < nyquist else {
                    throw ConfigError.invalidFilter("Frequency must be < samplerate/2")
                }
            }
            if let order = p.order {
                guard order > 0 else {
                    throw ConfigError.invalidFilter("Butterworth order must be larger than zero")
                }
            }

        case .tilt:
            let gain = p.slope ?? p.gain ?? 0.0
            guard gain > -100.0 else {
                throw ConfigError.invalidFilter("Gain must be > -100")
            }
            guard gain < 100.0 else {
                throw ConfigError.invalidFilter("Gain must be < 100")
            }

        case .fivePointPeq:
            if let fp = p.fivePointParams {
                guard fp.qLow > 0 && fp.qHigh > 0 && fp.qMid1 > 0 && fp.qMid2 > 0 && fp.qMid3 > 0 else {
                    throw ConfigError.invalidFilter("All Q-values must be > 0")
                }
                guard fp.fLow < nyquist && fp.fHigh < nyquist && fp.fMid1 < nyquist && fp.fMid2 < nyquist && fp.fMid3 < nyquist else {
                    throw ConfigError.invalidFilter("All frequencies must be < samplerate/2")
                }
            }

        case .graphicEqualizer:
            let freqMin = p.freqMin ?? 20.0
            let freqMax = p.freqMax ?? 20000.0
            guard freqMin > 0 && freqMax > 0 else {
                throw ConfigError.invalidFilter("Min and max frequencies must be > 0")
            }
            guard freqMin < nyquist && freqMax < nyquist else {
                throw ConfigError.invalidFilter("Min and max frequencies must be < samplerate/2")
            }
            guard freqMin < freqMax else {
                throw ConfigError.invalidFilter("Min frequency must be lower than max frequency")
            }
            if let gains = p.gains {
                for gain in gains {
                    guard gain >= -40.0 && gain <= 40.0 else {
                        throw ConfigError.invalidFilter("Equalizer gains must be within +- 40 dB")
                    }
                }
            }
        }
    }

    // MARK: - Gain

    private static func validateGain(_ p: FilterParameters) throws {
        if let gain = p.gain {
            guard gain > -150 && gain < 150 else {
                throw ConfigError.invalidFilter("gain must be in (-150, 150) dB, got \(gain)")
            }
        }
    }

    // MARK: - Volume

    private static func validateVolume(_ p: FilterParameters) throws {
        if let ramp = p.rampTime {
            guard ramp >= 0 else {
                throw ConfigError.invalidFilter("ramp_time must be >= 0, got \(ramp)")
            }
        }
    }

    // MARK: - Delay

    private static func validateDelay(_ p: FilterParameters) throws {
        if let delay = p.delay {
            guard delay >= 0 else {
                throw ConfigError.invalidFilter("delay must be >= 0, got \(delay)")
            }
        }
    }

    // MARK: - Loudness

    private static func validateLoudness(_ p: FilterParameters) throws {
        if let ref = p.referenceLevel {
            guard ref > -100 && ref < 20 else {
                throw ConfigError.invalidFilter("reference_level must be in (-100, 20), got \(ref)")
            }
        }
        if let boost = p.highBoost {
            guard boost >= 0 && boost <= 20 else {
                throw ConfigError.invalidFilter("high_boost must be in [0, 20], got \(boost)")
            }
        }
        if let boost = p.lowBoost {
            guard boost >= 0 && boost <= 20 else {
                throw ConfigError.invalidFilter("low_boost must be in [0, 20], got \(boost)")
            }
        }
    }

    // MARK: - Dither

    private static func validateDither(_ p: FilterParameters) throws {
        if let bits = p.bits {
            guard bits > 1 else {
                throw ConfigError.invalidFilter("bits must be > 1, got \(bits)")
            }
        }
    }

    // MARK: - Helpers

    private static func checkFreq(_ freq: Double, nyquist: Double, label: String) throws {
        guard freq > 0 else {
            throw ConfigError.invalidFilter("\(label) must be > 0, got \(freq)")
        }
        guard freq < nyquist else {
            throw ConfigError.invalidFilter("\(label) must be < Nyquist (\(nyquist) Hz), got \(freq)")
        }
    }

    private static func checkPositive(_ value: Double, label: String) throws {
        guard value > 0 else {
            throw ConfigError.invalidFilter("\(label) must be > 0, got \(value)")
        }
    }
}

/// Factory to create filter instances from configuration
public enum FilterFactory {
    public static func create(
        name: String,
        config: FilterConfig,
        sampleRate: Int,
        chunkSize: Int
    ) throws -> Filter {
        // Validate before creating
        try FilterValidator.validate(config, sampleRate: sampleRate)

        switch config.type {
        case .gain:
            return GainFilter(name: name, config: config)
        case .volume:
            return VolumeFilter(name: name, config: config, sampleRate: sampleRate, chunkSize: chunkSize)
        case .loudness:
            return LoudnessFilter(name: name, config: config, sampleRate: sampleRate)
        case .delay:
            return DelayFilter(name: name, config: config, sampleRate: sampleRate)
        case .conv:
            return try ConvolutionFilter(name: name, config: config, chunkSize: chunkSize, sampleRate: sampleRate)
        case .biquad:
            return try BiquadFilter(name: name, config: config, sampleRate: sampleRate)
        case .biquadCombo:
            return try BiquadComboFilter(name: name, config: config, sampleRate: sampleRate)
        case .diffEq:
            return DiffEqFilter(name: name, config: config)
        case .dither:
            return DitherFilter(name: name, config: config)
        case .limiter:
            return LimiterFilter(name: name, config: config)
        }
    }
}
