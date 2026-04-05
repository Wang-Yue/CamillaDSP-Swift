// ConfigAndPipelineTests.swift
// Tests for configuration parsing, validation, pipeline execution, and processing parameters.

import XCTest
@testable import CamillaDSPLib

// MARK: - Helpers

private func makeDevicesYAML(
    samplerate: Int = 44100,
    chunksize: Int = 1024,
    captureChannels: Int = 2,
    playbackChannels: Int = 2
) -> String {
    """
    devices:
      samplerate: \(samplerate)
      chunksize: \(chunksize)
      capture:
        type: RawFile
        channels: \(captureChannels)
        format: S16
      playback:
        type: RawFile
        channels: \(playbackChannels)
        format: S16
    """
}

// MARK: - Config Parsing Tests

final class ConfigParsingTests: XCTestCase {

    // MARK: 1. testMinimalConfig

    func testMinimalConfig() throws {
        let yaml = makeDevicesYAML()
        let config = try ConfigLoader.parse(yaml: yaml)

        XCTAssertEqual(config.devices.samplerate, 44100)
        XCTAssertEqual(config.devices.chunksize, 1024)
        XCTAssertEqual(config.devices.capture.channels, 2)
        XCTAssertEqual(config.devices.playback.channels, 2)
        XCTAssertNil(config.filters)
        XCTAssertNil(config.mixers)
        XCTAssertNil(config.processors)
        XCTAssertNil(config.pipeline)
    }

    // MARK: 2. testFullConfig

    func testFullConfig() throws {
        let yaml = """
        title: Full Config Test
        devices:
          samplerate: 96000
          chunksize: 2048
          capture:
            type: RawFile
            channels: 2
            format: S32
          playback:
            type: RawFile
            channels: 1
            format: S32
        filters:
          gain6dB:
            type: Gain
            parameters:
              gain: 6.0
              scale: dB
          lpf1k:
            type: Biquad
            parameters:
              type: Lowpass
              freq: 1000.0
              q: 0.707
        mixers:
          stereo2mono:
            channels_in: 2
            channels_out: 1
            mapping:
              - dest: 0
                sources:
                  - channel: 0
                    gain: -6.0
                  - channel: 1
                    gain: -6.0
        processors:
          comp1:
            type: Compressor
            parameters:
              channels: 1
              attack: 0.01
              release: 0.1
              threshold: -20.0
              factor: 4.0
        pipeline:
          - type: Filter
            channel: 0
            names: [gain6dB]
          - type: Filter
            channel: 1
            names: [lpf1k]
          - type: Mixer
            name: stereo2mono
          - type: Processor
            name: comp1
        """
        let config = try ConfigLoader.parse(yaml: yaml)

        XCTAssertEqual(config.title, "Full Config Test")
        XCTAssertEqual(config.devices.samplerate, 96000)
        XCTAssertEqual(config.devices.chunksize, 2048)
        XCTAssertEqual(config.filters?.count, 2)
        XCTAssertNotNil(config.filters?["gain6dB"])
        XCTAssertNotNil(config.filters?["lpf1k"])
        XCTAssertEqual(config.mixers?.count, 1)
        XCTAssertNotNil(config.mixers?["stereo2mono"])
        XCTAssertEqual(config.processors?.count, 1)
        XCTAssertNotNil(config.processors?["comp1"])
        XCTAssertEqual(config.pipeline?.count, 4)
    }

    // MARK: 3. testTokenSubstitution

    func testTokenSubstitution() throws {
        let yaml = """
        devices:
          samplerate: $samplerate$
          chunksize: 1024
          capture:
            type: RawFile
            channels: $channels$
            format: S16
          playback:
            type: RawFile
            channels: $channels$
            format: S16
        """
        let config = try ConfigLoader.parse(yaml: yaml, samplerate: 48000, channels: 4)

        XCTAssertEqual(config.devices.samplerate, 48000)
        XCTAssertEqual(config.devices.capture.channels, 4)
        XCTAssertEqual(config.devices.playback.channels, 4)
    }

    // MARK: 4. testCrossoverConfig

    func testCrossoverConfig() throws {
        let yaml = """
        title: 2-Way Crossover
        devices:
          samplerate: 44100
          chunksize: 1024
          capture:
            type: RawFile
            channels: 2
            format: S16
          playback:
            type: RawFile
            channels: 4
            format: S16
        filters:
          lr4_lp_2k:
            type: BiquadCombo
            parameters:
              type: LinkwitzRileyLowpass
              freq: 2000.0
              order: 4
          lr4_hp_2k:
            type: BiquadCombo
            parameters:
              type: LinkwitzRileyHighpass
              freq: 2000.0
              order: 4
        mixers:
          split2x4:
            channels_in: 2
            channels_out: 4
            mapping:
              - dest: 0
                sources:
                  - channel: 0
                    gain: 0.0
              - dest: 1
                sources:
                  - channel: 0
                    gain: 0.0
              - dest: 2
                sources:
                  - channel: 1
                    gain: 0.0
              - dest: 3
                sources:
                  - channel: 1
                    gain: 0.0
        pipeline:
          - type: Mixer
            name: split2x4
          - type: Filter
            channel: 0
            names: [lr4_lp_2k]
          - type: Filter
            channel: 1
            names: [lr4_hp_2k]
          - type: Filter
            channel: 2
            names: [lr4_lp_2k]
          - type: Filter
            channel: 3
            names: [lr4_hp_2k]
        """
        let config = try ConfigLoader.parse(yaml: yaml)

        XCTAssertEqual(config.title, "2-Way Crossover")
        XCTAssertEqual(config.devices.capture.channels, 2)
        XCTAssertEqual(config.devices.playback.channels, 4)
        XCTAssertEqual(config.filters?.count, 2)
        XCTAssertNotNil(config.filters?["lr4_lp_2k"])
        XCTAssertNotNil(config.filters?["lr4_hp_2k"])
        XCTAssertNotNil(config.mixers?["split2x4"])
        XCTAssertEqual(config.pipeline?.count, 5)
        XCTAssertEqual(config.pipeline?.first?.type, .mixer)
    }

    // MARK: 5. testConfigWithResampler

    func testConfigWithResampler() throws {
        let yaml = """
        devices:
          samplerate: 96000
          chunksize: 1024
          resampler:
            type: AsyncSinc
            profile: Balanced
          capture:
            type: RawFile
            channels: 2
            format: S16
          playback:
            type: RawFile
            channels: 2
            format: S16
        """
        let config = try ConfigLoader.parse(yaml: yaml)

        let resampler = try XCTUnwrap(config.devices.resampler)
        XCTAssertEqual(resampler.type, .asyncSinc)
        XCTAssertEqual(resampler.profile, .balanced)
    }
}

// MARK: - Config Validation Tests

final class ConfigValidationTests: XCTestCase {

    // MARK: 6. testInvalidSampleRate

    func testInvalidSampleRate() throws {
        let yaml = makeDevicesYAML(samplerate: 0)
        XCTAssertThrowsError(try ConfigLoader.parse(yaml: yaml)) { error in
            guard case ConfigError.validationError(let msg) = error else {
                return XCTFail("Expected validationError, got \(error)")
            }
            XCTAssertTrue(msg.lowercased().contains("sample rate"))
        }
    }

    // MARK: 7. testInvalidChunkSize

    func testInvalidChunkSize() throws {
        let yaml = makeDevicesYAML(chunksize: 0)
        XCTAssertThrowsError(try ConfigLoader.parse(yaml: yaml)) { error in
            guard case ConfigError.validationError(let msg) = error else {
                return XCTFail("Expected validationError, got \(error)")
            }
            XCTAssertTrue(msg.lowercased().contains("chunk size"))
        }
    }

    // MARK: 8. testInvalidCaptureChannels

    func testInvalidCaptureChannels() throws {
        let yaml = makeDevicesYAML(captureChannels: 0)
        XCTAssertThrowsError(try ConfigLoader.parse(yaml: yaml)) { error in
            guard case ConfigError.validationError(let msg) = error else {
                return XCTFail("Expected validationError, got \(error)")
            }
            XCTAssertTrue(msg.lowercased().contains("capture"))
        }
    }

    // MARK: 9. testInvalidPlaybackChannels

    func testInvalidPlaybackChannels() throws {
        let yaml = makeDevicesYAML(playbackChannels: 0)
        XCTAssertThrowsError(try ConfigLoader.parse(yaml: yaml)) { error in
            guard case ConfigError.validationError(let msg) = error else {
                return XCTFail("Expected validationError, got \(error)")
            }
            XCTAssertTrue(msg.lowercased().contains("playback"))
        }
    }

    // MARK: 10. testMissingFilterReference

    func testMissingFilterReference() throws {
        let yaml = """
        devices:
          samplerate: 44100
          chunksize: 1024
          capture:
            type: RawFile
            channels: 2
            format: S16
          playback:
            type: RawFile
            channels: 2
            format: S16
        pipeline:
          - type: Filter
            channel: 0
            names: [nonexistentFilter]
        """
        XCTAssertThrowsError(try ConfigLoader.parse(yaml: yaml)) { error in
            guard case ConfigError.invalidPipeline(let msg) = error else {
                return XCTFail("Expected invalidPipeline, got \(error)")
            }
            XCTAssertTrue(msg.contains("nonexistentFilter"))
        }
    }

    // MARK: 11. testMissingMixerReference

    func testMissingMixerReference() throws {
        let yaml = """
        devices:
          samplerate: 44100
          chunksize: 1024
          capture:
            type: RawFile
            channels: 2
            format: S16
          playback:
            type: RawFile
            channels: 2
            format: S16
        pipeline:
          - type: Mixer
            name: nonexistentMixer
        """
        XCTAssertThrowsError(try ConfigLoader.parse(yaml: yaml)) { error in
            guard case ConfigError.invalidPipeline(let msg) = error else {
                return XCTFail("Expected invalidPipeline, got \(error)")
            }
            XCTAssertTrue(msg.contains("nonexistentMixer"))
        }
    }

    // MARK: 12. testMissingProcessorReference

    func testMissingProcessorReference() throws {
        let yaml = """
        devices:
          samplerate: 44100
          chunksize: 1024
          capture:
            type: RawFile
            channels: 2
            format: S16
          playback:
            type: RawFile
            channels: 2
            format: S16
        pipeline:
          - type: Processor
            name: nonexistentProcessor
        """
        XCTAssertThrowsError(try ConfigLoader.parse(yaml: yaml)) { error in
            guard case ConfigError.invalidPipeline(let msg) = error else {
                return XCTFail("Expected invalidPipeline, got \(error)")
            }
            XCTAssertTrue(msg.contains("nonexistentProcessor"))
        }
    }

    // MARK: 13. testFilterStepMissingChannel

    func testFilterStepMissingChannel() throws {
        let yaml = """
        devices:
          samplerate: 44100
          chunksize: 1024
          capture:
            type: RawFile
            channels: 2
            format: S16
          playback:
            type: RawFile
            channels: 2
            format: S16
        filters:
          gain1:
            type: Gain
            parameters:
              gain: 0.0
        pipeline:
          - type: Filter
            names: [gain1]
        """
        XCTAssertThrowsError(try ConfigLoader.parse(yaml: yaml)) { error in
            guard case ConfigError.invalidPipeline(let msg) = error else {
                return XCTFail("Expected invalidPipeline, got \(error)")
            }
            XCTAssertTrue(msg.lowercased().contains("channel"))
        }
    }

    // MARK: 14. testFilterStepMissingNames

    func testFilterStepMissingNames() throws {
        let yaml = """
        devices:
          samplerate: 44100
          chunksize: 1024
          capture:
            type: RawFile
            channels: 2
            format: S16
          playback:
            type: RawFile
            channels: 2
            format: S16
        pipeline:
          - type: Filter
            channel: 0
        """
        XCTAssertThrowsError(try ConfigLoader.parse(yaml: yaml)) { error in
            guard case ConfigError.invalidPipeline(let msg) = error else {
                return XCTFail("Expected invalidPipeline, got \(error)")
            }
            XCTAssertTrue(msg.lowercased().contains("names"))
        }
    }

    // MARK: 15. testValidCompleteConfig

    func testValidCompleteConfig() throws {
        let yaml = """
        title: Valid Complete Config
        devices:
          samplerate: 48000
          chunksize: 512
          capture:
            type: RawFile
            channels: 2
            format: S32
          playback:
            type: RawFile
            channels: 2
            format: S32
        filters:
          highpass80:
            type: Biquad
            parameters:
              type: Highpass
              freq: 80.0
              q: 0.707
          lowpass10k:
            type: Biquad
            parameters:
              type: Lowpass
              freq: 10000.0
              q: 0.707
        mixers:
          passthrough:
            channels_in: 2
            channels_out: 2
            mapping:
              - dest: 0
                sources:
                  - channel: 0
                    gain: 0.0
              - dest: 1
                sources:
                  - channel: 1
                    gain: 0.0
        pipeline:
          - type: Filter
            channel: 0
            names: [highpass80, lowpass10k]
          - type: Filter
            channel: 1
            names: [highpass80, lowpass10k]
          - type: Mixer
            name: passthrough
        """
        // Should not throw
        let config = try ConfigLoader.parse(yaml: yaml)
        XCTAssertEqual(config.devices.samplerate, 48000)
        XCTAssertEqual(config.pipeline?.count, 3)
    }
}

// MARK: - Pipeline Tests

final class PipelineTests: XCTestCase {

    // MARK: 16. testEmptyPipeline

    func testEmptyPipeline() throws {
        let yaml = makeDevicesYAML()
        let config = try ConfigLoader.parse(yaml: yaml)
        let params = ProcessingParameters()
        let pipeline = try Pipeline(config: config, processingParams: params)

        let inputData: [PrcFmt] = [0.1, 0.2, -0.3, 0.4]
        var chunk = AudioChunk(waveforms: [inputData, inputData])
        try pipeline.process(chunk: &chunk)

        // Passthrough: waveforms should be unchanged
        XCTAssertEqual(chunk.waveforms[0], inputData)
        XCTAssertEqual(chunk.waveforms[1], inputData)
    }

    // MARK: 17. testSingleFilterPipeline

    func testSingleFilterPipeline() throws {
        let yaml = """
        devices:
          samplerate: 44100
          chunksize: 4
          capture:
            type: RawFile
            channels: 2
            format: S16
          playback:
            type: RawFile
            channels: 2
            format: S16
        filters:
          gainMinus6:
            type: Gain
            parameters:
              gain: -6.0
              scale: dB
        pipeline:
          - type: Filter
            channel: 0
            names: [gainMinus6]
        """
        let config = try ConfigLoader.parse(yaml: yaml)
        let params = ProcessingParameters()
        let pipeline = try Pipeline(config: config, processingParams: params)

        let inputData: [PrcFmt] = [1.0, 0.5, -0.5, -1.0]
        var chunk = AudioChunk(waveforms: [inputData, inputData])
        try pipeline.process(chunk: &chunk)

        // Channel 0: -6 dB = linear factor ~0.5012
        let expectedGain = PrcFmt.fromDB(-6.0)
        for i in 0..<inputData.count {
            XCTAssertEqual(chunk.waveforms[0][i], inputData[i] * expectedGain, accuracy: 1e-9)
        }
        // Channel 1: unchanged
        XCTAssertEqual(chunk.waveforms[1], inputData)
    }

    // MARK: 18. testMultiFilterPipeline

    func testMultiFilterPipeline() throws {
        let yaml = """
        devices:
          samplerate: 44100
          chunksize: 4
          capture:
            type: RawFile
            channels: 1
            format: S16
          playback:
            type: RawFile
            channels: 1
            format: S16
        filters:
          gain3dB:
            type: Gain
            parameters:
              gain: 3.0
              scale: dB
          gainMinus3dB:
            type: Gain
            parameters:
              gain: -3.0
              scale: dB
        pipeline:
          - type: Filter
            channel: 0
            names: [gain3dB, gainMinus3dB]
        """
        let config = try ConfigLoader.parse(yaml: yaml)
        let params = ProcessingParameters()
        let pipeline = try Pipeline(config: config, processingParams: params)

        let inputData: [PrcFmt] = [1.0, 0.5, -0.5, -1.0]
        var chunk = AudioChunk(waveforms: [inputData])
        try pipeline.process(chunk: &chunk)

        // +3 dB then -3 dB should cancel out to ~identity
        for i in 0..<inputData.count {
            XCTAssertEqual(chunk.waveforms[0][i], inputData[i], accuracy: 1e-9)
        }
    }

    // MARK: 19. testPipelineWithMixer

    func testPipelineWithMixer() throws {
        let yaml = """
        devices:
          samplerate: 44100
          chunksize: 4
          capture:
            type: RawFile
            channels: 2
            format: S16
          playback:
            type: RawFile
            channels: 1
            format: S16
        filters:
          gain0dB:
            type: Gain
            parameters:
              gain: 0.0
              scale: dB
        mixers:
          mono:
            channels_in: 2
            channels_out: 1
            mapping:
              - dest: 0
                sources:
                  - channel: 0
                    gain: -6.0
                  - channel: 1
                    gain: -6.0
        pipeline:
          - type: Filter
            channel: 0
            names: [gain0dB]
          - type: Filter
            channel: 1
            names: [gain0dB]
          - type: Mixer
            name: mono
        """
        let config = try ConfigLoader.parse(yaml: yaml)
        let params = ProcessingParameters()
        let pipeline = try Pipeline(config: config, processingParams: params)

        let ch0: [PrcFmt] = [1.0, 1.0, 1.0, 1.0]
        let ch1: [PrcFmt] = [1.0, 1.0, 1.0, 1.0]
        var chunk = AudioChunk(waveforms: [ch0, ch1])
        try pipeline.process(chunk: &chunk)

        // After mixer: 1 output channel
        XCTAssertEqual(chunk.channels, 1)
        // Each output sample = 2 * fromDB(-6.0) * 1.0
        let gain = PrcFmt.fromDB(-6.0)
        for i in 0..<4 {
            XCTAssertEqual(chunk.waveforms[0][i], 2.0 * gain, accuracy: 1e-9)
        }
    }

    // MARK: 20. testPipelinePreservesUnfilteredChannels

    func testPipelinePreservesUnfilteredChannels() throws {
        let yaml = """
        devices:
          samplerate: 44100
          chunksize: 4
          capture:
            type: RawFile
            channels: 2
            format: S16
          playback:
            type: RawFile
            channels: 2
            format: S16
        filters:
          gainMinus12:
            type: Gain
            parameters:
              gain: -12.0
              scale: dB
        pipeline:
          - type: Filter
            channel: 0
            names: [gainMinus12]
        """
        let config = try ConfigLoader.parse(yaml: yaml)
        let params = ProcessingParameters()
        let pipeline = try Pipeline(config: config, processingParams: params)

        let ch0: [PrcFmt] = [1.0, -1.0, 0.5, -0.5]
        let ch1: [PrcFmt] = [0.3, 0.6, -0.3, -0.6]
        var chunk = AudioChunk(waveforms: [ch0, ch1])
        try pipeline.process(chunk: &chunk)

        // Channel 0: attenuated by -12 dB
        let gain = PrcFmt.fromDB(-12.0)
        for i in 0..<4 {
            XCTAssertEqual(chunk.waveforms[0][i], ch0[i] * gain, accuracy: 1e-9)
        }
        // Channel 1: completely unchanged
        XCTAssertEqual(chunk.waveforms[1], ch1)
    }
}

// MARK: - ProcessingParameters Tests

final class ProcessingParametersTests: XCTestCase {

    // MARK: 21. testAllFaders

    func testAllFaders() {
        let params = ProcessingParameters()

        let faders: [Fader] = [.main, .aux1, .aux2, .aux3, .aux4]
        let testVolumes: [PrcFmt] = [-10.0, -20.0, -30.0, -40.0, -50.0]

        // Set volumes for all faders
        for (fader, vol) in zip(faders, testVolumes) {
            params.setTargetVolume(fader, vol)
        }

        // Read back and verify each fader is independent
        for (fader, vol) in zip(faders, testVolumes) {
            XCTAssertEqual(params.getTargetVolume(fader), vol, accuracy: 1e-9,
                           "Fader \(fader) volume mismatch")
        }

        // Test mute state for all faders
        for fader in faders {
            XCTAssertFalse(params.isMuted(fader), "Fader \(fader) should start unmuted")
            params.setMute(fader, true)
            XCTAssertTrue(params.isMuted(fader), "Fader \(fader) should be muted")
            params.toggleMute(fader)
            XCTAssertFalse(params.isMuted(fader), "Fader \(fader) should be unmuted after toggle")
        }

        // Test adjustVolume for all faders
        for fader in faders {
            let before = params.getTargetVolume(fader)
            params.adjustVolume(fader, by: 5.0)
            XCTAssertEqual(params.getTargetVolume(fader), before + 5.0, accuracy: 1e-9,
                           "Fader \(fader) adjustVolume failed")
        }

        // Verify fader indices are unique and correct
        XCTAssertEqual(Fader.main.index, 0)
        XCTAssertEqual(Fader.aux1.index, 1)
        XCTAssertEqual(Fader.aux2.index, 2)
        XCTAssertEqual(Fader.aux3.index, 3)
        XCTAssertEqual(Fader.aux4.index, 4)
        XCTAssertEqual(Fader.allCases.count, 5)
    }

    // MARK: 22. testConcurrentAccess

    func testConcurrentAccess() {
        let params = ProcessingParameters()
        let iterations = 1000
        let expectation = self.expectation(description: "Concurrent access completes")
        expectation.expectedFulfillmentCount = 2

        // Writer thread: continuously adjusts Main volume
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<iterations {
                params.setTargetVolume(.main, PrcFmt(i) * -0.1)
                params.setMute(.aux1, i % 2 == 0)
                params.adjustVolume(.aux2, by: 0.01)
            }
            expectation.fulfill()
        }

        // Reader thread: continuously reads values without crashing
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<iterations {
                _ = params.getTargetVolume(.main)
                _ = params.isMuted(.aux1)
                _ = params.getCurrentVolume(.aux2)
                _ = params.processingLoad
            }
            expectation.fulfill()
        }

        waitForExpectations(timeout: 10.0)

        // After concurrent writes, aux2 should have accumulated adjustments
        // (iterations * 0.01 adjustments from 0.0 baseline)
        let finalAux2 = params.getTargetVolume(.aux2)
        XCTAssertEqual(finalAux2, Double(iterations) * 0.01, accuracy: 1e-6,
                       "Concurrent adjustVolume should accumulate correctly")
    }
}
