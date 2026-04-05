// CamillaDSP-Swift: Processor protocol - operates on full AudioChunk (cross-channel)

import Foundation

/// Protocol for audio processors that work across channels simultaneously
public protocol AudioProcessor: AnyObject {
    /// Process a full audio chunk in-place
    func process(chunk: inout AudioChunk) throws
    /// Update processor parameters
    func updateParameters(_ config: ProcessorConfig)
    /// Processor name
    var name: String { get }
}

/// Per-processor config validation
public enum ProcessorValidator {
    public static func validate(_ config: ProcessorConfig, channels: Int) throws {
        let params = config.parameters
        switch config.type {
        case .compressor:
            try validateCompressor(params, channels: channels)
        case .noiseGate:
            try validateNoiseGate(params, channels: channels)
        case .race:
            try validateRACE(params, channels: channels)
        }
    }

    private static func validateCompressor(_ p: ProcessorParameters, channels: Int) throws {
        if let attack = p.attack {
            guard attack > 0 else {
                throw ConfigError.invalidFilter("compressor attack must be > 0, got \(attack)")
            }
        }
        if let release = p.release {
            guard release > 0 else {
                throw ConfigError.invalidFilter("compressor release must be > 0, got \(release)")
            }
        }
        if let totalChannels = p.channels {
            guard totalChannels <= channels else {
                throw ConfigError.invalidFilter("compressor channels \(totalChannels) > total channels \(channels)")
            }
        }
        if let chs = p.processChannels {
            for ch in chs {
                guard ch < channels else {
                    throw ConfigError.invalidFilter("compressor process channel \(ch) >= total channels \(channels)")
                }
            }
        }
        if let chs = p.monitorChannels {
            for ch in chs {
                guard ch < channels else {
                    throw ConfigError.invalidFilter("compressor monitor channel \(ch) >= total channels \(channels)")
                }
            }
        }
    }

    private static func validateRACE(_ p: ProcessorParameters, channels: Int) throws {
        guard let attenuation = p.attenuation, attenuation > 0 else {
            throw ConfigError.invalidFilter(
                "RACE attenuation must be > 0, got \(p.attenuation.map { String($0) } ?? "nil")"
            )
        }
        guard let delay = p.delay, delay > 0 else {
            throw ConfigError.invalidFilter(
                "RACE delay must be > 0, got \(p.delay.map { String($0) } ?? "nil")"
            )
        }
        let chA = p.channelA ?? 0
        let chB = p.channelB ?? 1
        guard chA != chB else {
            throw ConfigError.invalidFilter("RACE channel_a and channel_b must be different")
        }
        guard chA < channels else {
            throw ConfigError.invalidFilter(
                "RACE channel_a \(chA) >= total channels \(channels), max is \(channels - 1)"
            )
        }
        guard chB < channels else {
            throw ConfigError.invalidFilter(
                "RACE channel_b \(chB) >= total channels \(channels), max is \(channels - 1)"
            )
        }
    }

    private static func validateNoiseGate(_ p: ProcessorParameters, channels: Int) throws {
        if let attack = p.attack {
            guard attack > 0 else {
                throw ConfigError.invalidFilter("noise gate attack must be > 0, got \(attack)")
            }
        }
        if let release = p.release {
            guard release > 0 else {
                throw ConfigError.invalidFilter("noise gate release must be > 0, got \(release)")
            }
        }
        if let totalChannels = p.channels {
            guard totalChannels <= channels else {
                throw ConfigError.invalidFilter("noise gate channels \(totalChannels) > total channels \(channels)")
            }
        }
        if let chs = p.processChannels {
            for ch in chs {
                guard ch < channels else {
                    throw ConfigError.invalidFilter("noise gate process channel \(ch) >= total channels \(channels)")
                }
            }
        }
        if let chs = p.monitorChannels {
            for ch in chs {
                guard ch < channels else {
                    throw ConfigError.invalidFilter("noise gate monitor channel \(ch) >= total channels \(channels)")
                }
            }
        }
    }
}

/// Factory to create processor instances from configuration
public enum ProcessorFactory {
    public static func create(
        name: String,
        config: ProcessorConfig,
        sampleRate: Int,
        chunkSize: Int,
        channels: Int = 2
    ) throws -> AudioProcessor {
        try ProcessorValidator.validate(config, channels: channels)

        switch config.type {
        case .compressor:
            return CompressorProcessor(name: name, config: config, sampleRate: sampleRate)
        case .noiseGate:
            return NoiseGateProcessor(name: name, config: config, sampleRate: sampleRate)
        case .race:
            return RACEProcessor(name: name, config: config, sampleRate: sampleRate)
        }
    }
}
