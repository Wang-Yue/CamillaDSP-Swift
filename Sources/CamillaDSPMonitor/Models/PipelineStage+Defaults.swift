// PipelineStage+Defaults - Default stages and persistence (Snapshot)

import Foundation

extension PipelineStage {

    // MARK: - Default stages (fixed set)

    static func defaultStages() -> [PipelineStage] {
        [
            PipelineStage(type: .balance, name: "Balance"),
            PipelineStage(type: .width, name: "Width"),
            PipelineStage(type: .msProc, name: "M/S Proc"),
            PipelineStage(type: .phaseInvert, name: "Phase Invert"),
            PipelineStage(type: .crossfeed, name: "Crossfeed"),
            PipelineStage(type: .eq, name: "EQ"),
            PipelineStage(type: .loudness, name: "Loudness"),
            PipelineStage(type: .emphasis, name: "Emphasis"),
            PipelineStage(type: .dcProtection, name: "DC Protection"),
        ]
    }

    // MARK: - Persistence

    /// Codable snapshot of all mutable stage state
    struct Snapshot: Codable {
        let stageType: String
        var isEnabled: Bool
        var balancePosition: Double
        var widthAmount: Double
        var phaseInvertMode: String
        var crossfeedLevel: String
        var eqChannelMode: String
        var eqPreampGain: Double
        var eqPresetID: String?
        var eqLeftPresetID: String?
        var eqRightPresetID: String?
        var emphasisMode: String
        var cxCustomEnabled: Bool
        var cxFc: Double
        var cxDb: Double
        var loudnessReference: Double
        var loudnessHighBoost: Double
        var loudnessLowBoost: Double
    }

    func toSnapshot() -> Snapshot {
        Snapshot(
            stageType: type.rawValue,
            isEnabled: isEnabled,
            balancePosition: balancePosition,
            widthAmount: widthAmount,
            phaseInvertMode: phaseInvertMode.rawValue,
            crossfeedLevel: crossfeedLevel.rawValue,
            eqChannelMode: eqChannelMode.rawValue,
            eqPreampGain: eqPreampGain,
            eqPresetID: eqPresetID?.uuidString,
            eqLeftPresetID: eqLeftPresetID?.uuidString,
            eqRightPresetID: eqRightPresetID?.uuidString,
            emphasisMode: emphasisMode.rawValue,
            cxCustomEnabled: cxCustomEnabled,
            cxFc: cxFc,
            cxDb: cxDb,
            loudnessReference: loudnessReference,
            loudnessHighBoost: loudnessHighBoost,
            loudnessLowBoost: loudnessLowBoost
        )
    }

    func restore(from s: Snapshot) {
        isEnabled = s.isEnabled
        balancePosition = s.balancePosition
        widthAmount = s.widthAmount
        if let v = PhaseInvertMode(rawValue: s.phaseInvertMode) { phaseInvertMode = v }
        if let v = CrossfeedLevel(rawValue: s.crossfeedLevel) { crossfeedLevel = v }
        if let v = EQChannelMode(rawValue: s.eqChannelMode) { eqChannelMode = v }
        eqPreampGain = s.eqPreampGain
        eqPresetID = s.eqPresetID.flatMap { UUID(uuidString: $0) }
        eqLeftPresetID = s.eqLeftPresetID.flatMap { UUID(uuidString: $0) }
        eqRightPresetID = s.eqRightPresetID.flatMap { UUID(uuidString: $0) }
        if let v = EmphasisMode(rawValue: s.emphasisMode) { emphasisMode = v }
        cxCustomEnabled = s.cxCustomEnabled
        cxFc = s.cxFc
        cxDb = s.cxDb
        loudnessReference = s.loudnessReference
        loudnessHighBoost = s.loudnessHighBoost
        loudnessLowBoost = s.loudnessLowBoost
    }
}
