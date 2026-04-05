// EQPreset - Biquad EQ preset with multiple parametric bands
// Each preset can be edited via diagram, form, or raw YAML

import Foundation
import CamillaDSPLib

// MARK: - EQ Band

/// Biquad filter types commonly used in parametric EQ
enum EQBandType: String, CaseIterable, Codable, Identifiable {
    case peaking = "Peaking"
    case lowshelf = "Lowshelf"
    case highshelf = "Highshelf"
    case lowpass = "Lowpass"
    case highpass = "Highpass"
    case lowpassFO = "LowpassFO"
    case highpassFO = "HighpassFO"
    case lowshelfFO = "LowshelfFO"
    case highshelfFO = "HighshelfFO"
    case notch = "Notch"
    case bandpass = "Bandpass"
    case allpass = "Allpass"
    case allpassFO = "AllpassFO"

    var id: String { rawValue }

    /// Whether this band type uses the gain parameter
    var hasGain: Bool {
        switch self {
        case .peaking, .lowshelf, .highshelf, .lowshelfFO, .highshelfFO:
            return true
        default:
            return false
        }
    }

    /// Whether this band type uses the Q parameter
    var hasQ: Bool {
        switch self {
        case .lowpassFO, .highpassFO, .lowshelfFO, .highshelfFO, .allpassFO:
            return false
        default:
            return true
        }
    }

    /// Maps to CamillaDSPLib BiquadType
    var biquadType: BiquadType {
        BiquadType(rawValue: rawValue) ?? .peaking
    }
}

/// A single EQ band in a preset
class EQBand: ObservableObject, Identifiable, Codable {
    let id: UUID
    @Published var type: EQBandType
    @Published var freq: Double       // Hz (20–20000)
    @Published var gain: Double       // dB (-20 to +20)
    @Published var q: Double          // Q factor (0.1–30)
    @Published var isEnabled: Bool

    init(type: EQBandType = .peaking, freq: Double = 1000, gain: Double = 0, q: Double = 0.707, isEnabled: Bool = true) {
        self.id = UUID()
        self.type = type
        self.freq = freq
        self.gain = gain
        self.q = q
        self.isEnabled = isEnabled
    }

    // Codable
    enum CodingKeys: String, CodingKey {
        case id, type, freq, gain, q, isEnabled
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        type = try c.decode(EQBandType.self, forKey: .type)
        freq = try c.decode(Double.self, forKey: .freq)
        gain = try c.decode(Double.self, forKey: .gain)
        q = try c.decode(Double.self, forKey: .q)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(freq, forKey: .freq)
        try c.encode(gain, forKey: .gain)
        try c.encode(q, forKey: .q)
        try c.encode(isEnabled, forKey: .isEnabled)
    }

    /// Build CamillaDSP FilterParameters
    func toFilterParameters() -> FilterParameters {
        var p = FilterParameters()
        p.subtype = type.rawValue
        p.freq = freq
        if type.hasGain { p.gain = gain }
        if type.hasQ { p.q = q }
        return p
    }

    /// Compute biquad coefficients for this band
    func coefficients(sampleRate: Int) -> BiquadCoefficients? {
        try? BiquadFilter.computeCoefficients(toFilterParameters(), sampleRate: sampleRate)
    }

    /// Compute frequency response (gain in dB) at a given frequency
    func response(atFreq f: Double, sampleRate: Int) -> Double {
        guard isEnabled, let coeffs = coefficients(sampleRate: sampleRate) else { return 0 }
        return Self.gainDB(coeffs: coeffs, f: f, fs: Double(sampleRate))
    }

    /// Biquad frequency response from transfer function H(z) evaluated on unit circle
    static func gainDB(coeffs: BiquadCoefficients, f: Double, fs: Double) -> Double {
        let w = 2.0 * Double.pi * f / fs
        let cosW = cos(w), sinW = sin(w)
        let cos2W = cos(2.0 * w), sin2W = sin(2.0 * w)

        let numRe = coeffs.b0 + coeffs.b1 * cosW + coeffs.b2 * cos2W
        let numIm = -coeffs.b1 * sinW - coeffs.b2 * sin2W
        let denRe = 1.0 + coeffs.a1 * cosW + coeffs.a2 * cos2W
        let denIm = -coeffs.a1 * sinW - coeffs.a2 * sin2W

        let numMagSq = numRe * numRe + numIm * numIm
        let denMagSq = denRe * denRe + denIm * denIm
        guard denMagSq > 0 else { return 0 }
        return 10.0 * log10(numMagSq / denMagSq)
    }
}

// MARK: - EQ Preset

class EQPreset: ObservableObject, Identifiable, Codable {
    let id: UUID
    @Published var name: String
    @Published var bands: [EQBand]

    init(name: String, bands: [EQBand] = []) {
        self.id = UUID()
        self.name = name
        self.bands = bands
    }

    // Codable
    enum CodingKeys: String, CodingKey {
        case id, name, bands
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bands = try c.decode([EQBand].self, forKey: .bands)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(bands, forKey: .bands)
    }

    func addBand(_ band: EQBand? = nil) {
        let b = band ?? EQBand(type: .peaking, freq: 1000, gain: 0, q: 1.0)
        bands.append(b)
    }

    func removeBand(at index: Int) {
        guard bands.indices.contains(index) else { return }
        bands.remove(at: index)
    }

    /// Combined frequency response of all enabled bands at a given frequency
    func combinedResponse(atFreq f: Double, sampleRate: Int) -> Double {
        bands.filter(\.isEnabled).reduce(0.0) { $0 + $1.response(atFreq: f, sampleRate: sampleRate) }
    }

    /// Export as CamillaDSP YAML filter definitions
    func toYAML() -> String {
        var lines: [String] = []
        lines.append("filters:")
        for (i, band) in bands.enumerated() {
            let key = "\(name.lowercased().replacingOccurrences(of: " ", with: "_"))_band\(i + 1)"
            lines.append("  \(key):")
            lines.append("    type: Biquad")
            lines.append("    parameters:")
            lines.append("      type: \(band.type.rawValue)")
            lines.append("      freq: \(band.freq)")
            if band.type.hasGain {
                lines.append("      gain: \(band.gain)")
            }
            if band.type.hasQ {
                lines.append("      q: \(band.q)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Import from CamillaDSP YAML filter definitions
    static func fromYAML(_ yaml: String) -> [EQBand]? {
        // Simple parser for the format we export
        var bands: [EQBand] = []
        var currentType: EQBandType?
        var currentFreq: Double?
        var currentGain: Double?
        var currentQ: Double?

        func flushBand() {
            if let type = currentType, let freq = currentFreq {
                bands.append(EQBand(type: type, freq: freq, gain: currentGain ?? 0, q: currentQ ?? 0.707))
            }
            currentType = nil; currentFreq = nil; currentGain = nil; currentQ = nil
        }

        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("type: Biquad") {
                // This is the filter type line, next block is parameters
                continue
            }
            if trimmed.hasPrefix("type: ") && !trimmed.contains("Biquad") {
                flushBand()
                let val = trimmed.replacingOccurrences(of: "type: ", with: "")
                currentType = EQBandType(rawValue: val)
            } else if trimmed.hasPrefix("freq: ") {
                currentFreq = Double(trimmed.replacingOccurrences(of: "freq: ", with: ""))
            } else if trimmed.hasPrefix("gain: ") {
                currentGain = Double(trimmed.replacingOccurrences(of: "gain: ", with: ""))
            } else if trimmed.hasPrefix("q: ") {
                currentQ = Double(trimmed.replacingOccurrences(of: "q: ", with: ""))
            }
        }
        flushBand()
        return bands.isEmpty ? nil : bands
    }
}
