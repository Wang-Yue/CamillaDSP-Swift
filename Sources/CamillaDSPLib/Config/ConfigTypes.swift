// CamillaDSP-Swift: Configuration type definitions (maps to YAML config)

import Foundation

// MARK: - Top-level Configuration

public struct CamillaDSPConfig: Codable {
    public var title: String?
    public var description: String?
    public var devices: DevicesConfig
    public var filters: [String: FilterConfig]?
    public var mixers: [String: MixerConfig]?
    public var processors: [String: ProcessorConfig]?
    public var pipeline: [PipelineStep]?

    public init(devices: DevicesConfig) { self.devices = devices }
}

// MARK: - Devices

public struct DevicesConfig: Codable {
    public var samplerate: Int
    public var chunksize: Int
    public var enableRateAdjust: Bool?
    public var targetLevel: Int?
    public var adjustPeriod: Double?
    public var volumeRampTime: Double?
    public var volumeLimit: Double?
    public var multithreaded: Bool?
    public var workerThreads: Int?
    public var resampler: ResamplerConfig?
    public var capture: CaptureDeviceConfig
    public var playback: PlaybackDeviceConfig
    /// Capture sample rate when different from playback (requires resampler)
    public var captureSamplerate: Int?
    /// Silence detection threshold (dB). 0 = disabled.
    public var silenceThreshold: Double?
    /// Silence detection timeout (seconds). 0 = disabled.
    public var silenceTimeout: Double?
    /// Stop processing on sample rate change (requires restart)
    public var stopOnRateChange: Bool?
    /// Max number of chunks in the playback queue
    public var queuelimit: Int?
    /// Interval in seconds for rate measurement
    public var rateMeasureInterval: Double?

    enum CodingKeys: String, CodingKey {
        case samplerate, chunksize, resampler, capture, playback, queuelimit, multithreaded
        case enableRateAdjust = "enable_rate_adjust"
        case targetLevel = "target_level"
        case adjustPeriod = "adjust_period"
        case volumeRampTime = "volume_ramp_time"
        case volumeLimit = "volume_limit"
        case workerThreads = "worker_threads"
        case captureSamplerate = "capture_samplerate"
        case silenceThreshold = "silence_threshold"
        case silenceTimeout = "silence_timeout"
        case stopOnRateChange = "stop_on_rate_change"
        case rateMeasureInterval = "rate_measure_interval"
    }

    public init(samplerate: Int, chunksize: Int, capture: CaptureDeviceConfig, playback: PlaybackDeviceConfig) {
        self.samplerate = samplerate; self.chunksize = chunksize; self.capture = capture; self.playback = playback
    }
}

public struct CaptureDeviceConfig: Codable {
    public var type: AudioBackendType
    public var channels: Int
    public var device: String?
    public var format: SampleFormat?
    public var extraSamples: Int?
    /// Signal generator parameters — only used when type == .signalGenerator
    public var signal: SignalConfig?
    /// Optional per-channel labels (matches Rust config)
    public var labels: [String?]?

    enum CodingKeys: String, CodingKey {
        case type, channels, device, format, signal, labels
        case extraSamples = "extra_samples"
    }
    public init(type: AudioBackendType, channels: Int, device: String? = nil, format: SampleFormat? = nil, signal: SignalConfig? = nil, labels: [String?]? = nil) {
        self.type = type; self.channels = channels; self.device = device; self.format = format; self.signal = signal; self.labels = labels
    }
}

// MARK: - Signal Generator

/// Mirrors Rust's `config::Signal` enum.
/// `level` is in dBFS — converted to linear amplitude inside `SignalGeneratorCapture`.
public enum SignalConfig: Codable {
    case sine(freq: Double, level: Double)
    case square(freq: Double, level: Double)
    case whiteNoise(level: Double)

    private enum CodingKeys: String, CodingKey { case type, freq, level }
    private enum SignalType: String, Codable { case Sine, Square, WhiteNoise }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(SignalType.self, forKey: .type)
        switch kind {
        case .Sine:
            let freq  = try c.decode(Double.self, forKey: .freq)
            let level = try c.decode(Double.self, forKey: .level)
            self = .sine(freq: freq, level: level)
        case .Square:
            let freq  = try c.decode(Double.self, forKey: .freq)
            let level = try c.decode(Double.self, forKey: .level)
            self = .square(freq: freq, level: level)
        case .WhiteNoise:
            let level = try c.decode(Double.self, forKey: .level)
            self = .whiteNoise(level: level)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sine(let freq, let level):
            try c.encode(SignalType.Sine, forKey: .type)
            try c.encode(freq,  forKey: .freq)
            try c.encode(level, forKey: .level)
        case .square(let freq, let level):
            try c.encode(SignalType.Square, forKey: .type)
            try c.encode(freq,  forKey: .freq)
            try c.encode(level, forKey: .level)
        case .whiteNoise(let level):
            try c.encode(SignalType.WhiteNoise, forKey: .type)
            try c.encode(level, forKey: .level)
        }
    }
}

public struct PlaybackDeviceConfig: Codable {
    public var type: AudioBackendType
    public var channels: Int
    public var device: String?
    public var format: SampleFormat?
    public var exclusive: Bool?
    /// Optional per-channel labels (matches Rust config)
    public var labels: [String?]?

    enum CodingKeys: String, CodingKey {
        case type, channels, device, format, exclusive, labels
    }
    public init(type: AudioBackendType, channels: Int, device: String? = nil, format: SampleFormat? = nil, exclusive: Bool? = nil, labels: [String?]? = nil) {
        self.type = type; self.channels = channels; self.device = device; self.format = format; self.exclusive = exclusive; self.labels = labels
    }
}

public enum AudioBackendType: String, Codable {
    case coreAudio = "CoreAudio"
    case rawFile = "RawFile"
    case wavFile = "WavFile"
    case stdin = "Stdin"
    case stdout = "Stdout"
    case signalGenerator = "SignalGenerator"
}

// MARK: - Resampler

public struct ResamplerConfig: Codable {
    public var type: ResamplerType
    public var profile: ResamplerProfile?
    public var sincLen: Int?
    public var oversamplingFactor: Int?

    enum CodingKeys: String, CodingKey {
        case type, profile
        case sincLen = "sinc_len"
        case oversamplingFactor = "oversampling_factor"
    }

    public init(type: ResamplerType, profile: ResamplerProfile? = nil) {
        self.type = type; self.profile = profile
    }
}

public enum ResamplerType: String, Codable {
    case asyncSinc = "AsyncSinc"
    case asyncPoly = "AsyncPoly"
    case synchronous = "Synchronous"
}

public enum ResamplerProfile: String, Codable {
    case veryFast = "VeryFast"
    case fast = "Fast"
    case balanced = "Balanced"
    case accurate = "Accurate"
}

// MARK: - Filters

public struct FilterConfig: Codable {
    public var type: FilterType
    public var parameters: FilterParameters

    public init(type: FilterType, parameters: FilterParameters) {
        self.type = type; self.parameters = parameters
    }
}

public enum FilterType: String, Codable {
    case gain = "Gain"
    case volume = "Volume"
    case loudness = "Loudness"
    case delay = "Delay"
    case conv = "Conv"
    case biquad = "Biquad"
    case biquadCombo = "BiquadCombo"
    case diffEq = "DiffEq"
    case dither = "Dither"
    case limiter = "Limiter"
}

public struct FilterParameters: Codable {
    public init() {}

    // Gain
    public var gain: Double?
    public var scale: GainScale?
    public var inverted: Bool?
    public var mute: Bool?

    // Volume
    public var fader: Fader?
    public var rampTime: Double?
    public var limit: Double?

    // Loudness
    public var referenceLevel: Double?
    public var highBoost: Double?
    public var lowBoost: Double?
    public var attenuateMid: Bool?

    // Delay
    public var delay: Double?
    public var unit: DelayUnit?
    public var subsample: Bool?

    // Conv / Biquad / BiquadCombo - all use "type" key in YAML
    public var subtype: String?

    // Conv
    public var convType: ConvType? { subtype.flatMap { ConvType(rawValue: $0) } }
    public var filename: String?
    public var channel: Int?
    public var values: [PrcFmt]?
    public var rawFormat: String?

    // Biquad
    public var biquadType: BiquadType? { subtype.flatMap { BiquadType(rawValue: $0) } }
    public var freq: Double?
    public var q: Double?
    public var slope: Double?
    public var bandwidth: Double?
    public var a1: Double?
    public var a2: Double?
    public var b0: Double?
    public var b1: Double?
    public var b2: Double?
    public var freqNotch: Double?
    public var freqPole: Double?
    public var normalizeAtDc: Bool?
    public var freqAct: Double?
    public var qAct: Double?
    public var freqTarget: Double?
    public var qTarget: Double?

    // BiquadCombo
    public var comboType: BiquadComboType? { subtype.flatMap { BiquadComboType(rawValue: $0) } }
    public var order: Int?
    public var freqMin: Double?
    public var freqMax: Double?
    public var gains: [Double]?
    // FivePointPeq
    public var fivePointParams: FivePointPeqParams?

    // DiffEq
    public var a: [Double]?
    public var b: [Double]?

    // Dither
    public var ditherType: DitherType? { subtype.flatMap { DitherType(rawValue: $0) } }
    public var bits: Int?
    public var amplitude: Double?

    // Limiter
    public var clipLimit: Double?
    public var softClip: Bool?

    enum CodingKeys: String, CodingKey {
        case gain, scale, inverted, mute
        case fader
        case rampTime = "ramp_time"
        case limit
        case referenceLevel = "reference_level"
        case highBoost = "high_boost"
        case lowBoost = "low_boost"
        case attenuateMid = "attenuate_mid"
        case delay, unit, subsample
        case subtype = "type"
        case filename, channel, values
        case rawFormat = "format"
        case freq, q, slope, bandwidth
        case a1, a2, b0, b1, b2
        case freqNotch = "freq_notch"
        case freqPole = "freq_pole"
        case normalizeAtDc = "normalize_at_dc"
        case freqAct = "freq_act"
        case qAct = "q_act"
        case freqTarget = "freq_target"
        case qTarget = "q_target"
        case order
        case freqMin = "freq_min"
        case freqMax = "freq_max"
        case gains
        case fivePointParams
        case a, b
        case bits, amplitude
        case clipLimit = "clip_limit"
        case softClip = "soft_clip"
    }
}

public enum GainScale: String, Codable {
    case dB
    case linear
}

public enum DelayUnit: String, Codable {
    case ms
    case us
    case samples
    case mm
}

public enum ConvType: String, Codable {
    case wav = "Wav"
    case raw = "Raw"
    case values = "Values"
}

public enum BiquadType: String, Codable {
    case free = "Free"
    case highpass = "Highpass"
    case lowpass = "Lowpass"
    case highpassFO = "HighpassFO"
    case lowpassFO = "LowpassFO"
    case highshelf = "Highshelf"
    case lowshelf = "Lowshelf"
    case highshelfFO = "HighshelfFO"
    case lowshelfFO = "LowshelfFO"
    case peaking = "Peaking"
    case notch = "Notch"
    case generalNotch = "GeneralNotch"
    case bandpass = "Bandpass"
    case allpass = "Allpass"
    case allpassFO = "AllpassFO"
    case linkwitzTransform = "LinkwitzTransform"
}

public enum BiquadComboType: String, Codable {
    case butterworthHighpass = "ButterworthHighpass"
    case butterworthLowpass = "ButterworthLowpass"
    case linkwitzRileyHighpass = "LinkwitzRileyHighpass"
    case linkwitzRileyLowpass = "LinkwitzRileyLowpass"
    case tilt = "Tilt"
    case fivePointPeq = "FivePointPeq"
    case graphicEqualizer = "GraphicEqualizer"
}

public struct FivePointPeqParams: Codable {
    public var fLow: Double
    public var gLow: Double
    public var qLow: Double
    public var fMid1: Double
    public var gMid1: Double
    public var qMid1: Double
    public var fMid2: Double
    public var gMid2: Double
    public var qMid2: Double
    public var fMid3: Double
    public var gMid3: Double
    public var qMid3: Double
    public var fHigh: Double
    public var gHigh: Double
    public var qHigh: Double

    enum CodingKeys: String, CodingKey {
        case fLow = "f_low", gLow = "g_low", qLow = "q_low"
        case fMid1 = "f_mid1", gMid1 = "g_mid1", qMid1 = "q_mid1"
        case fMid2 = "f_mid2", gMid2 = "g_mid2", qMid2 = "q_mid2"
        case fMid3 = "f_mid3", gMid3 = "g_mid3", qMid3 = "q_mid3"
        case fHigh = "f_high", gHigh = "g_high", qHigh = "q_high"
    }
}

public enum DitherType: String, Codable {
    case none = "None"
    case flat = "Flat"
    case highpass = "Highpass"
    case fweighted441 = "Fweighted441"
    case fweightedLong441 = "FweightedLong441"
    case fweightedShort441 = "FweightedShort441"
    case gesemann441 = "Gesemann441"
    case gesemann48 = "Gesemann48"
    case lipshitz441 = "Lipshitz441"
    case lipshitzLong441 = "LipshitzLong441"
    case shibata441 = "Shibata441"
    case shibataHigh441 = "ShibataHigh441"
    case shibataLow441 = "ShibataLow441"
    case shibata48 = "Shibata48"
    case shibataHigh48 = "ShibataHigh48"
    case shibataLow48 = "ShibataLow48"
    case shibata882 = "Shibata882"
    case shibataLow882 = "ShibataLow882"
    case shibata96 = "Shibata96"
    case shibataLow96 = "ShibataLow96"
    case shibata192 = "Shibata192"
    case shibataLow192 = "ShibataLow192"
}

// MARK: - Mixers

/// Helper for decoding the Rust nested format: `channels: { in: N, out: N }`
private struct MixerChannelsNested: Codable {
    var `in`: Int
    var out: Int
}

public struct MixerConfig: Codable {
    public var channelsIn: Int
    public var channelsOut: Int
    public var mapping: [MixerMapping]
    public var description: String?
    public var labels: [String?]?

    public init(channelsIn: Int, channelsOut: Int, mapping: [MixerMapping]) {
        self.channelsIn = channelsIn; self.channelsOut = channelsOut; self.mapping = mapping
    }

    // Support both Rust nested format `channels: { in: N, out: N }` and
    // flat format `channels_in: N, channels_out: N`
    private enum CodingKeys: String, CodingKey {
        case channels             // Rust nested format
        case channelsIn = "channels_in"   // flat format
        case channelsOut = "channels_out" // flat format
        case mapping
        case description
        case labels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mapping = try container.decode([MixerMapping].self, forKey: .mapping)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        labels = try container.decodeIfPresent([String?].self, forKey: .labels)

        // Try nested format first: channels: { in: N, out: N }
        if let nested = try? container.decode(MixerChannelsNested.self, forKey: .channels) {
            channelsIn = nested.in
            channelsOut = nested.out
        } else {
            // Fall back to flat format: channels_in / channels_out
            channelsIn = try container.decode(Int.self, forKey: .channelsIn)
            channelsOut = try container.decode(Int.self, forKey: .channelsOut)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Encode in the Rust-compatible nested format
        let nested = MixerChannelsNested(in: channelsIn, out: channelsOut)
        try container.encode(nested, forKey: .channels)
        try container.encode(mapping, forKey: .mapping)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(labels, forKey: .labels)
    }
}

public struct MixerMapping: Codable {
    public var dest: Int
    public var sources: [MixerSource]
    public var mute: Bool?

    public init(dest: Int, sources: [MixerSource], mute: Bool? = nil) {
        self.dest = dest; self.sources = sources; self.mute = mute
    }
}

public struct MixerSource: Codable {
    public var channel: Int
    /// Gain value. Optional in Rust YAML (defaults to 0.0 dB when omitted).
    public var gain: Double?
    public var inverted: Bool?
    public var mute: Bool?
    public var scale: GainScale?

    /// Convenience accessor matching Rust default: 0.0 when gain is nil
    public var gainValue: Double { gain ?? 0.0 }

    public init(channel: Int, gain: Double? = nil, inverted: Bool? = nil, mute: Bool? = nil, scale: GainScale? = nil) {
        self.channel = channel; self.gain = gain; self.inverted = inverted; self.mute = mute; self.scale = scale
    }
}

// MARK: - Processors

public struct ProcessorConfig: Codable {
    public var type: ProcessorType
    public var parameters: ProcessorParameters

    public init(type: ProcessorType, parameters: ProcessorParameters) {
        self.type = type; self.parameters = parameters
    }
}

public enum ProcessorType: String, Codable {
    case compressor = "Compressor"
    case noiseGate = "NoiseGate"
    case race = "RACE"
}

public struct ProcessorParameters: Codable {
    /// Number of channels (scalar in Rust). Decodes from either Int or [Int] for compatibility.
    public var channels: Int?
    public var monitorChannels: [Int]?
    /// Channels to apply processing to (Rust: process_channels)
    public var processChannels: [Int]?
    /// Attack time in seconds (Rust key: "attack")
    public var attack: Double?
    /// Release time in seconds (Rust key: "release")
    public var release: Double?
    public var threshold: Double?
    /// Compression ratio (Rust key: "factor")
    public var factor: Double?
    public var makeupGain: Double?
    public var clipLimit: Double?
    public var softClip: Bool?
    public var attenuation: Double?  // NoiseGate: dB of attenuation when closed

    // RACE parameters
    public var channelA: Int?
    public var channelB: Int?
    public var delay: Double?
    public var subsampleDelay: Bool?
    public var delayUnit: String?

    enum CodingKeys: String, CodingKey {
        case channels
        case monitorChannels = "monitor_channels"
        case processChannels = "process_channels"
        case attack
        case release
        case threshold, factor
        case makeupGain = "makeup_gain"
        case clipLimit = "clip_limit"
        case softClip = "soft_clip"
        case attenuation
        case channelA = "channel_a"
        case channelB = "channel_b"
        case delay
        case subsampleDelay = "subsample_delay"
        case delayUnit = "delay_unit"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // channels: support both scalar Int (Rust) and [Int] array (legacy Swift) for compatibility
        if let scalar = try? container.decode(Int.self, forKey: .channels) {
            channels = scalar
        } else if let array = try? container.decode([Int].self, forKey: .channels),
                  let count = array.max().map({ $0 + 1 }) {
            channels = count
        }

        monitorChannels = try container.decodeIfPresent([Int].self, forKey: .monitorChannels)
        processChannels = try container.decodeIfPresent([Int].self, forKey: .processChannels)
        attack = try container.decodeIfPresent(Double.self, forKey: .attack)
        release = try container.decodeIfPresent(Double.self, forKey: .release)
        threshold = try container.decodeIfPresent(Double.self, forKey: .threshold)
        factor = try container.decodeIfPresent(Double.self, forKey: .factor)
        makeupGain = try container.decodeIfPresent(Double.self, forKey: .makeupGain)
        clipLimit = try container.decodeIfPresent(Double.self, forKey: .clipLimit)
        softClip = try container.decodeIfPresent(Bool.self, forKey: .softClip)
        attenuation = try container.decodeIfPresent(Double.self, forKey: .attenuation)
        channelA = try container.decodeIfPresent(Int.self, forKey: .channelA)
        channelB = try container.decodeIfPresent(Int.self, forKey: .channelB)
        delay = try container.decodeIfPresent(Double.self, forKey: .delay)
        subsampleDelay = try container.decodeIfPresent(Bool.self, forKey: .subsampleDelay)
        delayUnit = try container.decodeIfPresent(String.self, forKey: .delayUnit)
    }
}

// MARK: - Pipeline

public struct PipelineStep: Codable {
    public var type: PipelineStepType
    public var channel: Int?
    public var channels: [Int]?
    public var name: String?
    public var names: [String]?
    public var bypassed: Bool?

    public init(type: PipelineStepType, channel: Int? = nil, channels: [Int]? = nil,
                name: String? = nil, names: [String]? = nil, bypassed: Bool? = nil) {
        self.type = type; self.channel = channel; self.channels = channels
        self.name = name; self.names = names; self.bypassed = bypassed
    }
}

public enum PipelineStepType: String, Codable {
    case filter = "Filter"
    case mixer = "Mixer"
    case processor = "Processor"
}
