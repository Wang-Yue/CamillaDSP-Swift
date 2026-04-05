// PipelineStage+Builders - Build CamillaDSP config components (matches YAML files exactly)

import Foundation
import CamillaDSPLib

extension PipelineStage {

    func buildFilters() -> [String: FilterConfig] {
        guard isActive else { return [:] }

        switch type {
        case .balance, .width, .msProc:
            return [:]  // These use mixers only

        case .phaseInvert:
            // invert: { type: Gain, parameters: { gain: 0.0, inverted: true } }
            var p = FilterParameters()
            p.gain = 0.0
            p.inverted = true
            return ["invert": FilterConfig(type: .gain, parameters: p)]

        case .crossfeed:
            return crossfeedFilters()

        case .eq:
            return [:]  // EQ filters built via buildEQFilters(presets:)

        case .loudness:
            var p = FilterParameters()
            p.fader = .main
            p.referenceLevel = loudnessReference
            p.highBoost = loudnessHighBoost
            p.lowBoost = loudnessLowBoost
            return ["loudness": FilterConfig(type: .loudness, parameters: p)]

        case .emphasis:
            switch emphasisMode {
            case .off: return [:]
            case .deEmphasis:
                // deemphasis: { type: Biquad, parameters: { type: Highshelf, freq: 5200, gain: -9.5, q: 0.5 } }
                var p = FilterParameters()
                p.subtype = BiquadType.highshelf.rawValue
                p.freq = 5200.0
                p.gain = -9.5
                p.q = 0.5
                return ["deemphasis": FilterConfig(type: .biquad, parameters: p)]
            case .preEmphasis:
                // preemphasis: { type: Biquad, parameters: { type: Highshelf, freq: 5200, gain: 9.5, q: 0.5 } }
                var p = FilterParameters()
                p.subtype = BiquadType.highshelf.rawValue
                p.freq = 5200.0
                p.gain = 9.5
                p.q = 0.5
                return ["preemphasis": FilterConfig(type: .biquad, parameters: p)]
            }

        case .dcProtection:
            // dcp: { type: Biquad, parameters: { type: HighpassFO, freq: 7 } }
            var p = FilterParameters()
            p.subtype = BiquadType.highpassFO.rawValue
            p.freq = 7.0
            return ["dcp": FilterConfig(type: .biquad, parameters: p)]
        }
    }

    func buildMixers() -> [String: MixerConfig] {
        guard isActive else { return [:] }

        switch type {
        case .balance:
            // Balance: linear pan law. position -1..+1
            // Left gain = 1 - max(0, position), Right gain = 1 + min(0, position)
            // Convert to dB for the mixer
            let leftLin = 1.0 - max(0.0, balancePosition)   // 1.0 at center/left, 0.0 at full right
            let rightLin = 1.0 + min(0.0, balancePosition)  // 1.0 at center/right, 0.0 at full left
            let leftDB = leftLin > 0 ? 20.0 * log10(leftLin) : -100.0
            let rightDB = rightLin > 0 ? 20.0 * log10(rightLin) : -100.0
            return ["balance": MixerConfig(channelsIn: 2, channelsOut: 2, mapping: [
                MixerMapping(dest: 0, sources: [MixerSource(channel: 0, gain: leftDB)]),
                MixerMapping(dest: 1, sources: [MixerSource(channel: 1, gain: rightDB)]),
            ])]

        case .width:
            // Mid/Side width control:
            // L' = Mid + w*Side = (1+w)/2 * L + (1-w)/2 * R
            // R' = Mid - w*Side = (1-w)/2 * L + (1+w)/2 * R
            // w=1.0: passthrough, w=0: mono, w=-1: swapped, w=2: extra-wide
            let w = widthAmount
            let ll = (1.0 + w) / 2.0  // L→L gain (linear)
            let lr = (1.0 - w) / 2.0  // R→L gain (linear)
            let llDB = ll > 0 ? 20.0 * log10(ll) : -100.0
            let lrDB = lr > 0 ? 20.0 * log10(abs(lr)) : -100.0
            let lrInverted = lr < 0  // when w > 1, cross-feed is negative
            return ["width": MixerConfig(channelsIn: 2, channelsOut: 2, mapping: [
                MixerMapping(dest: 0, sources: [
                    MixerSource(channel: 0, gain: llDB),
                    MixerSource(channel: 1, gain: lrDB, inverted: lrInverted),
                ]),
                MixerMapping(dest: 1, sources: [
                    MixerSource(channel: 0, gain: lrDB, inverted: lrInverted),
                    MixerSource(channel: 1, gain: llDB),
                ]),
            ])]

        case .msProc:
            // M/S encode: Mid = L+R, Side = L-R (inverted R on dest 1)
            return ["msproc": MixerConfig(channelsIn: 2, channelsOut: 2, mapping: [
                MixerMapping(dest: 0, sources: [
                    MixerSource(channel: 0, gain: -6.02),
                    MixerSource(channel: 1, gain: -6.02),
                ]),
                MixerMapping(dest: 1, sources: [
                    MixerSource(channel: 0, gain: -6.02),
                    MixerSource(channel: 1, gain: -6.02, inverted: true),
                ]),
            ])]

        case .crossfeed:
            guard crossfeedLevel != .off else { return [:] }
            // 2to4: fan out L/R to 4 channels (direct + cross pairs)
            // 4to2: fold back with summation
            return [
                "2to4": MixerConfig(channelsIn: 2, channelsOut: 4, mapping: [
                    MixerMapping(dest: 0, sources: [MixerSource(channel: 0, gain: 0.0)]),
                    MixerMapping(dest: 1, sources: [MixerSource(channel: 0, gain: 0.0)]),
                    MixerMapping(dest: 2, sources: [MixerSource(channel: 1, gain: 0.0)]),
                    MixerMapping(dest: 3, sources: [MixerSource(channel: 1, gain: 0.0)]),
                ]),
                "4to2": MixerConfig(channelsIn: 4, channelsOut: 2, mapping: [
                    MixerMapping(dest: 0, sources: [
                        MixerSource(channel: 0, gain: 0.0),
                        MixerSource(channel: 2, gain: 0.0),
                    ]),
                    MixerMapping(dest: 1, sources: [
                        MixerSource(channel: 1, gain: 0.0),
                        MixerSource(channel: 3, gain: 0.0),
                    ]),
                ]),
            ]

        default:
            return [:]
        }
    }

    func buildPipelineSteps() -> [PipelineStep] {
        guard isActive else { return [] }

        switch type {
        case .balance:
            return [PipelineStep(type: .mixer, name: "balance")]

        case .width:
            return [PipelineStep(type: .mixer, name: "width")]

        case .msProc:
            return [PipelineStep(type: .mixer, name: "msproc")]

        case .phaseInvert:
            switch phaseInvertMode {
            case .off: return []
            case .left:
                return [PipelineStep(type: .filter, channels: [0], names: ["invert"])]
            case .right:
                return [PipelineStep(type: .filter, channels: [1], names: ["invert"])]
            case .both:
                return [PipelineStep(type: .filter, channels: [0, 1], names: ["invert"])]
            }

        case .crossfeed:
            guard crossfeedLevel != .off else { return [] }
            let n = String(crossfeedLevel.rawValue.last!)
            return [
                PipelineStep(type: .mixer, name: "2to4"),
                PipelineStep(type: .filter, channels: [0, 3], names: ["cx\(n)_hi"]),
                PipelineStep(type: .filter, channels: [1, 2], names: ["cx\(n)_lo", "cx\(n)_lo_gain"]),
                PipelineStep(type: .mixer, name: "4to2"),
            ]

        case .eq:
            return []  // EQ steps built via buildEQPipelineSteps(presets:)

        case .loudness:
            return [PipelineStep(type: .filter, channels: [0, 1], names: ["loudness"])]

        case .emphasis:
            switch emphasisMode {
            case .off: return []
            case .deEmphasis:
                return [PipelineStep(type: .filter, channels: [0, 1], names: ["deemphasis"])]
            case .preEmphasis:
                return [PipelineStep(type: .filter, channels: [0, 1], names: ["preemphasis"])]
            }

        case .dcProtection:
            return [PipelineStep(type: .filter, channels: [0, 1], names: ["dcp"])]
        }
    }

    // MARK: - EQ from presets

    func buildEQFilters(presets: [EQPreset]) -> [String: FilterConfig] {
        guard isActive, type == .eq else { return [:] }

        var filters: [String: FilterConfig] = [:]

        // Preamp gain filter to prevent clipping
        var preampParams = FilterParameters()
        preampParams.gain = eqPreampGain
        preampParams.inverted = false
        filters["eq_preamp"] = FilterConfig(type: .gain, parameters: preampParams)

        func addPresetFilters(_ preset: EQPreset, prefix: String) {
            for (i, band) in preset.bands.enumerated() where band.isEnabled {
                filters["\(prefix)_\(i + 1)"] = FilterConfig(type: .biquad, parameters: band.toFilterParameters())
            }
        }

        switch eqChannelMode {
        case .same:
            if let id = eqPresetID, let preset = presets.first(where: { $0.id == id }) {
                addPresetFilters(preset, prefix: "eq")
            }
        case .separate:
            if let id = eqLeftPresetID, let preset = presets.first(where: { $0.id == id }) {
                addPresetFilters(preset, prefix: "eq_l")
            }
            if let id = eqRightPresetID, let preset = presets.first(where: { $0.id == id }) {
                addPresetFilters(preset, prefix: "eq_r")
            }
        }
        return filters
    }

    func buildEQPipelineSteps(presets: [EQPreset]) -> [PipelineStep] {
        guard isActive, type == .eq else { return [] }

        // Preamp first to prevent clipping
        var steps = [PipelineStep(type: .filter, channels: [0, 1], names: ["eq_preamp"])]

        switch eqChannelMode {
        case .same:
            if let id = eqPresetID, let preset = presets.first(where: { $0.id == id }) {
                let names = preset.bands.enumerated().compactMap { i, b in b.isEnabled ? "eq_\(i + 1)" : nil }
                if !names.isEmpty { steps.append(PipelineStep(type: .filter, channels: [0, 1], names: names)) }
            }
        case .separate:
            if let id = eqLeftPresetID, let preset = presets.first(where: { $0.id == id }) {
                let names = preset.bands.enumerated().compactMap { i, b in b.isEnabled ? "eq_l_\(i + 1)" : nil }
                if !names.isEmpty { steps.append(PipelineStep(type: .filter, channels: [0], names: names)) }
            }
            if let id = eqRightPresetID, let preset = presets.first(where: { $0.id == id }) {
                let names = preset.bands.enumerated().compactMap { i, b in b.isEnabled ? "eq_r_\(i + 1)" : nil }
                if !names.isEmpty { steps.append(PipelineStep(type: .filter, channels: [1], names: names)) }
            }
        }
        return steps
    }
}
