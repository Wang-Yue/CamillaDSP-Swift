// BiquadComboTests.swift
// Tests for BiquadComboFilter - mirrors the CamillaDSP Rust test suite

import XCTest
@testable import CamillaDSPLib

final class BiquadComboTests: XCTestCase {

    // MARK: - Helpers

    private let sampleRate = 48000

    /// Generate a sine wave at the given frequency.
    private func makeSine(freq: Double, frames: Int, sr: Int = 48000) -> [PrcFmt] {
        (0..<frames).map { i in sin(2.0 * .pi * freq * Double(i) / Double(sr)) }
    }

    /// Compute peak absolute value of the steady-state portion (skip first half for transients).
    private func steadyStatePeak(_ buf: [PrcFmt]) -> PrcFmt {
        let start = buf.count / 2
        return DSPOps.peakAbsolute(Array(buf[start...]))
    }

    /// Build a BiquadComboFilter with a given combo type, freq, and order.
    private func makeFilter(
        type: BiquadComboType,
        freq: Double,
        order: Int,
        sampleRate: Int? = nil
    ) throws -> BiquadComboFilter {
        var params = FilterParameters()
        params.subtype = type.rawValue
        params.freq = freq
        params.order = order
        let config = FilterConfig(type: .biquadCombo, parameters: params)
        return try BiquadComboFilter(name: "test", config: config, sampleRate: sampleRate ?? self.sampleRate)
    }

    /// Helper: check two Double arrays are close element-wise.
    private func compareVecs(_ left: [PrcFmt], _ right: [PrcFmt], maxDiff: PrcFmt) -> Bool {
        guard left.count == right.count else { return false }
        for (l, r) in zip(left, right) {
            if abs(l - r) >= maxDiff { return false }
        }
        return true
    }

    /// Helper: validate a BiquadCombo config through FilterValidator.
    private func validateConfig(
        type: BiquadComboType,
        freq: Double = 1000.0,
        order: Int = 4,
        sampleRate: Int = 48000
    ) -> Bool {
        var params = FilterParameters()
        params.subtype = type.rawValue
        params.freq = freq
        params.order = order
        let config = FilterConfig(type: .biquadCombo, parameters: params)
        do {
            try FilterValidator.validate(config, sampleRate: sampleRate)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Rust-matching Q-value tests

    /// Mirrors Rust: make_butterworth_2
    /// Q values = [0.707], len = 1
    func testMakeButterworthQ2() {
        let q = BiquadComboFilter.butterworthQ(order: 2)
        let expect: [PrcFmt] = [0.707]
        XCTAssertEqual(q.count, 1)
        XCTAssertTrue(compareVecs(q, expect, maxDiff: 0.01),
                       "BW order 2 Q values should be [0.707], got \(q)")
    }

    /// Mirrors Rust: make_butterworth_5
    /// Q values = [1.62, 0.62, -1.0], len = 3
    func testMakeButterworthQ5() {
        let q = BiquadComboFilter.butterworthQ(order: 5)
        let expect: [PrcFmt] = [1.62, 0.62, -1.0]
        XCTAssertEqual(q.count, 3)
        XCTAssertTrue(compareVecs(q, expect, maxDiff: 0.01),
                       "BW order 5 Q values should be [1.62, 0.62, -1.0], got \(q)")
    }

    /// Mirrors Rust: make_butterworth_8
    /// Q values = [2.56, 0.9, 0.6, 0.51], len = 4
    func testMakeButterworthQ8() {
        let q = BiquadComboFilter.butterworthQ(order: 8)
        let expect: [PrcFmt] = [2.56, 0.9, 0.6, 0.51]
        XCTAssertEqual(q.count, 4)
        XCTAssertTrue(compareVecs(q, expect, maxDiff: 0.01),
                       "BW order 8 Q values should be [2.56, 0.9, 0.6, 0.51], got \(q)")
    }

    /// Mirrors Rust: make_lr4
    /// Q values = [0.707, 0.707], len = 2
    func testMakeLR4() {
        let q = BiquadComboFilter.linkwitzRileyQ(order: 4)
        let expect: [PrcFmt] = [0.707, 0.707]
        XCTAssertEqual(q.count, 2)
        XCTAssertTrue(compareVecs(q, expect, maxDiff: 0.01),
                       "LR order 4 Q values should be [0.707, 0.707], got \(q)")
    }

    /// Mirrors Rust: make_lr6 (actually LR10)
    /// Q values = [1.62, 0.62, 1.62, 0.62, 0.5], len = 5
    func testMakeLR10() {
        let q = BiquadComboFilter.linkwitzRileyQ(order: 10)
        let expect: [PrcFmt] = [1.62, 0.62, 1.62, 0.62, 0.5]
        XCTAssertEqual(q.count, 5)
        XCTAssertTrue(compareVecs(q, expect, maxDiff: 0.01),
                       "LR order 10 Q values should be [1.62, 0.62, 1.62, 0.62, 0.5], got \(q)")
    }

    // MARK: - Rust-matching validation tests

    /// Mirrors Rust: check_lr
    /// order=5 (bad), order=0 (bad), freq=0 (bad), freq=25000 (bad), order=6 (ok)
    func testCheckLR() {
        // ok: order=6, freq=1000
        XCTAssertTrue(validateConfig(type: .linkwitzRileyHighpass, freq: 1000.0, order: 6),
                       "LR HP order=6, freq=1000 should be valid")

        // bad: order=5 (odd)
        XCTAssertFalse(validateConfig(type: .linkwitzRileyHighpass, freq: 1000.0, order: 5),
                        "LR HP order=5 should be invalid (odd)")

        // bad: order=0
        XCTAssertFalse(validateConfig(type: .linkwitzRileyHighpass, freq: 1000.0, order: 0),
                        "LR HP order=0 should be invalid")

        // bad: freq=0
        XCTAssertFalse(validateConfig(type: .linkwitzRileyHighpass, freq: 0.0, order: 2),
                        "LR HP freq=0 should be invalid")

        // bad: freq=25000 (>= Nyquist for 48kHz)
        XCTAssertFalse(validateConfig(type: .linkwitzRileyHighpass, freq: 25000.0, order: 2),
                        "LR HP freq=25000 should be invalid (>= Nyquist)")
    }

    /// Mirrors Rust: check_butterworth
    /// order=0 (bad), freq=0 (bad), freq=25000 (bad), order=5 (ok), order=6 (ok)
    func testCheckButterworth() {
        // ok: order=6, freq=1000
        XCTAssertTrue(validateConfig(type: .butterworthHighpass, freq: 1000.0, order: 6),
                       "BW HP order=6, freq=1000 should be valid")

        // ok: order=5 (odd is fine for Butterworth)
        XCTAssertTrue(validateConfig(type: .butterworthHighpass, freq: 1000.0, order: 5),
                       "BW HP order=5 should be valid")

        // bad: order=0
        XCTAssertFalse(validateConfig(type: .butterworthHighpass, freq: 1000.0, order: 0),
                        "BW HP order=0 should be invalid")

        // bad: freq=0
        XCTAssertFalse(validateConfig(type: .butterworthHighpass, freq: 0.0, order: 2),
                        "BW HP freq=0 should be invalid")

        // bad: freq=25000 (>= Nyquist for 48kHz)
        XCTAssertFalse(validateConfig(type: .butterworthHighpass, freq: 25000.0, order: 2),
                        "BW HP freq=25000 should be invalid (>= Nyquist)")
    }

    // MARK: - Tilt validation

    func testCheckTiltGainBounds() {
        // Tilt with gain within bounds should pass
        var params = FilterParameters()
        params.subtype = BiquadComboType.tilt.rawValue
        params.slope = 5.0
        let okConfig = FilterConfig(type: .biquadCombo, parameters: params)
        XCTAssertNoThrow(try FilterValidator.validate(okConfig, sampleRate: sampleRate))

        // gain = -100 should fail (must be > -100)
        var paramsLow = FilterParameters()
        paramsLow.subtype = BiquadComboType.tilt.rawValue
        paramsLow.slope = -100.0
        let badLow = FilterConfig(type: .biquadCombo, parameters: paramsLow)
        XCTAssertThrowsError(try FilterValidator.validate(badLow, sampleRate: sampleRate))

        // gain = 100 should fail (must be < 100)
        var paramsHigh = FilterParameters()
        paramsHigh.subtype = BiquadComboType.tilt.rawValue
        paramsHigh.slope = 100.0
        let badHigh = FilterConfig(type: .biquadCombo, parameters: paramsHigh)
        XCTAssertThrowsError(try FilterValidator.validate(badHigh, sampleRate: sampleRate))
    }

    // MARK: - FivePointPeq validation

    func testCheckFivePointPeqQBounds() {
        // Q <= 0 should fail
        var params = FilterParameters()
        params.subtype = BiquadComboType.fivePointPeq.rawValue
        params.fivePointParams = FivePointPeqParams(
            fLow: 100, gLow: 1, qLow: 0.0,  // bad: Q=0
            fMid1: 500, gMid1: 1, qMid1: 1,
            fMid2: 1000, gMid2: 1, qMid2: 1,
            fMid3: 3000, gMid3: 1, qMid3: 1,
            fHigh: 8000, gHigh: 1, qHigh: 1
        )
        let badConfig = FilterConfig(type: .biquadCombo, parameters: params)
        XCTAssertThrowsError(try FilterValidator.validate(badConfig, sampleRate: sampleRate))
    }

    func testCheckFivePointPeqFreqBounds() {
        // freq >= Nyquist should fail
        var params = FilterParameters()
        params.subtype = BiquadComboType.fivePointPeq.rawValue
        params.fivePointParams = FivePointPeqParams(
            fLow: 100, gLow: 1, qLow: 1,
            fMid1: 500, gMid1: 1, qMid1: 1,
            fMid2: 1000, gMid2: 1, qMid2: 1,
            fMid3: 3000, gMid3: 1, qMid3: 1,
            fHigh: 25000, gHigh: 1, qHigh: 1  // bad: >= 24000 Nyquist
        )
        let badConfig = FilterConfig(type: .biquadCombo, parameters: params)
        XCTAssertThrowsError(try FilterValidator.validate(badConfig, sampleRate: sampleRate))
    }

    // MARK: - GraphicEQ validation

    func testCheckGraphicEQFreqBounds() {
        // freqMin >= Nyquist should fail
        var params = FilterParameters()
        params.subtype = BiquadComboType.graphicEqualizer.rawValue
        params.freqMin = 25000.0
        params.freqMax = 26000.0
        params.gains = [0.0, 1.0]
        let badConfig = FilterConfig(type: .biquadCombo, parameters: params)
        XCTAssertThrowsError(try FilterValidator.validate(badConfig, sampleRate: sampleRate))

        // freqMin > freqMax should fail
        var params2 = FilterParameters()
        params2.subtype = BiquadComboType.graphicEqualizer.rawValue
        params2.freqMin = 5000.0
        params2.freqMax = 1000.0
        params2.gains = [0.0, 1.0]
        let badConfig2 = FilterConfig(type: .biquadCombo, parameters: params2)
        XCTAssertThrowsError(try FilterValidator.validate(badConfig2, sampleRate: sampleRate))
    }

    func testCheckGraphicEQGainBounds() {
        // gain > 40 should fail
        var params = FilterParameters()
        params.subtype = BiquadComboType.graphicEqualizer.rawValue
        params.freqMin = 20.0
        params.freqMax = 20000.0
        params.gains = [0.0, 41.0]
        let badConfig = FilterConfig(type: .biquadCombo, parameters: params)
        XCTAssertThrowsError(try FilterValidator.validate(badConfig, sampleRate: sampleRate))

        // gain < -40 should fail
        var params2 = FilterParameters()
        params2.subtype = BiquadComboType.graphicEqualizer.rawValue
        params2.freqMin = 20.0
        params2.freqMax = 20000.0
        params2.gains = [-41.0, 0.0]
        let badConfig2 = FilterConfig(type: .biquadCombo, parameters: params2)
        XCTAssertThrowsError(try FilterValidator.validate(badConfig2, sampleRate: sampleRate))
    }

    // MARK: - Behavioral tests

    func testButterworthLowpassAttenuation() throws {
        let filter = try makeFilter(type: .butterworthLowpass, freq: 1000.0, order: 2)
        let frames = 4096
        var highFreq = makeSine(freq: 10000.0, frames: frames)
        try filter.process(waveform: &highFreq)
        let peak = steadyStatePeak(highFreq)
        XCTAssertLessThan(peak, 0.02, "2nd-order BW LP should heavily attenuate 10kHz")
    }

    func testButterworthHighpassBehavior() throws {
        let freq = 5000.0
        let filter = try makeFilter(type: .butterworthHighpass, freq: freq, order: 4)
        let frames = 8192

        var lowFreq = makeSine(freq: 100.0, frames: frames)
        var highFreq = makeSine(freq: 15000.0, frames: frames)

        try filter.process(waveform: &lowFreq)
        let filter2 = try makeFilter(type: .butterworthHighpass, freq: freq, order: 4)
        try filter2.process(waveform: &highFreq)

        let lowPeak = steadyStatePeak(lowFreq)
        let highPeak = steadyStatePeak(highFreq)

        XCTAssertLessThan(lowPeak, 0.001, "BW HP should attenuate low frequencies")
        XCTAssertGreaterThan(highPeak, 0.9, "BW HP should pass high frequencies")
    }

    func testLinkwitzRileyHighpassBehavior() throws {
        let freq = 2000.0
        let filter = try makeFilter(type: .linkwitzRileyHighpass, freq: freq, order: 4)
        let frames = 8192

        var lowFreq = makeSine(freq: 100.0, frames: frames)
        var highFreq = makeSine(freq: 10000.0, frames: frames)

        try filter.process(waveform: &lowFreq)
        let filter2 = try makeFilter(type: .linkwitzRileyHighpass, freq: freq, order: 4)
        try filter2.process(waveform: &highFreq)

        let lowPeak = steadyStatePeak(lowFreq)
        let highPeak = steadyStatePeak(highFreq)

        XCTAssertLessThan(lowPeak, 0.01, "LR HP should attenuate sub-band frequencies")
        XCTAssertGreaterThan(highPeak, 0.8, "LR HP should pass frequencies well above cutoff")
    }

    func testLinkwitzRileyOddOrderFails() {
        var params = FilterParameters()
        params.subtype = BiquadComboType.linkwitzRileyLowpass.rawValue
        params.freq = 1000.0
        params.order = 3
        let config = FilterConfig(type: .biquadCombo, parameters: params)

        XCTAssertThrowsError(
            try BiquadComboFilter(name: "test_lr_odd", config: config, sampleRate: sampleRate),
            "Linkwitz-Riley with odd order should throw an error"
        )
    }

    func testGraphicEQ() throws {
        var params = FilterParameters()
        params.subtype = BiquadComboType.graphicEqualizer.rawValue
        params.gains = [0.0, 6.0, 0.0, -6.0, 0.0]
        params.freqMin = 20.0
        params.freqMax = 20000.0
        let config = FilterConfig(type: .biquadCombo, parameters: params)

        let filter = try BiquadComboFilter(name: "test_geq", config: config, sampleRate: sampleRate)
        var waveform = makeSine(freq: 1000.0, frames: 4096)
        let originalRMS = DSPOps.rms(waveform)
        try filter.process(waveform: &waveform)
        let processedRMS = DSPOps.rms(waveform)

        XCTAssertNotEqual(originalRMS, processedRMS, accuracy: 0.001,
                          "Graphic EQ with non-zero gains should modify the signal")
    }

    func testGraphicEQZeroGainBandsSkipped() throws {
        var params = FilterParameters()
        params.subtype = BiquadComboType.graphicEqualizer.rawValue
        params.gains = [0.0, 0.0, 0.0]
        params.freqMin = 20.0
        params.freqMax = 20000.0
        let config = FilterConfig(type: .biquadCombo, parameters: params)

        let filter = try BiquadComboFilter(name: "test_geq_zero", config: config, sampleRate: sampleRate)
        var waveform: [PrcFmt] = [1.0, 0.5, -0.5, -1.0]
        let original = waveform
        try filter.process(waveform: &waveform)

        for i in 0..<waveform.count {
            XCTAssertEqual(waveform[i], original[i], accuracy: 1e-10,
                           "All-zero gain EQ should be a pass-through")
        }
    }

    func testTiltEQ() throws {
        var params = FilterParameters()
        params.subtype = BiquadComboType.tilt.rawValue
        params.freq = 1000.0
        params.slope = 1.0
        let config = FilterConfig(type: .biquadCombo, parameters: params)

        let filter = try BiquadComboFilter(name: "test_tilt", config: config, sampleRate: sampleRate)
        var waveform = makeSine(freq: 100.0, frames: 4096)
        XCTAssertNoThrow(try filter.process(waveform: &waveform))
    }

    func testBiquadComboMissingTypeThrows() {
        var params = FilterParameters()
        params.freq = 1000.0
        params.order = 2
        let config = FilterConfig(type: .biquadCombo, parameters: params)

        XCTAssertThrowsError(
            try BiquadComboFilter(name: "test_no_type", config: config, sampleRate: sampleRate)
        ) { error in
            XCTAssertTrue(error is ConfigError)
        }
    }

    func testButterworthLowpassPassband() throws {
        let filter = try makeFilter(type: .butterworthLowpass, freq: 10000.0, order: 4)
        let frames = 8192
        var waveform = makeSine(freq: 100.0, frames: frames)
        try filter.process(waveform: &waveform)

        let peak = steadyStatePeak(waveform)
        XCTAssertGreaterThan(peak, 0.95,
                             "BW LP should pass frequencies well below cutoff")
    }
}
