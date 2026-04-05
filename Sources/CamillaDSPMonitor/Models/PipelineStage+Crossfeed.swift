// PipelineStage+Crossfeed - Crossfeed filter definitions and computation
// From https://github.com/Wang-Yue/camilladsp-crossfeed/

import Foundation
import CamillaDSPLib

extension PipelineStage {

    /// L1-L5 presets: (Fc in Hz, Db as positive number)
    static let crossfeedPresets: [CrossfeedLevel: (fc: Double, db: Double)] = [
        .l1: (650, 13.5),   // Just a touch
        .l2: (650, 9.5),    // Jan Meier emulation
        .l3: (700, 6.0),    // Chu Moy emulation
        .l4: (700, 4.5),    // 30° 3 meter emulation
        .l5: (700, 3.0),    // Even stronger
    ]

    /// Compute crossfeed filter parameters from Fc (Hz) and Db (positive dB level).
    static func computeCrossfeed(fc: Double, db: Double) -> (hiFreq: Double, hiGain: Double, hiQ: Double, loFreq: Double, loGain: Double) {
        let gd = -5.0 * db / 6.0 - 3.0            // Lowpass gain (dB)
        let adH = db / 6.0 - 3.0                    // High shelf gain (dB)
        let aH = pow(10.0, adH / 20.0)              // Linear
        let gH = 1.0 - aH                           // Complementary
        let gdH = 20.0 * log10(max(gH, 1e-10))      // Back to dB

        // High shelf center frequency
        let fcH = fc * pow(2.0, (gd - gdH) / 12.0) / pow(10.0, -adH / 80.0 / 0.5)

        return (hiFreq: fcH, hiGain: adH, hiQ: 0.5, loFreq: fc, loGain: gd)
    }

    /// Get the active crossfeed parameters (either from preset or custom Fc/Db)
    var activeCrossfeedParams: (hiFreq: Double, hiGain: Double, hiQ: Double, loFreq: Double, loGain: Double) {
        if cxCustomEnabled {
            return Self.computeCrossfeed(fc: cxFc, db: cxDb)
        } else if let preset = Self.crossfeedPresets[crossfeedLevel] {
            return Self.computeCrossfeed(fc: preset.fc, db: preset.db)
        } else {
            return Self.computeCrossfeed(fc: 700, db: 6)
        }
    }

    func crossfeedFilters() -> [String: FilterConfig] {
        let n = String(crossfeedLevel.rawValue.last!)
        let cx = activeCrossfeedParams

        var hiP = FilterParameters()
        hiP.subtype = BiquadType.lowshelf.rawValue
        hiP.freq = cx.hiFreq
        hiP.gain = cx.hiGain
        hiP.q = cx.hiQ

        var loP = FilterParameters()
        loP.subtype = BiquadType.lowpassFO.rawValue
        loP.freq = cx.loFreq

        var gP = FilterParameters()
        gP.gain = cx.loGain
        gP.inverted = false

        return [
            "cx\(n)_hi": FilterConfig(type: .biquad, parameters: hiP),
            "cx\(n)_lo": FilterConfig(type: .biquad, parameters: loP),
            "cx\(n)_lo_gain": FilterConfig(type: .gain, parameters: gP),
        ]
    }
}
