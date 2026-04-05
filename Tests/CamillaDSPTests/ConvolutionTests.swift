// CamillaDSP-Swift: Convolution filter tests
// Mirrors the CamillaDSP Rust test suite for FIR convolution correctness.

import XCTest
@testable import CamillaDSPLib

final class ConvolutionTests: XCTestCase {

    // MARK: - Helpers

    /// Build a ConvolutionFilter from an inline values array.
    private func makeFilter(ir: [PrcFmt], chunkSize: Int) throws -> ConvolutionFilter {
        var params = FilterParameters()
        params.subtype = "Values"
        params.values = ir
        let config = FilterConfig(type: .conv, parameters: params)
        return try ConvolutionFilter(name: "test", config: config, chunkSize: chunkSize, sampleRate: 48000)
    }

    // MARK: - testMovingAverage
    // 2-tap moving-average IR [0.5, 0.5], chunkSize=8.
    // Input:    [1, 1, 1, 0, 0, -1, 0, 0]
    // Expected: [0.5, 1.0, 1.0, 0.5, 0.0, -0.5, -0.5, 0.0]

    func testMovingAverage() throws {
        let chunkSize = 8
        let filter = try makeFilter(ir: [0.5, 0.5], chunkSize: chunkSize)

        var waveform: [PrcFmt] = [1.0, 1.0, 1.0, 0.0, 0.0, -1.0, 0.0, 0.0]
        try filter.process(waveform: &waveform)

        let expected: [PrcFmt] = [0.5, 1.0, 1.0, 0.5, 0.0, -0.5, -0.5, 0.0]
        XCTAssertEqual(waveform.count, expected.count)
        for (i, (got, exp)) in zip(waveform, expected).enumerated() {
            XCTAssertEqual(got, exp, accuracy: 1e-7,
                           "moving average mismatch at sample \(i): got \(got), expected \(exp)")
        }
    }

    // MARK: - testSegmentedConvolution
    // 32-coefficient IR [0,1,2,...,31] with chunkSize=8 (forces 4 segments).
    // Feed an impulse [1,0,0,...] spread across 5 chunks.
    // The output of each chunk should equal the corresponding 8-coefficient slice of the IR,
    // and the 5th chunk should be all zeros.

    func testSegmentedConvolution() throws {
        let chunkSize = 8
        let irLength = 32
        let ir = (0..<irLength).map { PrcFmt($0) }          // [0, 1, 2, ..., 31]
        let filter = try makeFilter(ir: ir, chunkSize: chunkSize)

        // Chunk 1: impulse at sample 0
        var chunk1 = [PrcFmt](repeating: 0.0, count: chunkSize)
        chunk1[0] = 1.0
        try filter.process(waveform: &chunk1)

        let expected1: [PrcFmt] = [0, 1, 2, 3, 4, 5, 6, 7]
        for (i, (got, exp)) in zip(chunk1, expected1).enumerated() {
            XCTAssertEqual(got, exp, accuracy: 1e-5,
                           "segment chunk 1 mismatch at sample \(i): got \(got), expected \(exp)")
        }

        // Chunk 2
        var chunk2 = [PrcFmt](repeating: 0.0, count: chunkSize)
        try filter.process(waveform: &chunk2)

        let expected2: [PrcFmt] = [8, 9, 10, 11, 12, 13, 14, 15]
        for (i, (got, exp)) in zip(chunk2, expected2).enumerated() {
            XCTAssertEqual(got, exp, accuracy: 1e-5,
                           "segment chunk 2 mismatch at sample \(i): got \(got), expected \(exp)")
        }

        // Chunk 3
        var chunk3 = [PrcFmt](repeating: 0.0, count: chunkSize)
        try filter.process(waveform: &chunk3)

        let expected3: [PrcFmt] = [16, 17, 18, 19, 20, 21, 22, 23]
        for (i, (got, exp)) in zip(chunk3, expected3).enumerated() {
            XCTAssertEqual(got, exp, accuracy: 1e-5,
                           "segment chunk 3 mismatch at sample \(i): got \(got), expected \(exp)")
        }

        // Chunk 4
        var chunk4 = [PrcFmt](repeating: 0.0, count: chunkSize)
        try filter.process(waveform: &chunk4)

        let expected4: [PrcFmt] = [24, 25, 26, 27, 28, 29, 30, 31]
        for (i, (got, exp)) in zip(chunk4, expected4).enumerated() {
            XCTAssertEqual(got, exp, accuracy: 1e-5,
                           "segment chunk 4 mismatch at sample \(i): got \(got), expected \(exp)")
        }

        // Chunk 5: tail should be all zeros (IR is fully spent)
        var chunk5 = [PrcFmt](repeating: 0.0, count: chunkSize)
        try filter.process(waveform: &chunk5)

        for (i, got) in chunk5.enumerated() {
            XCTAssertEqual(got, 0.0, accuracy: 1e-5,
                           "segment chunk 5 should be zero at sample \(i): got \(got)")
        }
    }

    // MARK: - testIdentityConvolution
    // IR = [1.0]: convolution with a unit impulse is the identity transform.

    func testIdentityConvolution() throws {
        let chunkSize = 8
        let filter = try makeFilter(ir: [1.0], chunkSize: chunkSize)

        var waveform: [PrcFmt] = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        let original = waveform
        try filter.process(waveform: &waveform)

        for (i, (got, exp)) in zip(waveform, original).enumerated() {
            XCTAssertEqual(got, exp, accuracy: 1e-7,
                           "identity convolution mismatch at sample \(i): got \(got), expected \(exp)")
        }
    }

    // MARK: - testDelayConvolution
    // IR = [0, 0, 0, 1.0]: convolving with this IR delays the input by 3 samples.

    func testDelayConvolution() throws {
        let chunkSize = 8
        let filter = try makeFilter(ir: [0.0, 0.0, 0.0, 1.0], chunkSize: chunkSize)

        // Impulse at sample 0
        var waveform: [PrcFmt] = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        try filter.process(waveform: &waveform)

        // Samples before the delay should be zero
        XCTAssertEqual(waveform[0], 0.0, accuracy: 1e-7, "delay: sample 0 should be 0")
        XCTAssertEqual(waveform[1], 0.0, accuracy: 1e-7, "delay: sample 1 should be 0")
        XCTAssertEqual(waveform[2], 0.0, accuracy: 1e-7, "delay: sample 2 should be 0")
        // Delayed impulse appears at sample 3
        XCTAssertEqual(waveform[3], 1.0, accuracy: 1e-7, "delay: impulse should appear at sample 3")
        // Samples after the impulse should be zero again
        for i in 4..<chunkSize {
            XCTAssertEqual(waveform[i], 0.0, accuracy: 1e-7,
                           "delay: sample \(i) should be 0 after delayed impulse")
        }
    }

    // MARK: - testConvolutionWithSineWave
    // Convolve a steady-state sine wave with a known IR and verify the output amplitude.
    // IR = [0.5, 0.5] (moving average): a sine at frequency f is attenuated by
    //   |H(f)| = |1 + e^{-j2πf/fs}| * 0.5
    // For a low-frequency sine (f << fs) the attenuation is ~1 (passes through).
    // We verify that after the transient the output amplitude is within ±10% of the expected value.

    func testConvolutionWithSineWave() throws {
        let chunkSize = 64
        let sampleRate: PrcFmt = 48000.0
        let frequency: PrcFmt = 100.0       // well below Nyquist
        let filter = try makeFilter(ir: [0.5, 0.5], chunkSize: chunkSize)

        // Expected gain of [0.5, 0.5] at 100 Hz:
        // H(f) = 0.5 * (1 + exp(-j * 2π * f / fs))
        // |H(f)| = 0.5 * |1 + cos(2πf/fs) - j*sin(2πf/fs)|
        //        = 0.5 * sqrt((1 + cos(θ))^2 + sin^2(θ))  where θ = 2πf/fs
        //        ≈ 1 for small θ
        let theta = 2.0 * PrcFmt.pi * frequency / sampleRate
        let expectedGain = 0.5 * (1.0 + cos(theta))   // real part of H(f) for a cosine signal

        // Generate several chunks of a 100 Hz cosine to reach steady state,
        // then verify the amplitude of the last chunk.
        var lastChunk = [PrcFmt](repeating: 0.0, count: chunkSize)
        let totalChunks = 8
        for chunk in 0..<totalChunks {
            var waveform = [PrcFmt](repeating: 0.0, count: chunkSize)
            let offset = chunk * chunkSize
            for i in 0..<chunkSize {
                waveform[i] = cos(2.0 * PrcFmt.pi * frequency * PrcFmt(offset + i) / sampleRate)
            }
            try filter.process(waveform: &waveform)
            if chunk == totalChunks - 1 {
                lastChunk = waveform
            }
        }

        let peakAmplitude = DSPOps.peakAbsolute(lastChunk)
        XCTAssertEqual(peakAmplitude, expectedGain, accuracy: expectedGain * 0.10,
                       "sine wave amplitude after convolution (\(peakAmplitude)) should be within 10% of expected (\(expectedGain))")
    }

    // MARK: - testEmptyIRThrows
    // Passing an empty values array must throw a ConfigError.

    func testEmptyIRThrows() {
        var params = FilterParameters()
        params.subtype = "Values"
        params.values = []
        let config = FilterConfig(type: .conv, parameters: params)

        XCTAssertThrowsError(
            try ConvolutionFilter(name: "empty_ir", config: config, chunkSize: 8, sampleRate: 48000),
            "Creating a ConvolutionFilter with an empty IR should throw"
        ) { error in
            // Verify we get a ConfigError, not some other kind of error.
            XCTAssertTrue(error is ConfigError,
                          "Expected ConfigError but got \(type(of: error)): \(error)")
        }
    }
}
