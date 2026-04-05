// CamillaDSP-Swift: Compressor processor - dynamic range compression
// Matches Rust CamillaDSP: dB-domain envelope detection, chunk-level processing

import Foundation

public final class CompressorProcessor: AudioProcessor {
    public let name: String
    private var channels: Int                  // total number of channels
    private var monitorChannels: [Int]
    private var processChannels: [Int]
    private var threshold: PrcFmt              // dBFS
    private var factor: PrcFmt                 // compression ratio
    private var makeupGain: PrcFmt             // dB
    private var softClip: Bool
    private let sampleRate: Int

    // Limiter (nil = disabled, matching Rust Option<Limiter>)
    private var clipLimit: PrcFmt?             // linear, nil when disabled
    private var softClipEnabled: Bool

    // Envelope detection (dB domain, matching Rust)
    private var attackCoeff: PrcFmt            // smoothing coeff (close to 1.0)
    private var releaseCoeff: PrcFmt           // smoothing coeff (close to 1.0)
    private var prevLoudness: PrcFmt = -100.0  // envelope in dB

    // Scratch buffer for chunk-level processing (matches Rust)
    private var scratch: [PrcFmt]

    public init(name: String, config: ProcessorConfig, sampleRate: Int, chunkSize: Int = 0) {
        self.name = name
        self.sampleRate = sampleRate
        let params = config.parameters

        self.channels = params.channels ?? 2
        self.processChannels = params.processChannels ?? Array(0..<self.channels)
        self.monitorChannels = params.monitorChannels ?? self.processChannels
        self.threshold = params.threshold ?? -20.0
        self.factor = params.factor ?? 4.0
        self.makeupGain = params.makeupGain ?? 0.0
        self.softClip = params.softClip ?? false

        let attackTime = params.attack ?? 0.005
        let releaseTime = params.release ?? 0.05
        // Rust: attack = exp(-1.0 / srate / config.attack)
        self.attackCoeff = exp(-1.0 / (PrcFmt(sampleRate) * attackTime))
        self.releaseCoeff = exp(-1.0 / (PrcFmt(sampleRate) * releaseTime))

        // Rust: clip_limit = config.clip_limit.map(db_to_linear) — None means disabled
        if let clipLimitDB = params.clipLimit {
            self.clipLimit = PrcFmt.fromDB(clipLimitDB)
            self.softClipEnabled = params.softClip ?? false
        } else {
            self.clipLimit = nil
            self.softClipEnabled = false
        }

        self.scratch = [PrcFmt](repeating: 0.0, count: max(chunkSize, 1))
    }

    // MARK: - Chunk-level processing (matches Rust methods)

    /// Sum all monitor channels into scratch buffer (Rust: sum_monitor_channels)
    private func sumMonitorChannels(_ chunk: AudioChunk) {
        let frames = chunk.validFrames

        // Ensure scratch is large enough
        if scratch.count < frames {
            scratch = [PrcFmt](repeating: 0.0, count: frames)
        }

        // Copy first monitor channel
        let firstCh = monitorChannels[0]
        if firstCh < chunk.channels {
            for i in 0..<frames {
                scratch[i] = chunk.waveforms[firstCh][i]
            }
        }

        // Sum remaining monitor channels
        for chIdx in monitorChannels.dropFirst() {
            guard chIdx < chunk.channels else { continue }
            for i in 0..<frames {
                scratch[i] += chunk.waveforms[chIdx][i]
            }
        }
    }

    /// Estimate loudness in dB domain, store in scratch (Rust: estimate_loudness)
    private func estimateLoudness(_ frames: Int) {
        for i in 0..<frames {
            // Convert to dB (abs of sum + 1e-9 floor)
            var val = 20.0 * log10(abs(scratch[i]) + 1e-9)

            // Envelope follower
            if val >= prevLoudness {
                val = attackCoeff * prevLoudness + (1.0 - attackCoeff) * val
            } else {
                val = releaseCoeff * prevLoudness + (1.0 - releaseCoeff) * val
            }
            prevLoudness = val
            scratch[i] = val
        }
    }

    /// Calculate linear gain from loudness, store in scratch (Rust: calculate_linear_gain)
    private func calculateLinearGain(_ frames: Int) {
        for i in 0..<frames {
            var val = scratch[i]
            if val > threshold {
                val = -(val - threshold) * (factor - 1.0) / factor
            } else {
                val = 0.0
            }
            val += makeupGain
            scratch[i] = PrcFmt.fromDB(val)
        }
    }

    /// Apply gain from scratch to a channel (Rust: apply_gain)
    private func applyGain(_ waveform: inout [PrcFmt], frames: Int) {
        for i in 0..<frames {
            waveform[i] *= scratch[i]
        }
    }

    /// Apply limiter clipping if configured (Rust: apply_limiter)
    private func applyLimiter(_ waveform: inout [PrcFmt], frames: Int) {
        guard let limit = clipLimit else { return }  // None = disabled

        if softClipEnabled {
            // Cubic soft clipping (matches Rust Limiter soft clip)
            for i in 0..<frames {
                var scaled = waveform[i] / limit
                scaled = max(-1.5, min(1.5, scaled))
                waveform[i] = (scaled - scaled * scaled * scaled / 6.75) * limit
            }
        } else {
            // Hard clipping
            for i in 0..<frames {
                waveform[i] = max(-limit, min(limit, waveform[i]))
            }
        }
    }

    public func process(chunk: inout AudioChunk) throws {
        let frames = chunk.validFrames

        // Rust chunk-level pipeline: sum -> envelope -> gain -> apply
        sumMonitorChannels(chunk)
        estimateLoudness(frames)
        calculateLinearGain(frames)

        for ch in processChannels {
            guard ch < chunk.channels else { continue }
            applyGain(&chunk.waveforms[ch], frames: frames)
            applyLimiter(&chunk.waveforms[ch], frames: frames)
        }
    }

    public func updateParameters(_ config: ProcessorConfig) {
        let params = config.parameters
        channels = params.channels ?? 2
        processChannels = params.processChannels ?? Array(0..<channels)
        monitorChannels = params.monitorChannels ?? processChannels
        threshold = params.threshold ?? -20.0
        factor = params.factor ?? 4.0
        makeupGain = params.makeupGain ?? 0.0

        let attackTime = params.attack ?? 0.005
        let releaseTime = params.release ?? 0.05
        attackCoeff = exp(-1.0 / (PrcFmt(sampleRate) * attackTime))
        releaseCoeff = exp(-1.0 / (PrcFmt(sampleRate) * releaseTime))

        // Rust: clip_limit = config.clip_limit.map(db_to_linear) — None means disabled
        if let clipLimitDB = params.clipLimit {
            clipLimit = PrcFmt.fromDB(clipLimitDB)
            softClipEnabled = params.softClip ?? false
        } else {
            clipLimit = nil
            softClipEnabled = false
        }
        // Preserve prevLoudness (envelope state) -- no reset
    }
}
