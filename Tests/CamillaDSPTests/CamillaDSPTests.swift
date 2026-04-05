// CamillaDSP-Swift Tests

import XCTest
@testable import CamillaDSPLib

final class CamillaDSPTests: XCTestCase {

    // MARK: - AudioChunk Tests

    func testAudioChunkCreation() {
        let chunk = AudioChunk(frames: 1024, channels: 2)
        XCTAssertEqual(chunk.frames, 1024)
        XCTAssertEqual(chunk.channels, 2)
        XCTAssertEqual(chunk.validFrames, 1024)
    }

    func testAudioChunkFromWaveforms() {
        let waveforms: [[PrcFmt]] = [
            [0.5, -0.5, 1.0, -1.0],
            [0.25, -0.25, 0.5, -0.5],
        ]
        let chunk = AudioChunk(waveforms: waveforms)
        XCTAssertEqual(chunk.channels, 2)
        XCTAssertEqual(chunk.frames, 4)
        XCTAssertEqual(chunk.maxval, 1.0)
        XCTAssertEqual(chunk.minval, -1.0)
    }

    // MARK: - Gain Filter Tests

    func testGainFilterDB() throws {
        var params = FilterParameters()
        params.gain = -6.0
        params.scale = .dB
        let config = FilterConfig(type: .gain, parameters: params)
        let filter = GainFilter(name: "test_gain", config: config)

        var waveform: [PrcFmt] = [1.0, 0.5, -0.5, -1.0]
        try filter.process(waveform: &waveform)

        // -6dB ~ 0.5012
        let expected = PrcFmt.fromDB(-6.0)
        XCTAssertEqual(waveform[0], expected, accuracy: 0.001)
        XCTAssertEqual(waveform[3], -expected, accuracy: 0.001)
    }

    func testGainFilterLinear() throws {
        var params = FilterParameters()
        params.gain = 0.5
        params.scale = .linear
        let config = FilterConfig(type: .gain, parameters: params)
        let filter = GainFilter(name: "test_gain", config: config)

        var waveform: [PrcFmt] = [1.0, 0.5, -0.5, -1.0]
        try filter.process(waveform: &waveform)

        XCTAssertEqual(waveform[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(waveform[1], 0.25, accuracy: 0.001)
    }

    func testGainFilterMute() throws {
        var params = FilterParameters()
        params.gain = 0.0
        params.mute = true
        let config = FilterConfig(type: .gain, parameters: params)
        let filter = GainFilter(name: "test_gain", config: config)

        var waveform: [PrcFmt] = [1.0, 0.5, -0.5, -1.0]
        try filter.process(waveform: &waveform)

        XCTAssertEqual(waveform[0], 0.0)
        XCTAssertEqual(waveform[3], 0.0)
    }

    func testGainFilterInverted() throws {
        var params = FilterParameters()
        params.gain = 0.0
        params.inverted = true
        let config = FilterConfig(type: .gain, parameters: params)
        let filter = GainFilter(name: "test_gain", config: config)

        var waveform: [PrcFmt] = [1.0, 0.5, -0.5, -1.0]
        try filter.process(waveform: &waveform)

        XCTAssertEqual(waveform[0], -1.0, accuracy: 0.001)
        XCTAssertEqual(waveform[3], 1.0, accuracy: 0.001)
    }

    // MARK: - Biquad Filter Tests

    func testBiquadLowpass() throws {
        var params = FilterParameters()
        params.subtype = BiquadType.lowpass.rawValue
        params.freq = 1000.0
        params.q = 0.707
        let config = FilterConfig(type: .biquad, parameters: params)
        let filter = try BiquadFilter(name: "test_lp", config: config, sampleRate: 48000)

        // Generate 100Hz sine (should pass) and 10kHz sine (should be attenuated)
        let frames = 4096
        var lowFreq = [PrcFmt](repeating: 0, count: frames)
        var highFreq = [PrcFmt](repeating: 0, count: frames)

        for i in 0..<frames {
            lowFreq[i] = sin(2.0 * .pi * 100.0 * Double(i) / 48000.0)
            highFreq[i] = sin(2.0 * .pi * 10000.0 * Double(i) / 48000.0)
        }

        try filter.process(waveform: &lowFreq)
        filter.reset()
        try filter.process(waveform: &highFreq)

        let lowPeak = DSPOps.peakAbsolute(Array(lowFreq[1024...]))
        let highPeak = DSPOps.peakAbsolute(Array(highFreq[1024...]))

        // Low frequency should pass through mostly unchanged
        XCTAssertGreaterThan(lowPeak, 0.9)
        // High frequency should be significantly attenuated
        XCTAssertLessThan(highPeak, 0.2)
    }

    func testBiquadHighpass() throws {
        var params = FilterParameters()
        params.subtype = BiquadType.highpass.rawValue
        params.freq = 5000.0
        params.q = 0.707
        let config = FilterConfig(type: .biquad, parameters: params)
        let filter = try BiquadFilter(name: "test_hp", config: config, sampleRate: 48000)

        let frames = 4096
        var lowFreq = [PrcFmt](repeating: 0, count: frames)
        var highFreq = [PrcFmt](repeating: 0, count: frames)

        for i in 0..<frames {
            lowFreq[i] = sin(2.0 * .pi * 100.0 * Double(i) / 48000.0)
            highFreq[i] = sin(2.0 * .pi * 15000.0 * Double(i) / 48000.0)
        }

        try filter.process(waveform: &lowFreq)
        filter.reset()
        try filter.process(waveform: &highFreq)

        let lowPeak = DSPOps.peakAbsolute(Array(lowFreq[1024...]))
        let highPeak = DSPOps.peakAbsolute(Array(highFreq[1024...]))

        XCTAssertLessThan(lowPeak, 0.05)
        XCTAssertGreaterThan(highPeak, 0.8)
    }

    // MARK: - BiquadCombo Tests

    func testButterworthLowpass() throws {
        var params = FilterParameters()
        params.subtype = BiquadComboType.butterworthLowpass.rawValue
        params.freq = 1000.0
        params.order = 4
        let config = FilterConfig(type: .biquadCombo, parameters: params)
        let filter = try BiquadComboFilter(name: "test_bw", config: config, sampleRate: 48000)

        var waveform = [PrcFmt](repeating: 0, count: 4096)
        for i in 0..<4096 {
            waveform[i] = sin(2.0 * .pi * 10000.0 * Double(i) / 48000.0)
        }

        try filter.process(waveform: &waveform)
        let peak = DSPOps.peakAbsolute(Array(waveform[2048...]))
        // 4th-order at 10x the cutoff should be heavily attenuated
        XCTAssertLessThan(peak, 0.01)
    }

    // MARK: - Delay Filter Tests

    func testDelaySamples() throws {
        var params = FilterParameters()
        params.delay = 10.0
        params.unit = .samples
        let config = FilterConfig(type: .delay, parameters: params)
        let filter = DelayFilter(name: "test_delay", config: config, sampleRate: 48000)

        var waveform = [PrcFmt](repeating: 0, count: 20)
        waveform[0] = 1.0 // impulse

        try filter.process(waveform: &waveform)

        // Impulse should appear at sample 10
        XCTAssertEqual(waveform[0], 0.0)
        XCTAssertEqual(waveform[10], 1.0)
    }

    // MARK: - DiffEq Filter Tests

    func testDiffEqPassthrough() throws {
        var params = FilterParameters()
        params.a = [1.0]
        params.b = [1.0]
        let config = FilterConfig(type: .diffEq, parameters: params)
        let filter = DiffEqFilter(name: "test_diffeq", config: config)

        var waveform: [PrcFmt] = [1.0, 0.5, -0.5, -1.0]
        let original = waveform
        try filter.process(waveform: &waveform)

        for i in 0..<waveform.count {
            XCTAssertEqual(waveform[i], original[i], accuracy: 1e-10)
        }
    }

    // MARK: - Limiter Tests

    func testHardLimiter() throws {
        var params = FilterParameters()
        params.clipLimit = -6.0
        params.softClip = false
        let config = FilterConfig(type: .limiter, parameters: params)
        let filter = LimiterFilter(name: "test_limiter", config: config)

        var waveform: [PrcFmt] = [1.0, 0.3, -0.3, -1.0]
        try filter.process(waveform: &waveform)

        let limit = PrcFmt.fromDB(-6.0) // ~0.501
        XCTAssertEqual(waveform[0], limit, accuracy: 0.001)
        XCTAssertEqual(waveform[1], 0.3, accuracy: 0.001) // below limit
        XCTAssertEqual(waveform[3], -limit, accuracy: 0.001)
    }

    func testSoftLimiter() throws {
        var params = FilterParameters()
        params.clipLimit = 0.0
        params.softClip = true
        let config = FilterConfig(type: .limiter, parameters: params)
        let filter = LimiterFilter(name: "test_soft", config: config)

        var waveform: [PrcFmt] = [2.0, 0.1, -0.1, -2.0]
        try filter.process(waveform: &waveform)

        // Cubic soft clip: clamp to ±1.5, then x - x^3/6.75. At |x|>=1.5, output = exactly 1.0
        XCTAssertLessThanOrEqual(waveform[0], 1.0)
        XCTAssertGreaterThan(waveform[0], 0.9)
        // Small input barely affected: cubic(0.1) ≈ 0.1 - 0.001/6.75 ≈ 0.0999
        XCTAssertEqual(waveform[1], 0.1 - 0.001 / 6.75, accuracy: 0.001)
    }

    // MARK: - Mixer Tests

    func testMixerStereoToMono() {
        let config = MixerConfig(
            channelsIn: 2, channelsOut: 1,
            mapping: [
                MixerMapping(dest: 0, sources: [
                    MixerSource(channel: 0, gain: -6.0),
                    MixerSource(channel: 1, gain: -6.0),
                ]),
            ]
        )
        let mixer = AudioMixer(name: "test_mixer", config: config)

        let input = AudioChunk(waveforms: [
            [1.0, 1.0, 1.0, 1.0],
            [1.0, 1.0, 1.0, 1.0],
        ])

        let output = mixer.process(chunk: input)
        XCTAssertEqual(output.channels, 1)
        XCTAssertEqual(output.frames, 4)

        // Each channel at -6dB, summed
        let expected = PrcFmt.fromDB(-6.0) * 2.0
        XCTAssertEqual(output.waveforms[0][0], expected, accuracy: 0.01)
    }

    func testMixerMonoToStereo() {
        let config = MixerConfig(
            channelsIn: 1, channelsOut: 2,
            mapping: [
                MixerMapping(dest: 0, sources: [
                    MixerSource(channel: 0, gain: 0.0),
                ]),
                MixerMapping(dest: 1, sources: [
                    MixerSource(channel: 0, gain: 0.0),
                ]),
            ]
        )
        let mixer = AudioMixer(name: "test_mixer", config: config)
        let input = AudioChunk(waveforms: [[0.5, -0.5, 0.5, -0.5]])
        let output = mixer.process(chunk: input)

        XCTAssertEqual(output.channels, 2)
        XCTAssertEqual(output.waveforms[0][0], output.waveforms[1][0])
    }

    // MARK: - Configuration Tests

    func testConfigParsing() throws {
        let yaml = """
        devices:
          samplerate: 48000
          chunksize: 1024
          capture:
            type: CoreAudio
            channels: 2
          playback:
            type: CoreAudio
            channels: 2
        filters:
          lowpass:
            type: Biquad
            parameters:
              type: Lowpass
              freq: 1000.0
              q: 0.707
        pipeline:
          - type: Filter
            channel: 0
            names:
              - lowpass
        """

        let config = try ConfigLoader.parse(yaml: yaml)
        XCTAssertEqual(config.devices.samplerate, 48000)
        XCTAssertEqual(config.devices.chunksize, 1024)
        XCTAssertEqual(config.devices.capture.channels, 2)
        XCTAssertNotNil(config.filters?["lowpass"])
        XCTAssertEqual(config.pipeline?.count, 1)
    }

    func testConfigValidation() {
        var config = CamillaDSPConfig(devices: DevicesConfig(
            samplerate: 0,
            chunksize: 1024,
            capture: CaptureDeviceConfig(type: .coreAudio, channels: 2),
            playback: PlaybackDeviceConfig(type: .coreAudio, channels: 2)
        ))

        XCTAssertThrowsError(try ConfigLoader.validate(config))

        config.devices.samplerate = 48000
        config.devices.capture.channels = 0
        XCTAssertThrowsError(try ConfigLoader.validate(config))
    }

    // MARK: - ProcessingParameters Tests

    func testProcessingParameters() {
        let params = ProcessingParameters()

        params.setTargetVolume(.main, -10.0)
        XCTAssertEqual(params.getTargetVolume(.main), -10.0)

        params.adjustVolume(.main, by: -5.0)
        XCTAssertEqual(params.getTargetVolume(.main), -15.0)

        params.setMute(.main, true)
        XCTAssertTrue(params.isMuted(.main))

        params.toggleMute(.main)
        XCTAssertFalse(params.isMuted(.main))
    }

    // MARK: - DSPOps Tests

    func testDSPOpsPeakAbsolute() {
        let buffer: [PrcFmt] = [0.5, -0.8, 0.3, -0.1]
        XCTAssertEqual(DSPOps.peakAbsolute(buffer), 0.8, accuracy: 0.001)
    }

    func testDSPOpsRms() {
        // RMS of constant signal = that value
        let buffer: [PrcFmt] = [0.5, 0.5, 0.5, 0.5]
        XCTAssertEqual(DSPOps.rms(buffer), 0.5, accuracy: 0.001)
    }

    // MARK: - Convolution Tests

    func testConvolutionIdentity() throws {
        // Convolve with identity (impulse at sample 0) should pass through
        var params = FilterParameters()
        params.subtype = "Values"
        params.values = [1.0]
        let config = FilterConfig(type: .conv, parameters: params)
        let filter = try ConvolutionFilter(name: "test_conv", config: config, chunkSize: 64, sampleRate: 48000)

        // Use larger chunk for better FFT behavior
        var waveform = [PrcFmt](repeating: 0, count: 64)
        waveform[0] = 1.0
        try filter.process(waveform: &waveform)

        // With identity IR, energy should be concentrated at sample 0
        let peak = DSPOps.peakAbsolute(waveform)
        XCTAssertGreaterThan(peak, 0.5, "Peak should be significant after identity convolution")
    }

    // MARK: - Sample Format Tests

    func testSampleFormatBytesPerSample() {
        XCTAssertEqual(SampleFormat.s16.bytesPerSample, 2)
        XCTAssertEqual(SampleFormat.s24_3.bytesPerSample, 3)
        XCTAssertEqual(SampleFormat.s32.bytesPerSample, 4)
        XCTAssertEqual(SampleFormat.float32.bytesPerSample, 4)
        XCTAssertEqual(SampleFormat.float64.bytesPerSample, 8)
    }
}
