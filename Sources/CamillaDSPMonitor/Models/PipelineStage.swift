// PipelineStage - Configurable DSP pipeline stages matching CamillaDSP-Monitor YAML files exactly
// Each stage maps 1:1 to a section in the CamillaDSP-Monitor project.

import Foundation
import CamillaDSPLib

// MARK: - Stage Type (fixed set matching CamillaDSP-Monitor sections 0-7)

enum StageType: String, CaseIterable, Codable, Identifiable {
    case balance = "Balance"
    case width = "Width"
    case msProc = "M/S Proc"
    case phaseInvert = "Phase Invert"
    case crossfeed = "Crossfeed"
    case eq = "EQ"
    case loudness = "Loudness"
    case emphasis = "Emphasis"
    case dcProtection = "DC Protection"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .balance: return "dial.low"
        case .width: return "arrow.left.and.right"
        case .msProc: return "waveform.path"
        case .phaseInvert: return "waveform.path.ecg"
        case .crossfeed: return "headphones"
        case .eq: return "slider.horizontal.3"
        case .loudness: return "ear"
        case .emphasis: return "waveform"
        case .dcProtection: return "bolt.shield"
        }
    }
}

// MARK: - Option enums (matching YAML file options exactly)

enum PhaseInvertMode: String, CaseIterable, Identifiable {
    case off = "Off"      // 2-0
    case left = "Left"    // 2-1
    case right = "Right"  // 2-2
    case both = "Both"    // 2-3
    var id: String { rawValue }
}

enum CrossfeedLevel: String, CaseIterable, Identifiable {
    case off = "Off"  // 3-0
    case l1 = "L1"    // 3-1  lightest
    case l2 = "L2"    // 3-2
    case l3 = "L3"    // 3-3
    case l4 = "L4"    // 3-4
    case l5 = "L5"    // 3-5  strongest
    var id: String { rawValue }
}

enum EQChannelMode: String, CaseIterable, Identifiable {
    case same = "Same L/R"       // Same preset for both channels (headphones)
    case separate = "Separate L/R" // Different presets per channel (speakers)
    var id: String { rawValue }
}

enum EmphasisMode: String, CaseIterable, Identifiable {
    case off = "Off"              // 6-0
    case deEmphasis = "De-Emphasis" // 6-1
    case preEmphasis = "Pre-Emphasis" // 6-2
    var id: String { rawValue }
}

// MARK: - Pipeline Stage

class PipelineStage: ObservableObject, Identifiable {
    let id = UUID()
    let type: StageType
    let name: String
    @Published var isEnabled: Bool

    // Sub-options (only meaningful when isEnabled == true)
    @Published var balancePosition: Double = 0.0  // -1.0 = full left, 0.0 = center, +1.0 = full right
    @Published var widthAmount: Double = 1.0  // -1.0=swapped, 0=mono, 1.0=stereo, 2.0=extra-wide
    @Published var phaseInvertMode: PhaseInvertMode = .both
    @Published var crossfeedLevel: CrossfeedLevel = .l1
    @Published var eqChannelMode: EQChannelMode = .same
    @Published var eqPreampGain: Double = -6.0  // dB, applied before EQ to prevent clipping
    @Published var eqPresetID: UUID?         // preset for both channels (same mode)
    @Published var eqLeftPresetID: UUID?      // left channel preset (separate mode)
    @Published var eqRightPresetID: UUID?     // right channel preset (separate mode)
    @Published var emphasisMode: EmphasisMode = .deEmphasis

    // Crossfeed: two input values (Fc and Db) compute all filter params
    // See https://github.com/Wang-Yue/camilladsp-crossfeed/
    @Published var cxCustomEnabled: Bool = false  // false = use L1-L5 preset, true = use custom Fc/Db
    @Published var cxFc: Double = 650.0           // Lowpass cutoff frequency (Hz)
    @Published var cxDb: Double = 13.5            // Level in dB (positive, higher = stronger crossfeed)

    // Loudness parameters (defaults match setting.yml)
    @Published var loudnessReference: Double = -25.0
    @Published var loudnessHighBoost: Double = 7.0
    @Published var loudnessLowBoost: Double = 7.0

    init(type: StageType, name: String, isEnabled: Bool = false) {
        self.type = type
        self.name = name
        self.isEnabled = isEnabled
    }

    /// Whether this stage actually produces pipeline steps
    var isActive: Bool {
        guard isEnabled else { return false }
        if type == .width && widthAmount == 1.0 { return false }
        if type == .balance && balancePosition == 0.0 { return false }
        return true
    }
}
