// CamillaDSP-Swift: Mixer - routes and sums audio between channels

import Foundation
import Accelerate

/// Mixer config validation
public enum MixerValidator {
    public static func validate(_ config: MixerConfig) throws {
        var seenDests = Set<Int>()
        for map in config.mapping {
            guard map.dest < config.channelsOut else {
                throw ConfigError.invalidFilter("mixer dest \(map.dest) >= channels_out \(config.channelsOut)")
            }
            guard !seenDests.contains(map.dest) else {
                throw ConfigError.invalidFilter("mixer dest \(map.dest) mapped more than once")
            }
            seenDests.insert(map.dest)

            var seenSources = Set<Int>()
            for src in map.sources {
                guard src.channel < config.channelsIn else {
                    throw ConfigError.invalidFilter("mixer source channel \(src.channel) >= channels_in \(config.channelsIn)")
                }
                guard !seenSources.contains(src.channel) else {
                    throw ConfigError.invalidFilter("mixer source channel \(src.channel) listed more than once for dest \(map.dest)")
                }
                seenSources.insert(src.channel)
            }
        }
    }
}

/// A mixer source: one input channel contributing to an output channel
public struct MixerSourceEntry {
    public let channel: Int
    public let gain: PrcFmt
}

/// Mixer that changes channel count and routes/sums audio between channels
public final class AudioMixer {
    public let name: String
    public private(set) var channelsIn: Int
    public private(set) var channelsOut: Int
    private var mapping: [[MixerSourceEntry]]  // mapping[outCh] = list of sources
    private var mutedOutputs: Set<Int>

    public init(name: String, config: MixerConfig) {
        self.name = name
        self.channelsIn = config.channelsIn
        self.channelsOut = config.channelsOut
        self.mapping = []
        self.mutedOutputs = []
        applyConfig(config)
    }

    public func updateParameters(_ config: MixerConfig) {
        applyConfig(config)
    }

    private func applyConfig(_ config: MixerConfig) {
        channelsIn = config.channelsIn
        channelsOut = config.channelsOut

        var newMapping = [[MixerSourceEntry]](repeating: [], count: config.channelsOut)
        var newMutedOutputs = Set<Int>()

        for map in config.mapping {
            if map.mute == true {
                newMutedOutputs.insert(map.dest)
                continue
            }

            var sources: [MixerSourceEntry] = []
            for src in map.sources {
                if src.mute == true { continue }

                var linearGain: PrcFmt
                switch src.scale ?? .dB {
                case .dB:
                    linearGain = PrcFmt.fromDB(src.gainValue)
                case .linear:
                    linearGain = src.gainValue
                }
                if src.inverted == true { linearGain *= -1.0 }

                sources.append(MixerSourceEntry(channel: src.channel, gain: linearGain))
            }
            newMapping[map.dest] = sources
        }

        mapping = newMapping
        mutedOutputs = newMutedOutputs
    }

    /// Process chunk through mixer, producing a new chunk with potentially different channel count
    public func process(chunk: AudioChunk) -> AudioChunk {
        var output = AudioChunk(frames: chunk.frames, channels: channelsOut)
        output.validFrames = chunk.validFrames

        for outCh in 0..<channelsOut {
            if mutedOutputs.contains(outCh) {
                // Already zeroed
                continue
            }

            let sources = mapping[outCh]
            for source in sources {
                guard source.channel < chunk.channels else { continue }
                let inputWaveform = chunk.waveforms[source.channel]

                if source.gain == 1.0 {
                    // Simple add
                    DSPOps.add(inputWaveform, &output.waveforms[outCh], count: chunk.validFrames)
                } else {
                    // Scale and add
                    DSPOps.multiplyAdd(inputWaveform, source.gain, accumulator: &output.waveforms[outCh], count: chunk.validFrames)
                }
            }
        }

        return output
    }
}
