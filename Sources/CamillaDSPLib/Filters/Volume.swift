// CamillaDSP-Swift: Volume filter - fader-linked gain with smooth ramping
// Matches Rust CamillaDSP: chunk-granular ramp approach

import Foundation

public final class VolumeFilter: Filter {
    public let name: String
    private var fader: Fader
    private var volumeLimit: Double
    private let sampleRate: Int
    private let chunkSize: Int

    // Ramp state (matches Rust Volume struct fields)
    private var ramptimeInChunks: Int
    private var currentVolume: PrcFmt       // current volume in dB (tracks ramp progress)
    private var targetVolume: Double         // target volume in dB (from shared params, after limit)
    private var targetLinearGain: PrcFmt    // 10^(targetVolume/20), or 0 if muted
    private var mute: Bool
    private var rampStart: PrcFmt           // dB value at start of ramp
    private var rampStep: Int               // 0 = not ramping; 1..ramptimeInChunks = active ramp step

    // Shared parameters (set externally)
    public var processingParameters: ProcessingParameters?

    public init(name: String, config: FilterConfig, sampleRate: Int, chunkSize: Int) {
        self.name = name
        self.fader = config.parameters.fader ?? .main
        let rampTimeMs = config.parameters.rampTime ?? 400.0
        self.volumeLimit = config.parameters.limit ?? 50.0
        self.sampleRate = sampleRate
        self.chunkSize = chunkSize

        // Rust: ramptime_in_chunks = (ramp_time_ms / (1000.0 * chunksize / samplerate)).round() as usize
        self.ramptimeInChunks = Int((rampTimeMs / (1000.0 * Double(chunkSize) / Double(sampleRate))).rounded())

        // Initialize with 0 dB, not muted (will be updated on first process call)
        self.currentVolume = 0.0
        self.targetVolume = 0.0
        self.targetLinearGain = 1.0
        self.mute = false
        self.rampStart = 0.0
        self.rampStep = 0
    }

    /// Convenience initializer matching Rust Volume::new for direct construction (used in tests)
    public init(name: String, rampTimeMs: Double, limit: Double, currentVolume: Double,
                mute: Bool, chunkSize: Int, sampleRate: Int,
                processingParameters: ProcessingParameters, fader: Fader) {
        self.name = name
        self.fader = fader
        self.volumeLimit = limit
        self.sampleRate = sampleRate
        self.chunkSize = chunkSize
        self.processingParameters = processingParameters

        // Rust: ramptime_in_chunks = (ramp_time_ms / (1000.0 * chunksize / samplerate)).round() as usize
        self.ramptimeInChunks = Int((rampTimeMs / (1000.0 * Double(chunkSize) / Double(sampleRate))).rounded())

        // Rust: current_volume_with_mute = if mute { -100.0 } else { current_volume }
        let currentVolumeWithMute: PrcFmt = mute ? -100.0 : currentVolume
        self.currentVolume = currentVolumeWithMute
        self.rampStart = currentVolume
        self.targetVolume = currentVolume
        self.mute = mute
        self.rampStep = 0

        // Rust: target_linear_gain = if mute { 0.0 } else { 10.powf(current_volume / 20.0) }
        if mute {
            self.targetLinearGain = 0.0
        } else {
            self.targetLinearGain = pow(10.0, currentVolume / 20.0)
        }
    }

    /// Build the per-sample ramp gains for the current chunk (matches Rust make_ramp)
    private func makeRamp() -> [PrcFmt] {
        // Rust: target_volume = if self.mute { -100.0 } else { self.target_volume }
        let targetVol: PrcFmt = mute ? -100.0 : PrcFmt(targetVolume)

        // Rust: ramprange = (target_volume - self.ramp_start) / self.ramptime_in_chunks
        let ramprange = (targetVol - rampStart) / PrcFmt(ramptimeInChunks)

        // Rust: stepsize = ramprange / self.chunksize
        let stepsize = ramprange / PrcFmt(chunkSize)

        // Rust: (0..self.chunksize).map(|val| 10.0.powf((ramp_start + ramprange*(ramp_step-1) + val*stepsize) / 20.0))
        return (0..<chunkSize).map { val in
            pow(10.0,
                (rampStart
                 + ramprange * (PrcFmt(rampStep) - 1.0)
                 + PrcFmt(val) * stepsize)
                / 20.0)
        }
    }

    /// Check shared parameters for volume/mute changes (matches Rust prepare_processing)
    private func prepareProcessing() {
        guard let params = processingParameters else { return }

        let sharedVol = params.getTargetVolume(fader)
        let sharedMute = params.isMuted(fader)

        // Rust: are we above the set limit?
        let targetVol = min(sharedVol, volumeLimit)

        // Rust: Volume setting changed — use 0.01 dB threshold
        if abs(targetVol - targetVolume) > 0.01 || mute != sharedMute {
            if ramptimeInChunks > 0 {
                // Start ramp
                rampStart = currentVolume
                rampStep = 1
            } else {
                // Switch volume without ramp
                currentVolume = sharedMute ? 0.0 : PrcFmt(targetVol)
                rampStep = 0
            }
            targetVolume = targetVol
            if sharedMute {
                targetLinearGain = 0.0
            } else {
                targetLinearGain = pow(10.0, PrcFmt(targetVol) / 20.0)
            }
            mute = sharedMute
        }
    }

    public func process(waveform: inout [PrcFmt]) throws {
        prepareProcessing()

        // Not in a ramp
        if rampStep == 0 {
            for i in 0..<waveform.count {
                waveform[i] *= targetLinearGain
            }
        }
        // Ramping
        else if rampStep <= ramptimeInChunks {
            let ramp = makeRamp()
            rampStep += 1
            if rampStep > ramptimeInChunks {
                // Last step of ramp
                rampStep = 0
            }
            for i in 0..<waveform.count {
                waveform[i] *= ramp[i]
            }
            // Rust: self.current_volume = 20.0 * ramp.last().unwrap().log10()
            if let lastGain = ramp.last {
                currentVolume = 20.0 * log10(lastGain)
            }
        }
        // rampStep > ramptimeInChunks should not happen, but guard against it
        else {
            rampStep = 0
        }

        // Update shared current volume
        processingParameters?.setCurrentVolume(fader, currentVolume)
    }

    public func updateParameters(_ config: FilterConfig) {
        fader = config.parameters.fader ?? .main
        let rampTimeMs = config.parameters.rampTime ?? 400.0
        volumeLimit = config.parameters.limit ?? 50.0

        // Rust: recalculate ramptime_in_chunks
        ramptimeInChunks = Int((rampTimeMs / (1000.0 * Double(chunkSize) / Double(sampleRate))).rounded())

        // Rust: clamp currentVolume if above new limit
        if volumeLimit < currentVolume {
            currentVolume = volumeLimit
        }
    }
}
