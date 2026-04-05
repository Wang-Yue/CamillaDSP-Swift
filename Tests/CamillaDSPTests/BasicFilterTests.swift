// BasicFilterTests.swift - Comprehensive filter tests matching CamillaDSP Rust test suite

import XCTest
@testable import CamillaDSPLib

final class BasicFilterTests: XCTestCase {

    // MARK: - Helpers

    private func makeFilterConfig(type: FilterType, configure: (inout FilterParameters) -> Void) -> FilterConfig {
        var params = FilterParameters()
        configure(&params)
        return FilterConfig(type: type, parameters: params)
    }

    // MARK: - Gain Tests

    /// 0 dB + invert: [-0.5, 0.0, 0.5] → [0.5, 0.0, -0.5]
    func testGainInvert() throws {
        let config = makeFilterConfig(type: .gain) {
            $0.gain = 0.0
            $0.scale = .dB
            $0.inverted = true
        }
        let filter = GainFilter(name: "gain_invert", config: config)

        var waveform: [PrcFmt] = [-0.5, 0.0, 0.5]
        try filter.process(waveform: &waveform)

        XCTAssertEqual(waveform[0],  0.5, accuracy: 1e-10, "Inverted -0.5 should be 0.5")
        XCTAssertEqual(waveform[1],  0.0, accuracy: 1e-10, "Inverted 0.0 should be 0.0")
        XCTAssertEqual(waveform[2], -0.5, accuracy: 1e-10, "Inverted 0.5 should be -0.5")
    }

    /// +20 dB (10x amplitude): [-0.5, 0.0, 0.5] → [-5.0, 0.0, 5.0]
    func testGainAmplify() throws {
        let config = makeFilterConfig(type: .gain) {
            $0.gain = 20.0
            $0.scale = .dB
        }
        let filter = GainFilter(name: "gain_amplify", config: config)

        var waveform: [PrcFmt] = [-0.5, 0.0, 0.5]
        try filter.process(waveform: &waveform)

        XCTAssertEqual(waveform[0], -5.0, accuracy: 1e-6)
        XCTAssertEqual(waveform[1],  0.0, accuracy: 1e-10)
        XCTAssertEqual(waveform[2],  5.0, accuracy: 1e-6)
    }

    /// Muted filter: all samples become 0
    func testGainMute() throws {
        let config = makeFilterConfig(type: .gain) {
            $0.gain = 0.0
            $0.mute = true
        }
        let filter = GainFilter(name: "gain_mute", config: config)

        var waveform: [PrcFmt] = [-0.5, 0.0, 0.5, 1.0, -1.0]
        try filter.process(waveform: &waveform)

        for (i, sample) in waveform.enumerated() {
            XCTAssertEqual(sample, 0.0, "Sample \(i) should be zero after mute")
        }
    }

    /// Linear scale 0.5: [1.0] → [0.5]
    func testGainLinearScale() throws {
        let config = makeFilterConfig(type: .gain) {
            $0.gain = 0.5
            $0.scale = .linear
        }
        let filter = GainFilter(name: "gain_linear", config: config)

        var waveform: [PrcFmt] = [1.0]
        try filter.process(waveform: &waveform)

        XCTAssertEqual(waveform[0], 0.5, accuracy: 1e-10)
    }

    // MARK: - Delay Tests (matching Rust CamillaDSP basicfilters.rs tests exactly)

    private func compareWaveforms(_ left: [PrcFmt], _ right: [PrcFmt], maxdiff: PrcFmt) -> Bool {
        for (valL, valR) in zip(left, right) {
            if abs(valL - valR) >= maxdiff {
                return false
            }
        }
        return true
    }

    /// Rust test: delay_small - 3-sample integer delay
    func testDelaySmall() throws {
        let filter = DelayFilter(name: "test", sampleRate: 44100, delaySamples: 3.0, subsample: false)
        var waveform: [PrcFmt] = [0.0, -0.5, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        let expected: [PrcFmt] = [0.0, 0.0, 0.0, 0.0, -0.5, 1.0, 0.0, 0.0]
        try filter.process(waveform: &waveform)
        XCTAssertEqual(waveform, expected)
    }

    /// Rust test: delay_supersmall - 0.1 samples rounds to 0, passthrough
    func testDelaySuperSmall() throws {
        let filter = DelayFilter(name: "test", sampleRate: 44100, delaySamples: 0.1, subsample: false)
        var waveform: [PrcFmt] = [0.0, -0.5, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        let expected = waveform
        try filter.process(waveform: &waveform)
        XCTAssertEqual(waveform, expected)
    }

    /// Rust test: delay_large - 9-sample delay spanning two chunks of 8
    func testDelayLarge() throws {
        let filter = DelayFilter(name: "test", sampleRate: 44100, delaySamples: 9.0, subsample: false)
        var waveform1: [PrcFmt] = [0.0, -0.5, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        var waveform2: [PrcFmt] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        let expectedDelayed: [PrcFmt] = [0.0, 0.0, -0.5, 1.0, 0.0, 0.0, 0.0, 0.0]
        try filter.process(waveform: &waveform1)
        try filter.process(waveform: &waveform2)
        XCTAssertEqual(waveform1, [PrcFmt](repeating: 0.0, count: 8))
        XCTAssertEqual(waveform2, expectedDelayed)
    }

    /// Rust test: delay_fraction - 1.7-sample delay with subsample=true (2nd order Thiran allpass)
    func testDelayFraction() throws {
        let filter = DelayFilter(name: "test", sampleRate: 44100, delaySamples: 1.7, subsample: true)
        var waveform: [PrcFmt] = [0.0, -0.5, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        let expected: [PrcFmt] = [
            0.0,
            0.01051051051051051,
            -0.13446780113446782,
            -0.2476751025299573,
            1.0522122611990257,
            -0.23903133046978262,
            0.07523664949897024,
            -0.021743938066703532,
            0.006413537427714274,
            -0.001882310318672015,
        ]
        try filter.process(waveform: &waveform)
        XCTAssertTrue(compareWaveforms(waveform, expected, maxdiff: 1.0e-6),
                      "Fractional delay output does not match Rust expected values. Got: \(waveform)")
    }

    // MARK: - Volume Tests

    /// Helper to create a VolumeFilter with Rust-style direct init
    private func makeVolumeFilter(
        rampTimeMs: Double = 400.0,
        limit: Double = 50.0,
        currentVolume: Double = 0.0,
        mute: Bool = false,
        chunkSize: Int = 4,
        sampleRate: Int = 44100,
        fader: Fader = .main
    ) -> (VolumeFilter, ProcessingParameters) {
        let params = ProcessingParameters()
        params.setTargetVolume(fader, currentVolume)
        params.setMute(fader, mute)
        let filter = VolumeFilter(
            name: "test_volume",
            rampTimeMs: rampTimeMs,
            limit: limit,
            currentVolume: currentVolume,
            mute: mute,
            chunkSize: chunkSize,
            sampleRate: sampleRate,
            processingParameters: params,
            fader: fader
        )
        return (filter, params)
    }

    /// Volume at 0 dB: signal passes through unchanged
    func testVolumeUnityGain() throws {
        let (filter, _) = makeVolumeFilter(rampTimeMs: 0.0, currentVolume: 0.0)
        var waveform: [PrcFmt] = [1.0, -0.5, 0.25, 0.0]
        let original = waveform
        try filter.process(waveform: &waveform)

        for i in 0..<waveform.count {
            XCTAssertEqual(waveform[i], original[i], accuracy: 1e-10,
                           "0 dB volume should pass through unchanged at sample \(i)")
        }
    }

    /// Volume at -20 dB (gain=0.1): signal attenuated by 10x
    func testVolumeAttenuation() throws {
        let (filter, _) = makeVolumeFilter(rampTimeMs: 0.0, currentVolume: -20.0)
        var waveform: [PrcFmt] = [1.0, -1.0, 0.5, -0.5]
        try filter.process(waveform: &waveform)

        let gain = PrcFmt.fromDB(-20.0)  // 0.1
        XCTAssertEqual(waveform[0], 1.0 * gain, accuracy: 1e-10)
        XCTAssertEqual(waveform[1], -1.0 * gain, accuracy: 1e-10)
        XCTAssertEqual(waveform[2], 0.5 * gain, accuracy: 1e-10)
        XCTAssertEqual(waveform[3], -0.5 * gain, accuracy: 1e-10)
    }

    /// Mute: signal zeroed through normal gain path (targetLinearGain=0, no bypass)
    func testVolumeMuteRampsToZero() throws {
        // With ramptime=0, mute should immediately apply gain of 0.0
        let (filter, _) = makeVolumeFilter(rampTimeMs: 0.0, currentVolume: 0.0, mute: true)
        var waveform: [PrcFmt] = [1.0, 0.5, -0.5, -1.0]
        try filter.process(waveform: &waveform)

        for i in 0..<waveform.count {
            XCTAssertEqual(waveform[i], 0.0, accuracy: 1e-10,
                           "Muted volume should zero out sample \(i)")
        }
    }

    /// Ramped volume change: over multiple chunks, gain ramps from initial to target
    func testVolumeRamp() throws {
        let chunkSize = 4
        let sampleRate = 44100
        // ramp_time_ms chosen so ramptimeInChunks = 2
        let rampTimeMs = 1000.0 * Double(chunkSize) / Double(sampleRate) * 2.0

        let (filter, params) = makeVolumeFilter(
            rampTimeMs: rampTimeMs,
            currentVolume: 0.0,
            chunkSize: chunkSize,
            sampleRate: sampleRate
        )

        // Process one chunk at unity (0 dB) to establish baseline
        var chunk0: [PrcFmt] = [1.0, 1.0, 1.0, 1.0]
        try filter.process(waveform: &chunk0)
        for i in 0..<chunkSize {
            XCTAssertEqual(chunk0[i], 1.0, accuracy: 1e-10, "Initial chunk should be unity")
        }

        // Now change target to -20 dB
        params.setTargetVolume(.main, -20.0)

        // Process first ramp chunk (rampStep=1 of 2)
        var chunk1: [PrcFmt] = [1.0, 1.0, 1.0, 1.0]
        try filter.process(waveform: &chunk1)

        // All samples should be between fromDB(0) and fromDB(-20)
        let gain0dB = PrcFmt.fromDB(0.0)
        let gainM20dB = PrcFmt.fromDB(-20.0)
        for i in 0..<chunkSize {
            XCTAssertLessThanOrEqual(chunk1[i], gain0dB + 1e-6,
                                     "Ramp chunk 1 sample \(i) should be <= 1.0")
            XCTAssertGreaterThanOrEqual(chunk1[i], gainM20dB - 1e-6,
                                        "Ramp chunk 1 sample \(i) should be >= gainM20dB")
        }
        // Ramp should be decreasing
        XCTAssertGreaterThan(chunk1[0], chunk1[chunkSize - 1],
                             "Ramp should be decreasing within chunk")

        // Process second ramp chunk (rampStep=2 of 2, last step)
        var chunk2: [PrcFmt] = [1.0, 1.0, 1.0, 1.0]
        try filter.process(waveform: &chunk2)

        // Rust chunk-granular ramp: last sample of last chunk is NOT exactly at target.
        // With 2 chunks of 4 samples ramping 0 -> -20 dB:
        // ramprange = -10, stepsize = -2.5
        // step 2, sample 3: 0 + (-10)*(2-1) + 3*(-2.5) = -17.5 dB -> 10^(-17.5/20) ~ 0.1334
        // Ramp should still be decreasing and closer to target than chunk1
        XCTAssertLessThan(chunk2[chunkSize - 1], chunk1[chunkSize - 1],
                          "Second ramp chunk should be closer to target than first")
        XCTAssertGreaterThan(chunk2[chunkSize - 1], gainM20dB - 1e-6,
                             "Last ramp sample should not overshoot target")

        // Process a third chunk (ramp complete). Rust uses targetLinearGain directly.
        var chunk3: [PrcFmt] = [1.0, 1.0, 1.0, 1.0]
        try filter.process(waveform: &chunk3)

        for i in 0..<chunkSize {
            XCTAssertEqual(chunk3[i], gainM20dB, accuracy: 1e-6,
                           "Post-ramp chunk should use targetLinearGain exactly")
        }
    }

    /// Volume change detection uses 0.01 dB threshold (not exact equality)
    func testVolumeChangeThreshold() throws {
        let (filter, params) = makeVolumeFilter(rampTimeMs: 0.0, currentVolume: 0.0)

        // Process at 0 dB
        var wave1: [PrcFmt] = [1.0, 1.0, 1.0, 1.0]
        try filter.process(waveform: &wave1)

        // Change by only 0.005 dB (below 0.01 threshold) - should NOT trigger a change
        params.setTargetVolume(.main, 0.005)
        var wave2: [PrcFmt] = [1.0, 1.0, 1.0, 1.0]
        try filter.process(waveform: &wave2)

        // Should still be at old gain (0 dB = 1.0)
        for i in 0..<wave2.count {
            XCTAssertEqual(wave2[i], 1.0, accuracy: 1e-10,
                           "Change below 0.01 dB threshold should not trigger update")
        }

        // Change by 0.02 dB (above threshold) - should trigger
        params.setTargetVolume(.main, 0.02)
        var wave3: [PrcFmt] = [1.0, 1.0, 1.0, 1.0]
        try filter.process(waveform: &wave3)

        let expectedGain = PrcFmt.fromDB(0.02)
        for i in 0..<wave3.count {
            XCTAssertEqual(wave3[i], expectedGain, accuracy: 1e-6,
                           "Change above 0.01 dB threshold should trigger update")
        }
    }

    /// Volume limit: target volume is clamped to the limit
    func testVolumeLimit() throws {
        let (filter, params) = makeVolumeFilter(rampTimeMs: 0.0, limit: 10.0, currentVolume: 0.0)

        // Set target above limit
        params.setTargetVolume(.main, 20.0)
        var waveform: [PrcFmt] = [1.0, 1.0, 1.0, 1.0]
        try filter.process(waveform: &waveform)

        // Should be clamped to 10 dB
        let expectedGain = PrcFmt.fromDB(10.0)
        for i in 0..<waveform.count {
            XCTAssertEqual(waveform[i], expectedGain, accuracy: 1e-6,
                           "Volume should be clamped to limit of 10 dB")
        }
    }

    /// updateParameters clamps currentVolume to new volumeLimit
    func testVolumeUpdateParametersClampsToLimit() throws {
        let (filter, params) = makeVolumeFilter(rampTimeMs: 0.0, limit: 50.0, currentVolume: 20.0)

        // Process to establish currentVolume = 20 dB
        var wave1: [PrcFmt] = [1.0, 1.0, 1.0, 1.0]
        try filter.process(waveform: &wave1)

        // Now lower the limit to 10 dB via updateParameters
        var newParams = FilterParameters()
        newParams.rampTime = 0.0
        newParams.limit = 10.0
        let newConfig = FilterConfig(type: .volume, parameters: newParams)
        filter.updateParameters(newConfig)

        // currentVolume should now be clamped to 10.0
        params.setTargetVolume(.main, 10.0)
        var wave2: [PrcFmt] = [1.0, 1.0, 1.0, 1.0]
        try filter.process(waveform: &wave2)

        let expectedGain = PrcFmt.fromDB(10.0)
        for i in 0..<wave2.count {
            XCTAssertEqual(wave2[i], expectedGain, accuracy: 1e-6,
                           "After limit clamp, gain should be at new limit")
        }
    }

    /// Compressor with clipLimit=nil (disabled): no clipping applied
    func testCompressorDisabledClipLimit() throws {
        // This test verifies that clipLimit=nil (Rust None) does NOT zero audio
        // Bug: old Swift code with clipLimit=0 would zero all samples via max(-0, min(0, x))
        var cparams = ProcessorParameters()
        cparams.channels = 1
        cparams.processChannels = [0]
        cparams.monitorChannels = [0]
        cparams.attack = 0.001
        cparams.release = 0.001
        cparams.threshold = -100.0   // very low so compression always engages
        cparams.factor = 1.0         // factor 1:1 = no compression (gain = 0 dB)
        cparams.makeupGain = 0.0
        cparams.clipLimit = nil       // disabled (Rust None)
        cparams.softClip = false
        let config = ProcessorConfig(type: .compressor, parameters: cparams)
        let proc = CompressorProcessor(name: "no_clip", config: config, sampleRate: 48000)

        let frames = 4800
        var chunk = AudioChunk(
            waveforms: [[PrcFmt](repeating: 0.5, count: frames)],
            validFrames: frames
        )
        try proc.process(chunk: &chunk)

        // With ratio=1 and no clip limit, output should approximate input
        let tail = Array(chunk.waveforms[0][(frames * 3 / 4)...])
        let peak = DSPOps.peakAbsolute(tail)
        XCTAssertGreaterThan(peak, 0.1,
                             "With clipLimit=nil, audio should NOT be zeroed")
    }

    // MARK: - DiffEq Tests

    /// Known impulse response matching Rust check_result test exactly.
    /// a=[1, -0.1462978543780541, 0.005350765548905586],
    /// b=[0.21476322779271284, 0.4295264555854257, 0.21476322779271284]
    /// Expected first 5 outputs ≈ [0.215, 0.461, 0.281, 0.039, 0.004] (tolerance 1e-3)
    func testDiffEqImpulseResponse() throws {
        let config = makeFilterConfig(type: .diffEq) {
            $0.a = [1.0, -0.1462978543780541, 0.005350765548905586]
            $0.b = [0.21476322779271284, 0.4295264555854257, 0.21476322779271284]
        }
        let filter = DiffEqFilter(name: "diffeq_ir", config: config)

        // Impulse: 1 followed by zeros
        var waveform: [PrcFmt] = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        try filter.process(waveform: &waveform)

        let expected: [PrcFmt] = [0.215, 0.461, 0.281, 0.039, 0.004]
        XCTAssertEqual(waveform[0], expected[0], accuracy: 1e-3, "IR[0]")
        XCTAssertEqual(waveform[1], expected[1], accuracy: 1e-3, "IR[1]")
        XCTAssertEqual(waveform[2], expected[2], accuracy: 1e-3, "IR[2]")
        XCTAssertEqual(waveform[3], expected[3], accuracy: 1e-3, "IR[3]")
        XCTAssertEqual(waveform[4], expected[4], accuracy: 1e-3, "IR[4]")
    }

    /// DiffEq with biquad coefficients should match BiquadFilter output exactly
    func testDiffEqMatchesBiquad() throws {
        // Lowpass biquad at 1000 Hz, Q=0.707, fs=48000
        let freq: PrcFmt = 1000.0
        let q: PrcFmt = 0.707
        let fs: PrcFmt = 48000.0
        let w0 = 2.0 * .pi * freq / fs
        let alpha = sin(w0) / (2.0 * q)
        let cosw0 = cos(w0)
        let a0 = 1.0 + alpha

        // Normalized coefficients (a0 = 1)
        let b0 = ((1.0 - cosw0) / 2.0) / a0
        let b1 = (1.0 - cosw0) / a0
        let b2 = ((1.0 - cosw0) / 2.0) / a0
        let a1n = (-2.0 * cosw0) / a0
        let a2n = (1.0 - alpha) / a0

        // Configure DiffEq with same coefficients
        // DiffEq convention: y[n] = sum(b*x) - sum(a[k>=1]*y), a[0]=1
        let diffEqConfig = makeFilterConfig(type: .diffEq) {
            $0.a = [1.0, a1n, a2n]
            $0.b = [b0, b1, b2]
        }
        let diffEqFilter = DiffEqFilter(name: "diffeq_biquad", config: diffEqConfig)

        // Configure Biquad directly with same coefficients (Free type)
        let biquadConfig = makeFilterConfig(type: .biquad) {
            $0.subtype = BiquadType.free.rawValue
            $0.b0 = b0
            $0.b1 = b1
            $0.b2 = b2
            $0.a1 = a1n
            $0.a2 = a2n
        }
        let biquadFilter = try BiquadFilter(name: "biquad_free", config: biquadConfig, sampleRate: 48000)

        // Use the same test signal for both filters
        let testSignal: [PrcFmt] = [1.0, 0.5, -0.3, 0.8, -0.6, 0.1, -0.9, 0.4,
                                     0.2, -0.7, 0.3, -0.1, 0.6, -0.4, 0.0, 0.9]

        var diffEqOutput = testSignal
        var biquadOutput = testSignal

        try diffEqFilter.process(waveform: &diffEqOutput)
        try biquadFilter.process(waveform: &biquadOutput)

        for i in 0..<testSignal.count {
            XCTAssertEqual(diffEqOutput[i], biquadOutput[i], accuracy: 1e-10,
                           "DiffEq and Biquad should produce identical output at sample \(i)")
        }
    }

    /// DiffEq passthrough: a=[1], b=[1] → identity
    func testDiffEqPassthrough() throws {
        let config = makeFilterConfig(type: .diffEq) {
            $0.a = [1.0]
            $0.b = [1.0]
        }
        let filter = DiffEqFilter(name: "diffeq_pass", config: config)

        var waveform: [PrcFmt] = [1.0, -0.5, 0.3, 0.7, -0.9, 0.2]
        let original = waveform
        try filter.process(waveform: &waveform)

        for i in 0..<waveform.count {
            XCTAssertEqual(waveform[i], original[i], accuracy: 1e-10,
                           "Passthrough DiffEq should not alter sample \(i)")
        }
    }

    // MARK: - Dither Tests (matching Rust CamillaDSP test suite)

    /// Helper: check if two values are close within maxdiff
    private func isClose(_ left: PrcFmt, _ right: PrcFmt, maxdiff: PrcFmt) -> Bool {
        return abs(left - right) < maxdiff
    }

    /// test_quantize: None dither still quantizes to N bits (does NOT skip processing)
    func testDitherQuantize() throws {
        var waveform: [PrcFmt] = [-1.0, -0.5, -1.0 / 3.0, 0.0, 1.0 / 3.0, 0.5, 1.0]
        let waveform2 = waveform
        let config = makeFilterConfig(type: .dither) {
            $0.subtype = DitherType.none.rawValue
            $0.bits = 8
        }
        let filter = DitherFilter(name: "test", config: config)
        try filter.process(waveform: &waveform)
        // Output should be close to input (within 1 LSB = 1/128)
        XCTAssertTrue(compareWaveforms(waveform, waveform2, maxdiff: 1.0 / 128.0),
                      "Quantized output should be within 1 LSB of input")
        // The quantized value at index 2 should be exactly representable at 8 bits
        XCTAssertTrue(isClose((128.0 * waveform[2]).rounded(.toNearestOrAwayFromZero),
                              128.0 * waveform[2], maxdiff: 1e-9),
                      "Output at index 2 should be exactly quantized to 8-bit grid")
    }

    /// test_flat: Flat TPDF dither at 8 bits
    func testDitherFlat() throws {
        var waveform: [PrcFmt] = [-1.0, -0.5, -1.0 / 3.0, 0.0, 1.0 / 3.0, 0.5, 1.0]
        let waveform2 = waveform
        let config = makeFilterConfig(type: .dither) {
            $0.subtype = DitherType.flat.rawValue
            $0.bits = 8
            $0.amplitude = 2.0
        }
        let filter = DitherFilter(name: "test", config: config)
        try filter.process(waveform: &waveform)
        // Output should be close to input (within 1/64 = ~2 LSB at 8 bits)
        XCTAssertTrue(compareWaveforms(waveform, waveform2, maxdiff: 1.0 / 64.0),
                      "Flat dithered output should be within 2 LSB of input")
        // Output should be exactly quantized to 8-bit grid
        XCTAssertTrue(isClose((128.0 * waveform[2]).rounded(.toNearestOrAwayFromZero),
                              128.0 * waveform[2], maxdiff: 1e-9),
                      "Output at index 2 should be exactly quantized to 8-bit grid")
    }

    /// test_high_pass: Highpass dither (violet noise) at 8 bits
    func testDitherHighPass() throws {
        var waveform: [PrcFmt] = [-1.0, -0.5, -1.0 / 3.0, 0.0, 1.0 / 3.0, 0.5, 1.0]
        let waveform2 = waveform
        let config = makeFilterConfig(type: .dither) {
            $0.subtype = DitherType.highpass.rawValue
            $0.bits = 8
        }
        let filter = DitherFilter(name: "test", config: config)
        try filter.process(waveform: &waveform)
        // Output should be close to input (within 1/32 = ~4 LSB at 8 bits)
        XCTAssertTrue(compareWaveforms(waveform, waveform2, maxdiff: 1.0 / 32.0),
                      "Highpass dithered output should be within 4 LSB of input")
        // Output should be exactly quantized to 8-bit grid
        XCTAssertTrue(isClose((128.0 * waveform[2]).rounded(.toNearestOrAwayFromZero),
                              128.0 * waveform[2], maxdiff: 1e-9),
                      "Output at index 2 should be exactly quantized to 8-bit grid")
    }

    /// test_lip: Lipshitz441 noise-shaped dither at 8 bits
    func testDitherLipshitz() throws {
        var waveform: [PrcFmt] = [-1.0, -0.5, -1.0 / 3.0, 0.0, 1.0 / 3.0, 0.5, 1.0]
        let waveform2 = waveform
        let config = makeFilterConfig(type: .dither) {
            $0.subtype = DitherType.lipshitz441.rawValue
            $0.bits = 8
        }
        let filter = DitherFilter(name: "test", config: config)
        try filter.process(waveform: &waveform)
        // Noise shaping can have larger per-sample deviation; allow 1/16
        XCTAssertTrue(compareWaveforms(waveform, waveform2, maxdiff: 1.0 / 16.0),
                      "Lipshitz dithered output should be within ~8 LSB of input")
        // Output should be exactly quantized to 8-bit grid
        XCTAssertTrue(isClose((128.0 * waveform[2]).rounded(.toNearestOrAwayFromZero),
                              128.0 * waveform[2], maxdiff: 1e-9),
                      "Output at index 2 should be exactly quantized to 8-bit grid")
    }

    // MARK: - Limiter Tests

    /// Hard clip at 0 dB: values above 1.0 clamped to 1.0, below -1.0 clamped to -1.0
    func testHardClip() throws {
        let config = makeFilterConfig(type: .limiter) {
            $0.clipLimit = 0.0   // 0 dB → linear 1.0
            $0.softClip = false
        }
        let filter = LimiterFilter(name: "limiter_hard", config: config)

        var waveform: [PrcFmt] = [0.5, 1.0, 1.5, 2.0, -0.5, -1.0, -1.5, -2.0]
        try filter.process(waveform: &waveform)

        // Values within range pass through
        XCTAssertEqual(waveform[0],  0.5,  accuracy: 1e-10)
        XCTAssertEqual(waveform[1],  1.0,  accuracy: 1e-10)

        // Values above threshold are clamped to 1.0
        XCTAssertEqual(waveform[2],  1.0,  accuracy: 1e-10, "1.5 should be clamped to 1.0")
        XCTAssertEqual(waveform[3],  1.0,  accuracy: 1e-10, "2.0 should be clamped to 1.0")

        // Negative values within range
        XCTAssertEqual(waveform[4], -0.5,  accuracy: 1e-10)
        XCTAssertEqual(waveform[5], -1.0,  accuracy: 1e-10)

        // Values below -threshold are clamped to -1.0
        XCTAssertEqual(waveform[6], -1.0,  accuracy: 1e-10, "-1.5 should be clamped to -1.0")
        XCTAssertEqual(waveform[7], -1.0,  accuracy: 1e-10, "-2.0 should be clamped to -1.0")
    }

    /// Soft clip at 0 dB: large values compressed via tanh, never exceeds limit
    func testSoftClip() throws {
        let config = makeFilterConfig(type: .limiter) {
            $0.clipLimit = 0.0   // 0 dB → linear 1.0
            $0.softClip = true
        }
        let filter = LimiterFilter(name: "limiter_soft", config: config)

        // Cubic soft clip: clamp(x/limit, -1.5, 1.5), then x - x^3/6.75
        func cubicClip(_ x: Double) -> Double {
            let s = max(-1.5, min(1.5, x))
            return s - s * s * s / 6.75
        }

        var waveform: [PrcFmt] = [0.5, 1.0, 1.5, 2.0, -0.5, -1.0, -1.5, -5.0]
        try filter.process(waveform: &waveform)

        for (i, input) in [0.5, 1.0, 1.5, 2.0, -0.5, -1.0, -1.5, -5.0].enumerated() {
            XCTAssertEqual(waveform[i], cubicClip(input), accuracy: 1e-10,
                           "Soft clip[\(i)] input=\(input)")
        }

        // Cubic clips to exactly ±1.0 at |x| >= 1.5
        for (i, sample) in waveform.enumerated() {
            XCTAssertLessThanOrEqual(abs(sample), 1.0, "Soft clip[\(i)] should be <= 1.0")
        }
    }

    /// Values below threshold pass through unmodified with hard clip
    func testLimiterBelowThreshold() throws {
        // Threshold at -6 dB ≈ 0.5012
        let config = makeFilterConfig(type: .limiter) {
            $0.clipLimit = -6.0
            $0.softClip = false
        }
        let filter = LimiterFilter(name: "limiter_below", config: config)

        let threshold = PrcFmt.fromDB(-6.0)
        // Values well below threshold (use ±0.1 which is << 0.5012)
        var waveform: [PrcFmt] = [0.1, 0.2, -0.1, -0.2, 0.0, 0.3]
        let original = waveform
        try filter.process(waveform: &waveform)

        for i in 0..<waveform.count {
            XCTAssertLessThan(abs(original[i]), threshold,
                              "Precondition: sample \(i) must be below threshold")
            XCTAssertEqual(waveform[i], original[i], accuracy: 1e-10,
                           "Sample \(i) below threshold should pass unchanged")
        }
    }
}
