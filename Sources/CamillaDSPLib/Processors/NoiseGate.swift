// CamillaDSP-Swift: NoiseGate processor - attenuates channels below threshold
// Matches Rust CamillaDSP: dB-domain envelope, configurable attenuation factor

import Foundation

public final class NoiseGateProcessor: AudioProcessor {
    public let name: String
    private var numChannels: Int
    private var processChannels: [Int]
    private var monitorChannels: [Int]
    private var threshold: PrcFmt        // dBFS
    private var attenuation: PrcFmt      // linear gain applied when gate is closed
    private let sampleRate: Int

    // Envelope detection (dB domain, matching Rust)
    private var attackCoeff: PrcFmt
    private var releaseCoeff: PrcFmt
    private var prevLoudness: PrcFmt = 0.0  // match Rust: start open (0 dB)
    private var gateOpen: Bool = false

    public init(name: String, config: ProcessorConfig, sampleRate: Int) {
        self.name = name
        self.sampleRate = sampleRate
        let params = config.parameters

        self.numChannels = params.channels ?? 2
        self.processChannels = params.processChannels ?? Array(0..<self.numChannels)
        self.monitorChannels = params.monitorChannels ?? self.processChannels
        self.threshold = params.threshold ?? -40.0
        // Rust: factor = db_to_linear(-attenuation). Default attenuation ~40 dB
        self.attenuation = PrcFmt.fromDB(-(params.attenuation ?? 40.0))

        let attackTime = params.attack ?? 0.001
        let releaseTime = params.release ?? 0.1
        self.attackCoeff = exp(-1.0 / (PrcFmt(sampleRate) * attackTime))
        self.releaseCoeff = exp(-1.0 / (PrcFmt(sampleRate) * releaseTime))
    }

    public func process(chunk: inout AudioChunk) throws {
        for i in 0..<chunk.validFrames {
            // Sum monitor channels (signed sum then abs, matching Rust)
            var sum: PrcFmt = 0
            for ch in monitorChannels {
                guard ch < chunk.channels else { continue }
                sum += chunk.waveforms[ch][i]
            }

            // Convert to dB (matching Rust: abs + 1e-9 floor)
            let inputDB = 20.0 * log10(abs(sum) + 1e-9)

            // Envelope follower in dB domain
            let coeff = inputDB > prevLoudness ? attackCoeff : releaseCoeff
            prevLoudness = coeff * prevLoudness + (1.0 - coeff) * inputDB

            // Gate logic
            gateOpen = prevLoudness > threshold

            // Apply attenuation when gate is closed (not hard mute)
            if !gateOpen {
                for ch in processChannels {
                    guard ch < chunk.channels else { continue }
                    chunk.waveforms[ch][i] *= attenuation
                }
            }
        }
    }

    public func updateParameters(_ config: ProcessorConfig) {
        let params = config.parameters
        numChannels = params.channels ?? 2
        processChannels = params.processChannels ?? Array(0..<numChannels)
        monitorChannels = params.monitorChannels ?? processChannels
        threshold = params.threshold ?? -40.0
        attenuation = PrcFmt.fromDB(-(params.attenuation ?? 40.0))
        let attackTime = params.attack ?? 0.001
        let releaseTime = params.release ?? 0.1
        attackCoeff = exp(-1.0 / (PrcFmt(sampleRate) * attackTime))
        releaseCoeff = exp(-1.0 / (PrcFmt(sampleRate) * releaseTime))
        // Preserve prevLoudness and gateOpen — no reset
    }
}
