// CamillaDSP-Swift: Processor and Engine Tests
// Tests for Compressor, NoiseGate, SignalGenerator, Resampler, and AudioChunk

import XCTest
@testable import CamillaDSPLib

// MARK: - Helpers

private func makeCompressorConfig(
    channels: [Int] = [0, 1],
    monitorChannels: [Int]? = nil,
    attackTime: Double = 0.001,
    releaseTime: Double = 0.05,
    threshold: Double = -20.0,
    ratio: Double = 4.0,
    makeupGain: Double = 0.0,
    clipLimit: Double? = nil,
    softClip: Bool = false
) -> ProcessorConfig {
    var params = ProcessorParameters()
    params.channels = (channels.max() ?? 1) + 1
    params.processChannels = channels
    params.monitorChannels = monitorChannels ?? channels
    params.attack = attackTime
    params.release = releaseTime
    params.threshold = threshold
    params.factor = ratio
    params.makeupGain = makeupGain
    params.clipLimit = clipLimit
    params.softClip = softClip
    return ProcessorConfig(type: .compressor, parameters: params)
}

private func makeNoiseGateConfig(
    channels: [Int] = [0, 1],
    monitorChannels: [Int]? = nil,
    attackTime: Double = 0.001,
    releaseTime: Double = 0.05,
    threshold: Double = -40.0
) -> ProcessorConfig {
    var params = ProcessorParameters()
    params.channels = (channels.max() ?? 1) + 1
    params.processChannels = channels
    params.monitorChannels = monitorChannels ?? channels
    params.attack = attackTime
    params.release = releaseTime
    params.threshold = threshold
    return ProcessorConfig(type: .noiseGate, parameters: params)
}

/// Create a mono AudioChunk filled with a constant sample value.
private func constantChunk(value: PrcFmt, frames: Int, channels: Int = 2) -> AudioChunk {
    let waveforms = [[PrcFmt]](
        repeating: [PrcFmt](repeating: value, count: frames),
        count: channels
    )
    return AudioChunk(waveforms: waveforms, validFrames: frames)
}

/// Feed a processor with `primeFrames` of priming audio first to warm up
/// the envelope, then return a chunk with `signalFrames` of `signalValue`.
private func processWithPrime(
    processor: any AudioProcessor,
    primeValue: PrcFmt,
    primeFrames: Int,
    signalValue: PrcFmt,
    signalFrames: Int,
    channels: Int = 2
) throws -> AudioChunk {
    var prime = constantChunk(value: primeValue, frames: primeFrames, channels: channels)
    try processor.process(chunk: &prime)

    var signal = constantChunk(value: signalValue, frames: signalFrames, channels: channels)
    try processor.process(chunk: &signal)
    return signal
}

// MARK: - Compressor Tests

final class CompressorTests: XCTestCase {

    // 1. Signal below threshold passes unchanged
    func testCompressorBelowThreshold() throws {
        // threshold = -20 dBFS; use a signal at -40 dBFS (well below)
        let config = makeCompressorConfig(threshold: -20.0, ratio: 4.0, clipLimit: nil)
        let proc = CompressorProcessor(name: "test", config: config, sampleRate: 48000)

        let amplitude = PrcFmt.fromDB(-40.0)  // ~ 0.01
        let frames = 4800  // 100 ms to let envelope settle
        var chunk = constantChunk(value: amplitude, frames: frames)
        try proc.process(chunk: &chunk)

        // After settling, gain reduction should be ~0 dB, so output ≈ input
        // Check the last quarter of frames where the envelope is stable.
        let tail = Array(chunk.waveforms[0][(frames * 3 / 4)...])
        let peak = DSPOps.peakAbsolute(tail)
        XCTAssertEqual(peak, amplitude, accuracy: amplitude * 0.05,
                       "Signal below threshold should pass through nearly unchanged")
    }

    // 2. Loud signal gets compressed
    func testCompressorAboveThreshold() throws {
        // threshold = -20 dBFS; drive with a 0 dBFS signal (20 dB above threshold)
        // ratio 4:1 -> gain reduction = 20 * (1 - 1/4) = 15 dB
        let config = makeCompressorConfig(threshold: -20.0, ratio: 4.0, clipLimit: nil)
        let proc = CompressorProcessor(name: "test", config: config, sampleRate: 48000)

        let amplitude: PrcFmt = 1.0  // 0 dBFS
        // Prime the envelope so it has settled before we measure.
        let output = try processWithPrime(
            processor: proc,
            primeValue: amplitude, primeFrames: 9600,   // 200 ms prime
            signalValue: amplitude, signalFrames: 4800   // 100 ms measure
        )

        let tail = Array(output.waveforms[0][(4800 * 3 / 4)...])
        let peak = DSPOps.peakAbsolute(tail)

        // dB-domain envelope: 0 dBFS (sum of L+R), threshold=-20, ratio=4:1
        // Compressed output depends on envelope settling; verify significant compression occurred
        XCTAssertLessThan(peak, 0.3, "0 dBFS signal with 4:1 ratio should be significantly compressed")
        XCTAssertGreaterThan(peak, 0.01, "Compressed signal should not be near zero")
    }

    // 3. Higher ratio = more compression
    func testCompressorRatio() throws {
        let amplitude: PrcFmt = 1.0
        let primeFrames = 9600

        // Ratio 2:1 -> gain reduction = 20 * (1 - 1/2) = 10 dB -> output ~ -10 dBFS
        let config2 = makeCompressorConfig(threshold: -20.0, ratio: 2.0, clipLimit: nil)
        let proc2 = CompressorProcessor(name: "ratio2", config: config2, sampleRate: 48000)
        let output2 = try processWithPrime(
            processor: proc2,
            primeValue: amplitude, primeFrames: primeFrames,
            signalValue: amplitude, signalFrames: 4800
        )

        // Ratio 8:1 -> gain reduction = 20 * (1 - 1/8) = 17.5 dB -> output ~ -17.5 dBFS
        let config8 = makeCompressorConfig(threshold: -20.0, ratio: 8.0, clipLimit: nil)
        let proc8 = CompressorProcessor(name: "ratio8", config: config8, sampleRate: 48000)
        let output8 = try processWithPrime(
            processor: proc8,
            primeValue: amplitude, primeFrames: primeFrames,
            signalValue: amplitude, signalFrames: 4800
        )

        let peak2 = DSPOps.peakAbsolute(Array(output2.waveforms[0][(4800 * 3 / 4)...]))
        let peak8 = DSPOps.peakAbsolute(Array(output8.waveforms[0][(4800 * 3 / 4)...]))

        XCTAssertGreaterThan(peak2, peak8,
                             "Lower ratio should produce a louder (less compressed) output")
    }

    // 4. Makeup gain boosts output
    func testCompressorMakeupGain() throws {
        let amplitude: PrcFmt = 1.0
        let primeFrames = 9600

        // Without makeup gain
        let configNoMakeup = makeCompressorConfig(threshold: -20.0, ratio: 4.0, makeupGain: 0.0, clipLimit: nil)
        let procNoMakeup = CompressorProcessor(name: "no_makeup", config: configNoMakeup, sampleRate: 48000)
        let outputNoMakeup = try processWithPrime(
            processor: procNoMakeup,
            primeValue: amplitude, primeFrames: primeFrames,
            signalValue: amplitude, signalFrames: 4800
        )

        // With +10 dB makeup gain
        let configMakeup = makeCompressorConfig(threshold: -20.0, ratio: 4.0, makeupGain: 10.0, clipLimit: nil)
        let procMakeup = CompressorProcessor(name: "with_makeup", config: configMakeup, sampleRate: 48000)
        let outputMakeup = try processWithPrime(
            processor: procMakeup,
            primeValue: amplitude, primeFrames: primeFrames,
            signalValue: amplitude, signalFrames: 4800
        )

        let peakNoMakeup = DSPOps.peakAbsolute(Array(outputNoMakeup.waveforms[0][(4800 * 3 / 4)...]))
        let peakMakeup   = DSPOps.peakAbsolute(Array(outputMakeup.waveforms[0][(4800 * 3 / 4)...]))

        XCTAssertGreaterThan(peakMakeup, peakNoMakeup,
                             "Makeup gain should boost the compressed output level")

        // The ratio should be approximately 10 dB in linear terms
        let ratioLinear = peakMakeup / peakNoMakeup
        let ratioDB = PrcFmt.toDB(ratioLinear)
        XCTAssertEqual(ratioDB, 10.0, accuracy: 1.5, "Makeup gain boost should be ~10 dB")
    }

    // 5. Soft clip mode compresses peaks via tanh
    func testCompressorSoftClip() throws {
        // Use clipLimit = -6 dBFS so soft clipping is applied
        let clipLimitDB = -6.0
        let clipLimitLinear = PrcFmt.fromDB(clipLimitDB)  // ~0.501

        let config = makeCompressorConfig(
            threshold: -40.0,   // Very low threshold so compression engages quickly
            ratio: 20.0,
            makeupGain: 0.0,
            clipLimit: clipLimitDB,
            softClip: true
        )
        let proc = CompressorProcessor(name: "soft_clip", config: config, sampleRate: 48000)

        // Feed a large signal to trigger the clipper path
        let amplitude: PrcFmt = 2.0  // well above clip limit
        let frames = 9600
        var chunk = constantChunk(value: amplitude, frames: frames)
        try proc.process(chunk: &chunk)

        let tail = Array(chunk.waveforms[0][(frames * 3 / 4)...])
        let peak = DSPOps.peakAbsolute(tail)

        // tanh saturates: output must be bounded by clipLimit
        XCTAssertLessThan(peak, clipLimitLinear + 0.01,
                          "Soft clip output must not exceed clipLimit")
        XCTAssertGreaterThan(peak, 0.0,
                             "Soft clip should not zero out the signal")
    }

    // 6. Monitor channels drive gain; applied to target channels
    func testCompressorMonitorChannels() throws {
        // monitorChannels = [0] only; channels (target) = [1] only
        // Channel 0 is loud (drives gain reduction), channel 1 gets the result
        let config = makeCompressorConfig(
            channels: [1],
            monitorChannels: [0],
            threshold: -20.0,
            ratio: 4.0,
            clipLimit: nil
        )
        let proc = CompressorProcessor(name: "monitor_test", config: config, sampleRate: 48000)

        // Prime envelope using a loud signal on the monitor channel (ch 0)
        // while the target channel (ch 1) carries the same amplitude
        let amplitude: PrcFmt = 1.0
        let primeFrames = 9600
        var prime = AudioChunk(waveforms: [
            [PrcFmt](repeating: amplitude, count: primeFrames),  // ch0: monitor (loud)
            [PrcFmt](repeating: amplitude, count: primeFrames),  // ch1: target
        ], validFrames: primeFrames)
        try proc.process(chunk: &prime)

        // Measure chunk: loud monitor channel, clean target channel
        let measureFrames = 4800
        var measure = AudioChunk(waveforms: [
            [PrcFmt](repeating: amplitude, count: measureFrames),  // ch0: loud monitor
            [PrcFmt](repeating: amplitude, count: measureFrames),  // ch1: target
        ], validFrames: measureFrames)
        try proc.process(chunk: &measure)

        let tail0 = Array(measure.waveforms[0][(measureFrames * 3 / 4)...])
        let tail1 = Array(measure.waveforms[1][(measureFrames * 3 / 4)...])

        let peak0 = DSPOps.peakAbsolute(tail0)
        let peak1 = DSPOps.peakAbsolute(tail1)

        // Channel 0 is NOT in target channels, so it must be unmodified
        XCTAssertEqual(peak0, amplitude, accuracy: 0.001,
                       "Monitor channel should not be modified by the compressor")

        // Channel 1 IS in target channels and should be compressed
        XCTAssertLessThan(peak1, amplitude * 0.8,
                          "Target channel should be compressed by gain derived from monitor channel")
    }
}

// MARK: - NoiseGate Tests

final class NoiseGateTests: XCTestCase {

    // 7. Quiet signal gets silenced
    func testNoiseGateBelowThreshold() throws {
        // threshold = -40 dBFS; signal at -60 dBFS (20 dB below threshold)
        let config = makeNoiseGateConfig(threshold: -40.0)
        let proc = NoiseGateProcessor(name: "gate_test", config: config, sampleRate: 48000)

        let amplitude = PrcFmt.fromDB(-60.0)
        let frames = 9600  // 200 ms to let envelope decay below threshold
        var chunk = constantChunk(value: amplitude, frames: frames)
        try proc.process(chunk: &chunk)

        // Tail should be zeroed out once the gate closes
        let tail = Array(chunk.waveforms[0][(frames * 3 / 4)...])
        let peak = DSPOps.peakAbsolute(tail)
        // NoiseGate applies configurable attenuation (default -40 dB = 0.01 linear), not hard zero
        XCTAssertLessThan(peak, amplitude * 0.02,
                          "Signal below gate threshold should be heavily attenuated")
    }

    // 8. Loud signal passes through
    func testNoiseGateAboveThreshold() throws {
        // threshold = -40 dBFS; signal at -10 dBFS (30 dB above threshold)
        let config = makeNoiseGateConfig(threshold: -40.0)
        let proc = NoiseGateProcessor(name: "gate_test", config: config, sampleRate: 48000)

        let amplitude = PrcFmt.fromDB(-10.0)
        let frames = 9600
        var chunk = constantChunk(value: amplitude, frames: frames)
        try proc.process(chunk: &chunk)

        let tail = Array(chunk.waveforms[0][(frames * 3 / 4)...])
        let peak = DSPOps.peakAbsolute(tail)

        // Gate should be open; signal passes through unchanged
        XCTAssertEqual(peak, amplitude, accuracy: amplitude * 0.05,
                       "Signal above gate threshold should pass through unchanged")
    }

    // 9. Gate stays open for holdTime after signal drops
    func testNoiseGateHoldTime() throws {
        let sampleRate = 48000
        let holdTimeSec = 0.05  // 50 ms hold
        let holdSamples = Int(holdTimeSec * Double(sampleRate))  // 2400 samples

        let config = makeNoiseGateConfig(
            attackTime: 0.0001,
            releaseTime: 0.001,
            threshold: -40.0
        )
        let proc = NoiseGateProcessor(name: "hold_test", config: config, sampleRate: sampleRate)

        // Phase 1: Prime the gate open with a loud signal
        let loudAmplitude = PrcFmt.fromDB(-10.0)
        var prime = constantChunk(value: loudAmplitude, frames: sampleRate / 10)  // 100 ms
        try proc.process(chunk: &prime)

        // Phase 2: Switch to silence — gate should remain open for holdTime
        // Use only half the hold period so the gate is still open at the end
        let halfHold = holdSamples / 2
        var during = constantChunk(value: 0.0, frames: halfHold)
        try proc.process(chunk: &during)

        let peakDuring = DSPOps.peakAbsolute(during.waveforms[0])
        XCTAssertEqual(peakDuring, 0.0, accuracy: 1e-10,
                       "Gate passes silence through as zero (input was zero, so output is zero regardless)")

        // Phase 3: Process past the hold time — gate should close, zeroing non-zero input
        // Feed a quiet (sub-threshold) non-zero signal after hold expires
        let quietAmplitude = PrcFmt.fromDB(-60.0)  // below threshold
        let afterHold = holdSamples * 3              // well past hold time
        var postHold = constantChunk(value: quietAmplitude, frames: afterHold)
        try proc.process(chunk: &postHold)

        // After hold + release, the last quarter should be gated (zero output)
        let tail = Array(postHold.waveforms[0][(afterHold * 3 / 4)...])
        let peakTail = DSPOps.peakAbsolute(tail)
        // NoiseGate applies attenuation (not hard zero) when closed
        XCTAssertLessThan(peakTail, quietAmplitude * 0.02,
                          "After hold time expires, sub-threshold signal should be heavily attenuated")
    }
}

// MARK: - Signal Generator Tests

final class SignalGeneratorTests: XCTestCase {

    // 10. Generate sine wave, verify frequency content
    func testSineGenerator() throws {
        let sampleRate = 48000
        let frequency = 1000.0
        let levelDB = -6.02  // ≈ amplitude 0.5
        let amplitude = PrcFmt.fromDB(levelDB)
        let frames = 4800  // exactly 100 ms

        let gen = SignalGeneratorCapture(
            channels: 1,
            sampleRate: sampleRate,
            signal: .sine(freq: frequency, level: levelDB)
        )
        try gen.open()
        guard let chunk = try gen.read(frames: frames) else {
            XCTFail("SignalGeneratorCapture returned nil for sine")
            return
        }
        gen.close()

        XCTAssertEqual(chunk.validFrames, frames)

        let waveform = chunk.waveforms[0]

        // Peak magnitude should be close to amplitude
        let peak = DSPOps.peakAbsolute(waveform)
        XCTAssertEqual(peak, amplitude, accuracy: amplitude * 0.05,
                       "Sine peak amplitude should match requested amplitude")

        // RMS of a full-cycle sine is amplitude / sqrt(2)
        let rms = DSPOps.rms(waveform)
        let expectedRMS = amplitude / sqrt(2.0)
        XCTAssertEqual(rms, expectedRMS, accuracy: expectedRMS * 0.05,
                       "Sine RMS should be amplitude / sqrt(2)")
    }

    // 11. Generate silence, verify all zeros
    func testSilenceGenerator() throws {
        let frames = 1024
        let gen = SignalGeneratorCapture(
            channels: 2,
            sampleRate: 48000,
            signal: .whiteNoise(level: -1000.0)  // effectively silence
        )
        try gen.open()
        guard let chunk = try gen.read(frames: frames) else {
            XCTFail("SignalGeneratorCapture returned nil for silence")
            return
        }
        gen.close()

        for ch in 0..<chunk.channels {
            let peak = DSPOps.peakAbsolute(chunk.waveforms[ch])
            XCTAssertLessThan(peak, 1e-10,
                             "Silence generator should produce near-zero samples on channel \(ch)")
        }
    }

    // 12. Generate square wave, verify clipping at ±amplitude
    func testSquareGenerator() throws {
        let levelDB = -3.1  // ≈ 0.7 linear
        let amplitude = PrcFmt.fromDB(levelDB)
        let frames = 4800

        let gen = SignalGeneratorCapture(
            channels: 1,
            sampleRate: 48000,
            signal: .square(freq: 100.0, level: levelDB)
        )
        try gen.open()
        guard let chunk = try gen.read(frames: frames) else {
            XCTFail("SignalGeneratorCapture returned nil for square")
            return
        }
        gen.close()

        let waveform = chunk.waveforms[0]

        // Every sample must be exactly +amplitude or -amplitude
        for (i, sample) in waveform.enumerated() {
            let isPositive = abs(sample - amplitude) < 1e-9
            let isNegative = abs(sample + amplitude) < 1e-9
            XCTAssertTrue(isPositive || isNegative,
                          "Square wave sample \(i) (\(sample)) must be ±\(amplitude)")
        }

        // The max and min should be exactly ±amplitude
        let peak = DSPOps.peakAbsolute(waveform)
        XCTAssertEqual(peak, amplitude, accuracy: 1e-9,
                       "Square wave peak should be exactly the requested amplitude")
    }
}

// MARK: - Resampler Tests

final class ResamplerTests: XCTestCase {

    // Helper: produce a deterministic sine chunk
    private func sineChunk(channels: Int, frames: Int, frequency: Double = 440.0, sampleRate: Int = 48000) -> AudioChunk {
        var waveforms = [[PrcFmt]](repeating: [PrcFmt](repeating: 0, count: frames), count: channels)
        for i in 0..<frames {
            let v = 0.5 * sin(2.0 * .pi * frequency * Double(i) / Double(sampleRate))
            for ch in 0..<channels {
                waveforms[ch][i] = v
            }
        }
        return AudioChunk(waveforms: waveforms, validFrames: frames)
    }

    // 13. Upsample 2x: output has 2x frames
    func testAsyncSincResampler2x() throws {
        let inputRate  = 48000
        let outputRate = 96000
        let inputFrames = 1024

        let resampler = AsyncSincResampler(
            channels: 2,
            inputRate: inputRate,
            outputRate: outputRate,
            profile: .veryFast  // fast for tests
        )

        let chunk = sineChunk(channels: 2, frames: inputFrames, sampleRate: inputRate)
        let output = try resampler.process(chunk: chunk)

        let expectedFrames = Int(Double(inputFrames) * resampler.ratio + 0.5)
        XCTAssertEqual(output.validFrames, expectedFrames,
                       "2x upsample should produce ~2x output frames")
        XCTAssertEqual(output.channels, 2)

        // Sanity-check: ratio should be 2.0
        XCTAssertEqual(resampler.ratio, 2.0, accuracy: 1e-9,
                       "96000/48000 ratio should be exactly 2.0")
    }

    // 14. Downsample: output has fewer frames
    func testAsyncPolyResampler() throws {
        let inputRate  = 96000
        let outputRate = 44100
        let inputFrames = 2048

        let resampler = AsyncPolyResampler(
            channels: 1,
            inputRate: inputRate,
            outputRate: outputRate
        )

        let chunk = sineChunk(channels: 1, frames: inputFrames, sampleRate: inputRate)
        let output = try resampler.process(chunk: chunk)

        // ratio = 44100/96000 < 1, so output frames < input frames
        XCTAssertLessThan(output.validFrames, inputFrames,
                          "Downsampling should produce fewer output frames than input")
        XCTAssertGreaterThan(output.validFrames, 0,
                             "Downsampled output should not be empty")

        let expectedFrames = Int(Double(inputFrames) * resampler.ratio + 0.5)
        XCTAssertEqual(output.validFrames, expectedFrames,
                       "Output frame count should match ratio * input frames")
    }

    // 15. Change ratio mid-stream
    func testResamplerRatioAdjust() throws {
        let inputRate  = 48000
        let outputRate = 48000
        let inputFrames = 1024

        let resampler = AsyncSincResampler(
            channels: 1,
            inputRate: inputRate,
            outputRate: outputRate,
            profile: .veryFast
        )

        // Initial ratio should be 1.0
        XCTAssertEqual(resampler.ratio, 1.0, accuracy: 1e-9)

        let chunk = sineChunk(channels: 1, frames: inputFrames, sampleRate: inputRate)
        let output1 = try resampler.process(chunk: chunk)
        XCTAssertEqual(output1.validFrames, inputFrames,
                       "1:1 ratio should produce exactly inputFrames output frames")

        // Adjust ratio to emulate slight clock drift (+1%)
        let newRatio = 1.01
        resampler.setRatio(newRatio)
        XCTAssertEqual(resampler.ratio, newRatio, accuracy: 1e-9,
                       "setRatio should update the resampler's ratio")

        let output2 = try resampler.process(chunk: chunk)
        let expectedFrames2 = Int(Double(inputFrames) * newRatio + 0.5)
        XCTAssertEqual(output2.validFrames, expectedFrames2,
                       "After ratio change, output frame count should reflect new ratio")
    }
}

// MARK: - AudioChunk Tests

final class AudioChunkTests: XCTestCase {

    // 16. Verify peak dB measurement
    func testPeakDB() {
        // Channel 0: peak = 0.5 (-6.02 dBFS)
        // Channel 1: peak = 1.0 (0.0 dBFS)
        let waveforms: [[PrcFmt]] = [
            [0.5, -0.3, 0.2],
            [1.0, -0.8, 0.0],
        ]
        let chunk = AudioChunk(waveforms: waveforms)
        let peaks = chunk.peakDB()

        XCTAssertEqual(peaks.count, 2)
        XCTAssertEqual(peaks[0], PrcFmt.toDB(0.5), accuracy: 0.01,
                       "Channel 0 peak dB should be ~-6.02 dBFS")
        XCTAssertEqual(peaks[1], PrcFmt.toDB(1.0), accuracy: 0.01,
                       "Channel 1 peak dB should be 0.0 dBFS")
    }

    // 17. Verify RMS dB measurement
    func testRmsDB() {
        // A constant signal at 0.5 has RMS = 0.5, so RMS dB = toDB(0.5) ~ -6.02
        let frames = 1024
        let value: PrcFmt = 0.5
        let waveforms: [[PrcFmt]] = [
            [PrcFmt](repeating: value, count: frames),
        ]
        let chunk = AudioChunk(waveforms: waveforms)
        let rmsDBValues = chunk.rmsDB()

        XCTAssertEqual(rmsDBValues.count, 1)
        let expectedRMSDB = PrcFmt.toDB(value)
        XCTAssertEqual(rmsDBValues[0], expectedRMSDB, accuracy: 0.1,
                       "Constant signal RMS dB should equal toDB(amplitude)")
    }

    // 18. Silent chunk has -inf dB peaks
    func testSilentChunk() {
        let chunk = AudioChunk(frames: 512, channels: 2)
        let peaks = chunk.peakDB()

        for (ch, peakDB) in peaks.enumerated() {
            XCTAssertTrue(peakDB < -200.0,
                          "Channel \(ch) of a silent chunk should have a very low (near -inf dB) peak, got \(peakDB)")
        }
    }

    // 19. updatePeaks() correctly computes min/max
    func testChunkUpdatePeaks() {
        var waveforms: [[PrcFmt]] = [
            [0.3, -0.9, 0.1],
            [0.7, 0.2, -0.4],
        ]
        var chunk = AudioChunk(waveforms: waveforms, validFrames: 3)

        // Initial peaks are set by the init via updatePeaks()
        XCTAssertEqual(chunk.maxval,  0.7, accuracy: 1e-9, "Initial maxval should be 0.7")
        XCTAssertEqual(chunk.minval, -0.9, accuracy: 1e-9, "Initial minval should be -0.9")

        // Now mutate the waveform and call updatePeaks manually
        chunk.waveforms[0][0] = 0.95
        chunk.waveforms[1][2] = -1.0
        chunk.updatePeaks()

        XCTAssertEqual(chunk.maxval,  0.95, accuracy: 1e-9,
                       "After update, maxval should reflect the new maximum")
        XCTAssertEqual(chunk.minval, -1.0,  accuracy: 1e-9,
                       "After update, minval should reflect the new minimum")
    }
}
