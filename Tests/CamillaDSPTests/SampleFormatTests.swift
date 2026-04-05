// SampleFormatTests.swift
// Tests for sample format encode/decode, matching the CamillaDSP Rust test suite.

import XCTest
@testable import CamillaDSPLib

final class SampleFormatTests: XCTestCase {

    // MARK: - Helpers

    /// Encode waveforms to Data then decode back to [[PrcFmt]].
    private func roundTrip(
        _ samples: [PrcFmt],
        format: SampleFormat
    ) -> [PrcFmt] {
        let waveforms: [[PrcFmt]] = [samples]
        let data = waveformsToBytes(waveforms, format: format, frames: samples.count)
        let recovered = data.withUnsafeBytes { ptr in
            bytesToWaveforms(ptr, format: format, channels: 1, frames: samples.count)
        }
        return recovered[0]
    }

    // MARK: - Round-trip tests

    func testRoundTripS16() {
        let input: [PrcFmt] = [-0.5, 0.0, 0.5]
        let output = roundTrip(input, format: .s16)
        // S16 has 15-bit mantissa; a perfect power-of-two fraction round-trips exactly.
        for (a, b) in zip(input, output) {
            XCTAssertEqual(a, b, accuracy: 1.0 / PrcFmt(Int16.max),
                           "S16 round-trip failed: expected \(a), got \(b)")
        }
    }

    func testRoundTripS24_3() {
        let input: [PrcFmt] = [-0.5, 0.0, 0.5]
        let output = roundTrip(input, format: .s24_3)
        for (a, b) in zip(input, output) {
            XCTAssertEqual(a, b, accuracy: 1e-6,
                           "S24_3 round-trip failed: expected \(a), got \(b)")
        }
    }

    func testRoundTripS24_4() {
        let input: [PrcFmt] = [-0.5, 0.0, 0.5]
        let output = roundTrip(input, format: .s24_4)
        for (a, b) in zip(input, output) {
            XCTAssertEqual(a, b, accuracy: 1e-6,
                           "S24_4 round-trip failed: expected \(a), got \(b)")
        }
    }

    func testRoundTripS32() {
        let input: [PrcFmt] = [-0.5, 0.0, 0.5]
        let output = roundTrip(input, format: .s32)
        for (a, b) in zip(input, output) {
            XCTAssertEqual(a, b, accuracy: 1e-9,
                           "S32 round-trip failed: expected \(a), got \(b)")
        }
    }

    func testRoundTripFloat32() {
        let input: [PrcFmt] = [-0.5, 0.0, 0.5]
        let output = roundTrip(input, format: .float32)
        // Float32 → PrcFmt (Double) is lossless for these values.
        for (a, b) in zip(input, output) {
            XCTAssertEqual(a, b, accuracy: 0.0,
                           "Float32 round-trip failed: expected \(a), got \(b)")
        }
    }

    func testRoundTripFloat64() {
        let input: [PrcFmt] = [-0.5, 0.0, 0.5]
        let output = roundTrip(input, format: .float64)
        for (a, b) in zip(input, output) {
            XCTAssertEqual(a, b, accuracy: 0.0,
                           "Float64 round-trip failed: expected \(a), got \(b)")
        }
    }

    // MARK: - Clipping tests

    func testClippingS16() {
        let input: [PrcFmt] = [-2.0, 0.0, 2.0]
        let output = roundTrip(input, format: .s16)
        // Values beyond ±1.0 must be clamped.
        XCTAssertLessThanOrEqual(output[2], 1.0, "S16 clipping: positive overload not clamped")
        XCTAssertGreaterThanOrEqual(output[0], -1.0, "S16 clipping: negative overload not clamped")
        // The clamped value must round-trip to the maximum representable level (~1.0).
        XCTAssertEqual(output[2], PrcFmt(Int16.max) / PrcFmt(Int16.max), accuracy: 1e-6)
        XCTAssertEqual(output[0], -1.0, accuracy: 1e-3)
        XCTAssertEqual(output[1], 0.0, accuracy: 1e-10)
    }

    func testClippingS24() {
        let input: [PrcFmt] = [-2.0, 0.0, 2.0]
        // S24_3 and S24_4 share the same integer range.
        for format in [SampleFormat.s24_3, SampleFormat.s24_4] {
            let output = roundTrip(input, format: format)
            XCTAssertLessThanOrEqual(output[2], 1.0, "\(format) clipping: positive overload not clamped")
            XCTAssertGreaterThanOrEqual(output[0], -1.0, "\(format) clipping: negative overload not clamped")
            // Maximum S24 value is (2^23 - 1); after encode/decode ~1.0.
            let s24Max = PrcFmt((1 << 23) - 1)
            XCTAssertEqual(output[2], s24Max / s24Max, accuracy: 1e-6)
            XCTAssertEqual(output[1], 0.0, accuracy: 1e-10)
        }
    }

    func testClippingS32() {
        let input: [PrcFmt] = [-2.0, 0.0, 2.0]
        let output = roundTrip(input, format: .s32)
        XCTAssertLessThanOrEqual(output[2], 1.0, "S32 clipping: positive overload not clamped")
        XCTAssertGreaterThanOrEqual(output[0], -1.0, "S32 clipping: negative overload not clamped")
        XCTAssertEqual(output[2], PrcFmt(Int32.max) / PrcFmt(Int32.max), accuracy: 1e-9)
        XCTAssertEqual(output[1], 0.0, accuracy: 1e-10)
    }

    // MARK: - Specific byte pattern tests

    /// Float 0.1 encoded as S16 little-endian.
    /// Int16(0.1 * 32767) = Int16(3276) = 0x0CCC  →  LE bytes [0xCC, 0x0C]
    func testS16BytePattern() {
        let waveforms: [[PrcFmt]] = [[0.1]]
        let data = waveformsToBytes(waveforms, format: .s16, frames: 1)
        XCTAssertEqual(data.count, 2)
        // 0.1 * 32767 = 3276.7, truncated to Int16 = 3276 = 0x0CCC
        let expected: [UInt8] = [0xCC, 0x0C]
        XCTAssertEqual([UInt8](data), expected,
                       "S16 byte pattern mismatch: got \(data.map { String(format: "0x%02X", $0) })")
    }

    /// Float 0.1 encoded as IEEE 754 single-precision little-endian.
    /// Float(0.1).bitPattern == 0x3DCCCCCD  →  LE bytes [0xCD, 0xCC, 0xCC, 0x3D]
    func testFloat32BytePattern() {
        let waveforms: [[PrcFmt]] = [[0.1]]
        let data = waveformsToBytes(waveforms, format: .float32, frames: 1)
        XCTAssertEqual(data.count, 4)
        let expected: [UInt8] = [0xCD, 0xCC, 0xCC, 0x3D]
        XCTAssertEqual([UInt8](data), expected,
                       "Float32 byte pattern mismatch: got \(data.map { String(format: "0x%02X", $0) })")
    }

    // MARK: - Multi-channel tests

    func testMultiChannelRoundTrip() {
        // 2 channels, 3 frames, interleaved.
        let ch0: [PrcFmt] = [-0.5, 0.0, 0.5]
        let ch1: [PrcFmt] = [0.25, -0.25, 0.75]
        let waveforms: [[PrcFmt]] = [ch0, ch1]

        for format in [SampleFormat.s16, .s24_3, .s24_4, .s32, .float32, .float64] {
            let data = waveformsToBytes(waveforms, format: format, frames: 3)
            let recovered = data.withUnsafeBytes { ptr in
                bytesToWaveforms(ptr, format: format, channels: 2, frames: 3)
            }
            XCTAssertEqual(recovered.count, 2, "\(format): channel count mismatch")
            XCTAssertEqual(recovered[0].count, 3, "\(format): frame count mismatch ch0")
            XCTAssertEqual(recovered[1].count, 3, "\(format): frame count mismatch ch1")

            let tolerance: PrcFmt = {
                switch format {
                case .s16:     return 1.0 / PrcFmt(Int16.max)
                case .s24_3, .s24_4, .s24_4_lj: return 1e-6
                case .s32:     return 1e-9
                case .float32, .float64: return 0.0
                }
            }()

            for i in 0..<3 {
                XCTAssertEqual(recovered[0][i], ch0[i], accuracy: tolerance,
                               "\(format) ch0[\(i)]: expected \(ch0[i]), got \(recovered[0][i])")
                XCTAssertEqual(recovered[1][i], ch1[i], accuracy: tolerance,
                               "\(format) ch1[\(i)]: expected \(ch1[i]), got \(recovered[1][i])")
            }
        }
    }

    func testBytesPerSample() {
        XCTAssertEqual(SampleFormat.s16.bytesPerSample, 2)
        XCTAssertEqual(SampleFormat.s24_3.bytesPerSample, 3)
        XCTAssertEqual(SampleFormat.s24_4.bytesPerSample, 4)
        XCTAssertEqual(SampleFormat.s32.bytesPerSample, 4)
        XCTAssertEqual(SampleFormat.float32.bytesPerSample, 4)
        XCTAssertEqual(SampleFormat.float64.bytesPerSample, 8)
    }

    // MARK: - Edge case tests

    func testZeroValues() {
        let input: [PrcFmt] = [0.0, 0.0, 0.0, 0.0]
        for format in [SampleFormat.s16, .s24_3, .s24_4, .s32, .float32, .float64] {
            let output = roundTrip(input, format: format)
            for (i, v) in output.enumerated() {
                XCTAssertEqual(v, 0.0, accuracy: 0.0,
                               "\(format) zero[\(i)]: expected 0.0, got \(v)")
            }
        }
    }

    func testFullScale() {
        let input: [PrcFmt] = [1.0, -1.0]

        // Integer formats: +1.0 cannot be represented exactly (max is maxValue/maxValue < 1),
        // so we only verify that the decoded value is the closest representable maximum.
        for format in [SampleFormat.s16, .s24_3, .s24_4, .s32] {
            let waveforms: [[PrcFmt]] = [input]
            let data = waveformsToBytes(waveforms, format: format, frames: input.count)
            let recovered = data.withUnsafeBytes { ptr in
                bytesToWaveforms(ptr, format: format, channels: 1, frames: input.count)
            }[0]

            // Positive full-scale encodes to the maximum integer, decodes to
            // maxInt / maxInt == 1.0 (exactly, since they divide evenly).
            XCTAssertEqual(recovered[0], 1.0, accuracy: 1e-6,
                           "\(format) full-scale positive mismatch: \(recovered[0])")
            // Negative full-scale: -1.0 * maxInt truncates to -maxInt (not Int.min),
            // so the decoded value is -1.0 within floating-point precision.
            XCTAssertEqual(recovered[1], -1.0, accuracy: 1.0 / format.maxValue,
                           "\(format) full-scale negative mismatch: \(recovered[1])")
        }

        // Floating-point formats round-trip exactly.
        for format in [SampleFormat.float32, .float64] {
            let output = roundTrip(input, format: format)
            XCTAssertEqual(output[0], 1.0, accuracy: 0.0, "\(format) full-scale +1.0 mismatch")
            XCTAssertEqual(output[1], -1.0, accuracy: 0.0, "\(format) full-scale -1.0 mismatch")
        }
    }
}
