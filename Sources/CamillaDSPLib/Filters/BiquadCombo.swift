// CamillaDSP-Swift: BiquadCombo - cascaded biquad sections for higher-order filters

import Foundation

public final class BiquadComboFilter: Filter {
    public let name: String
    private var sections: [BiquadFilter]
    private let sampleRate: Int

    public init(name: String, config: FilterConfig, sampleRate: Int) throws {
        self.name = name
        self.sampleRate = sampleRate
        self.sections = try BiquadComboFilter.buildSections(name: name, params: config.parameters, sampleRate: sampleRate)
    }

    public func process(waveform: inout [PrcFmt]) throws {
        for section in sections {
            try section.process(waveform: &waveform)
        }
    }

    public func updateParameters(_ config: FilterConfig) {
        if let newSections = try? BiquadComboFilter.buildSections(name: name, params: config.parameters, sampleRate: sampleRate) {
            sections = newSections
        }
    }

    private static func buildSections(name: String, params: FilterParameters, sampleRate: Int) throws -> [BiquadFilter] {
        guard let comboType = params.comboType else {
            throw ConfigError.invalidFilter("BiquadCombo missing 'type'")
        }

        let freq = params.freq ?? 1000.0
        let order = params.order ?? 4
        let fs = PrcFmt(sampleRate)

        switch comboType {
        case .butterworthLowpass:
            return try butterworthSections(name: name, freq: freq, order: order, fs: fs, sampleRate: sampleRate, highpass: false)

        case .butterworthHighpass:
            return try butterworthSections(name: name, freq: freq, order: order, fs: fs, sampleRate: sampleRate, highpass: true)

        case .linkwitzRileyLowpass:
            guard order % 2 == 0 else {
                throw ConfigError.invalidFilter("Linkwitz-Riley order must be even")
            }
            let qValues = linkwitzRileyQ(order: order)
            return try makeSectionsFromQ(name: name, freq: freq, qValues: qValues, sampleRate: sampleRate, highpass: false)

        case .linkwitzRileyHighpass:
            guard order % 2 == 0 else {
                throw ConfigError.invalidFilter("Linkwitz-Riley order must be even")
            }
            let qValues = linkwitzRileyQ(order: order)
            return try makeSectionsFromQ(name: name, freq: freq, qValues: qValues, sampleRate: sampleRate, highpass: true)

        case .tilt:
            let slope = params.slope ?? 0.0
            return try buildTiltEQ(name: name, freq: freq, slope: slope, fs: fs, sampleRate: sampleRate)

        case .graphicEqualizer:
            let gains = params.gains ?? []
            let freqMin = params.freqMin ?? 20.0
            let freqMax = params.freqMax ?? 20000.0
            return try buildGraphicEQ(name: name, gains: gains, freqMin: freqMin, freqMax: freqMax, sampleRate: sampleRate)

        case .fivePointPeq:
            return try buildFivePointPEQ(name: name, params: params, sampleRate: sampleRate)
        }
    }

    // MARK: - Butterworth

    /// Compute Butterworth Q values for a given order.
    /// Returns Q > 0 for second-order sections, -1.0 for first-order sections (odd order).
    /// Exposed as internal for testing (mirrors Rust's butterworth_q).
    static func butterworthQ(order: Int) -> [PrcFmt] {
        var qValues: [PrcFmt] = []
        for k in 0..<(order / 2) {
            let angle = PrcFmt.pi / PrcFmt(order) * (PrcFmt(k) + 0.5)
            qValues.append(1.0 / (2.0 * sin(angle)))
        }
        if order % 2 == 1 {
            qValues.append(-1.0)  // marker for first-order section
        }
        return qValues
    }

    /// Compute Linkwitz-Riley Q values: double the BW(order/2) poles,
    /// merging paired FO sections into a Q=0.5 second-order section.
    /// Exposed as internal for testing (mirrors Rust's linkwitzriley_q).
    static func linkwitzRileyQ(order: Int) -> [PrcFmt] {
        var qTemp = butterworthQ(order: order / 2)
        if order % 4 > 0 {
            // Odd half-order: pop the FO section, double the SOS sections, add Q=0.5
            qTemp.removeLast()  // remove the -1.0 FO marker
            var qValues = qTemp
            qValues.append(contentsOf: qTemp)
            qValues.append(0.5)
            return qValues
        } else {
            // Even half-order: just double all sections
            var qValues = qTemp
            qValues.append(contentsOf: qTemp)
            return qValues
        }
    }

    /// Create biquad sections from Q values. Q < 0 → first-order, Q > 0 → second-order.
    private static func makeSectionsFromQ(
        name: String, freq: PrcFmt, qValues: [PrcFmt], sampleRate: Int, highpass: Bool
    ) throws -> [BiquadFilter] {
        var sections: [BiquadFilter] = []
        for (i, q) in qValues.enumerated() {
            var p = FilterParameters()
            p.freq = freq
            if q >= 0 {
                p.q = q
                p.subtype = highpass ? BiquadType.highpass.rawValue : BiquadType.lowpass.rawValue
            } else {
                p.subtype = highpass ? BiquadType.highpassFO.rawValue : BiquadType.lowpassFO.rawValue
            }
            let coeffs = try BiquadFilter.computeCoefficients(p, sampleRate: sampleRate)
            sections.append(BiquadFilter(name: "\(name)_lr\(i)", coefficients: coeffs, sampleRate: sampleRate))
        }
        return sections
    }

    private static func butterworthSections(
        name: String, freq: PrcFmt, order: Int, fs: PrcFmt, sampleRate: Int, highpass: Bool
    ) throws -> [BiquadFilter] {
        var sections: [BiquadFilter] = []
        let n = order

        // For each second-order section
        let numSOS = n / 2
        for k in 0..<numSOS {
            // Butterworth pole angle (matches Rust: pi/order * (k + 0.5))
            let angle = PrcFmt.pi / PrcFmt(n) * (PrcFmt(k) + 0.5)
            let q = 1.0 / (2.0 * sin(angle))

            var filterParams = FilterParameters()
            filterParams.freq = freq
            filterParams.q = q
            filterParams.subtype = highpass ? BiquadType.highpass.rawValue : BiquadType.lowpass.rawValue

            let coeffs = try BiquadFilter.computeCoefficients(filterParams, sampleRate: sampleRate)
            sections.append(BiquadFilter(name: "\(name)_bw\(k)", coefficients: coeffs, sampleRate: sampleRate))
        }

        // Odd order: add first-order section
        if n % 2 == 1 {
            var filterParams = FilterParameters()
            filterParams.freq = freq
            filterParams.subtype = highpass ? BiquadType.highpassFO.rawValue : BiquadType.lowpassFO.rawValue

            let coeffs = try BiquadFilter.computeCoefficients(filterParams, sampleRate: sampleRate)
            sections.append(BiquadFilter(name: "\(name)_bwfo", coefficients: coeffs, sampleRate: sampleRate))
        }

        return sections
    }

    // MARK: - Tilt EQ

    private static func buildTiltEQ(
        name: String, freq: PrcFmt, slope: PrcFmt, fs: PrcFmt, sampleRate: Int
    ) throws -> [BiquadFilter] {
        // Matches Rust: Lowshelf at 110 Hz, Highshelf at 3500 Hz, Q=0.35
        // gain_low = -gain/2, gain_high = gain/2  (where gain = slope from config)
        let gainLow = -slope / 2.0
        let gainHigh = slope / 2.0

        var lsParams = FilterParameters()
        lsParams.freq = 110.0
        lsParams.gain = gainLow
        lsParams.q = 0.35
        lsParams.subtype = BiquadType.lowshelf.rawValue

        var hsParams = FilterParameters()
        hsParams.freq = 3500.0
        hsParams.gain = gainHigh
        hsParams.q = 0.35
        hsParams.subtype = BiquadType.highshelf.rawValue

        let lsCoeffs = try BiquadFilter.computeCoefficients(lsParams, sampleRate: sampleRate)
        let hsCoeffs = try BiquadFilter.computeCoefficients(hsParams, sampleRate: sampleRate)

        return [
            BiquadFilter(name: "\(name)_ls", coefficients: lsCoeffs, sampleRate: sampleRate),
            BiquadFilter(name: "\(name)_hs", coefficients: hsCoeffs, sampleRate: sampleRate),
        ]
    }

    // MARK: - Graphic EQ

    private static func buildGraphicEQ(
        name: String, gains: [Double], freqMin: Double, freqMax: Double, sampleRate: Int
    ) throws -> [BiquadFilter] {
        let nbands = gains.count
        guard nbands > 0 else { return [] }

        let logMin = log10(freqMin)
        let logMax = log10(freqMax)
        let logStep = (logMax - logMin) / PrcFmt(nbands)
        let bw = logStep / log10(2.0) // bandwidth in octaves

        var sections: [BiquadFilter] = []
        for i in 0..<nbands {
            if abs(gains[i]) <= 0.001 { continue } // skip near-zero gain bands (matches Rust threshold)
            let logFreq = logMin + logStep * (PrcFmt(i) + 0.5)
            let freq = pow(10.0, logFreq)

            var p = FilterParameters()
            p.freq = freq
            p.gain = gains[i]
            p.bandwidth = bw
            p.subtype = BiquadType.peaking.rawValue

            let coeffs = try BiquadFilter.computeCoefficients(p, sampleRate: sampleRate)
            sections.append(BiquadFilter(name: "\(name)_geq\(i)", coefficients: coeffs, sampleRate: sampleRate))
        }
        return sections
    }

    // MARK: - Five Point PEQ

    private static func buildFivePointPEQ(
        name: String, params: FilterParameters, sampleRate: Int
    ) throws -> [BiquadFilter] {
        guard let fp = params.fivePointParams else {
            throw ConfigError.invalidFilter("FivePointPeq missing parameters")
        }

        var sections: [BiquadFilter] = []

        // Low shelf
        if abs(fp.gLow) > 0.01 {
            var p = FilterParameters()
            p.freq = fp.fLow; p.gain = fp.gLow; p.q = fp.qLow; p.subtype = BiquadType.lowshelf.rawValue
            sections.append(BiquadFilter(name: "\(name)_ls", coefficients: try BiquadFilter.computeCoefficients(p, sampleRate: sampleRate), sampleRate: sampleRate))
        }

        // Three peaking bands
        let mids: [(f: Double, g: Double, q: Double, suffix: String)] = [
            (fp.fMid1, fp.gMid1, fp.qMid1, "m1"),
            (fp.fMid2, fp.gMid2, fp.qMid2, "m2"),
            (fp.fMid3, fp.gMid3, fp.qMid3, "m3"),
        ]
        for mid in mids {
            if abs(mid.g) > 0.01 {
                var p = FilterParameters()
                p.freq = mid.f; p.gain = mid.g; p.q = mid.q; p.subtype = BiquadType.peaking.rawValue
                sections.append(BiquadFilter(name: "\(name)_\(mid.suffix)", coefficients: try BiquadFilter.computeCoefficients(p, sampleRate: sampleRate), sampleRate: sampleRate))
            }
        }

        // High shelf
        if abs(fp.gHigh) > 0.01 {
            var p = FilterParameters()
            p.freq = fp.fHigh; p.gain = fp.gHigh; p.q = fp.qHigh; p.subtype = BiquadType.highshelf.rawValue
            sections.append(BiquadFilter(name: "\(name)_hs", coefficients: try BiquadFilter.computeCoefficients(p, sampleRate: sampleRate), sampleRate: sampleRate))
        }

        return sections
    }
}
