// StageDetailView - Configuration UI for each pipeline stage
// The sidebar toggle controls enabled/disabled. The detail view only shows
// the active options (no "Off" state).

import SwiftUI
import CamillaDSPLib

struct StageDetailView: View {
    let stageIndex: Int
    @EnvironmentObject var appState: AppState

    var body: some View {
        if stageIndex < appState.stages.count {
            StageDetailContent(stage: appState.stages[stageIndex])
        } else {
            Text("Stage not found")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

private struct StageDetailContent: View {
    @ObservedObject var stage: PipelineStage
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: stage.type.icon)
                        .font(.title2)
                        .foregroundStyle(stage.isEnabled ? Color.accentColor : .secondary)
                    Text(stage.name)
                        .font(.title2.bold())
                    Spacer()
                    Toggle("Enabled", isOn: $stage.isEnabled)
                        .onChange(of: stage.isEnabled) { _, _ in appState.applyConfig() }
                }

                Divider()

                Group {
                    switch stage.type {
                    case .balance: BalanceOptions(stage: stage)
                    case .width: WidthOptions(stage: stage)
                    case .msProc: MSProcDescription()
                    case .phaseInvert: PhaseInvertOptions(stage: stage)
                    case .crossfeed: CrossfeedOptions(stage: stage)
                    case .eq: EQOptions(stage: stage)
                    case .loudness: LoudnessOptions(stage: stage)
                    case .emphasis: EmphasisOptions(stage: stage)
                    case .dcProtection: DCProtectionDescription()
                    }
                }
                .disabled(!stage.isEnabled)
                .opacity(stage.isEnabled ? 1.0 : 0.5)

                Spacer()
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Balance

struct BalanceOptions: View {
    @ObservedObject var stage: PipelineStage
    @EnvironmentObject var appState: AppState

    var body: some View {
        GroupBox("Balance") {
            VStack(spacing: 12) {
                HStack {
                    Text("L")
                        .font(.system(.body, design: .monospaced).bold())
                        .foregroundStyle(.secondary)
                    Slider(value: $stage.balancePosition, in: -1.0...1.0, step: 0.01)
                        .onChange(of: stage.balancePosition) { _, _ in appState.applyConfig() }
                    Text("R")
                        .font(.system(.body, design: .monospaced).bold())
                        .foregroundStyle(.secondary)
                }

                HStack {
                    let leftPct = Int((1.0 - max(0, stage.balancePosition)) * 100)
                    let rightPct = Int((1.0 + min(0, stage.balancePosition)) * 100)
                    Text("Left: \(leftPct)%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Center") {
                        stage.balancePosition = 0.0
                        appState.applyConfig()
                    }
                    .controlSize(.small)
                    Text("Right: \(rightPct)%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Section 0: Width

struct WidthOptions: View {
    @ObservedObject var stage: PipelineStage
    @EnvironmentObject var appState: AppState

    private var percentage: Int { Int(stage.widthAmount * 100) }

    var body: some View {
        GroupBox("Stereo Width") {
            VStack(spacing: 12) {
                HStack {
                    Text("Swapped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $stage.widthAmount, in: -1.0...2.0, step: 0.01)
                        .onChange(of: stage.widthAmount) { _, _ in appState.applyConfig() }
                    Text("Wide")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("\(percentage)%")
                        .font(.system(.title3, design: .monospaced).bold())
                    Spacer()
                    HStack(spacing: 12) {
                        Button("-100%") { stage.widthAmount = -1.0; appState.applyConfig() }
                            .controlSize(.small)
                        Button("Mono") { stage.widthAmount = 0.0; appState.applyConfig() }
                            .controlSize(.small)
                        Button("100%") { stage.widthAmount = 1.0; appState.applyConfig() }
                            .controlSize(.small)
                    }
                }

                Text(widthDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var widthDescription: String {
        if stage.widthAmount == 1.0 { return "Normal stereo (passthrough)" }
        if stage.widthAmount == 0.0 { return "Mono — L and R summed equally" }
        if stage.widthAmount == -1.0 { return "Fully swapped — L and R exchanged" }
        if stage.widthAmount < 0 { return "Partially swapped with crossfeed" }
        if stage.widthAmount < 1.0 { return "Narrowed stereo image" }
        return "Enhanced stereo — wider than original"
    }
}

// MARK: - Section 1: M/S Proc (no sub-options — toggle is the control)

struct MSProcDescription: View {
    var body: some View {
        GroupBox("Mid/Side Processing") {
            Text("Encodes stereo to Mid (L+R) and Side (L-R) signals at -6.02 dB")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Section 2: Phase Invert (no "Off" — Left/Right/Both only)

struct PhaseInvertOptions: View {
    @ObservedObject var stage: PipelineStage
    @EnvironmentObject var appState: AppState

    var body: some View {
        GroupBox("Phase Inversion") {
            Picker("Channel", selection: $stage.phaseInvertMode) {
                Text("Left").tag(PhaseInvertMode.left)
                Text("Right").tag(PhaseInvertMode.right)
                Text("Both").tag(PhaseInvertMode.both)
            }
            .pickerStyle(.segmented)
            .onChange(of: stage.phaseInvertMode) { _, _ in appState.applyConfig() }

            Text(phaseDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    var phaseDescription: String {
        switch stage.phaseInvertMode {
        case .off: return ""
        case .left: return "Invert left channel only"
        case .right: return "Invert right channel only"
        case .both: return "Invert both channels (polarity flip)"
        }
    }
}

// MARK: - Section 3: Crossfeed (no "Off" — L1 through L5 only)

struct CrossfeedOptions: View {
    @ObservedObject var stage: PipelineStage
    @EnvironmentObject var appState: AppState

    var body: some View {
        // Preset picker (used when custom is off)
        GroupBox("Preset") {
            Picker("Level", selection: $stage.crossfeedLevel) {
                Text("L1").tag(CrossfeedLevel.l1)
                Text("L2").tag(CrossfeedLevel.l2)
                Text("L3").tag(CrossfeedLevel.l3)
                Text("L4").tag(CrossfeedLevel.l4)
                Text("L5").tag(CrossfeedLevel.l5)
            }
            .pickerStyle(.segmented)
            .disabled(stage.cxCustomEnabled)
            .onChange(of: stage.crossfeedLevel) { _, _ in appState.applyConfig() }

            if let preset = PipelineStage.crossfeedPresets[stage.crossfeedLevel] {
                Text("Fc = \(String(format: "%.0f", preset.fc)) Hz, Level = \(String(format: "%.1f", preset.db)) dB — \(presetDescription)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .opacity(stage.cxCustomEnabled ? 0.5 : 1.0)

        // Custom toggle + sliders
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Custom Parameters", isOn: $stage.cxCustomEnabled)
                    .onChange(of: stage.cxCustomEnabled) { _, enabled in
                        if enabled {
                            // Initialize custom values from current preset
                            if let preset = PipelineStage.crossfeedPresets[stage.crossfeedLevel] {
                                stage.cxFc = preset.fc
                                stage.cxDb = preset.db
                            }
                        }
                        appState.applyConfig()
                    }

                if stage.cxCustomEnabled {
                    HStack {
                        Text("Fc (Hz)")
                            .frame(width: 90, alignment: .leading)
                        Slider(value: $stage.cxFc, in: 300...1200, step: 10)
                            .onChange(of: stage.cxFc) { _, _ in appState.applyConfig() }
                        Text(String(format: "%.0f", stage.cxFc))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 55, alignment: .trailing)
                    }

                    HStack {
                        Text("Level (dB)")
                            .frame(width: 90, alignment: .leading)
                        Slider(value: $stage.cxDb, in: 1...20, step: 0.5)
                            .onChange(of: stage.cxDb) { _, _ in appState.applyConfig() }
                        Text(String(format: "%.1f", stage.cxDb))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 55, alignment: .trailing)
                    }
                }
            }
        }

        // Computed parameters display
        let cx = stage.activeCrossfeedParams
        GroupBox("Computed Filter Parameters") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Lowshelf").foregroundStyle(.secondary)
                    Text(String(format: "%.1f Hz", cx.hiFreq)).font(.system(.body, design: .monospaced))
                    Text(String(format: "%.2f dB", cx.hiGain)).font(.system(.body, design: .monospaced))
                    Text("Q 0.5").font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Lowpass").foregroundStyle(.secondary)
                    Text(String(format: "%.0f Hz", cx.loFreq)).font(.system(.body, design: .monospaced))
                    Text("1st order").font(.caption).foregroundStyle(.tertiary)
                    Text("")
                }
                GridRow {
                    Text("Cross gain").foregroundStyle(.secondary)
                    Text(String(format: "%.2f dB", cx.loGain)).font(.system(.body, design: .monospaced))
                    Text("")
                    Text("")
                }
            }
            .font(.caption)
        }
    }

    var presetDescription: String {
        switch stage.crossfeedLevel {
        case .l1: return "Just a touch"
        case .l2: return "Jan Meier"
        case .l3: return "Chu Moy"
        case .l4: return "30° 3m"
        case .l5: return "Strong"
        case .off: return ""
        }
    }
}

// MARK: - Section 4: EQ (preset-based)

struct EQOptions: View {
    @ObservedObject var stage: PipelineStage
    @EnvironmentObject var appState: AppState

    var body: some View {
        GroupBox("Channel Mode") {
            Picker("Mode", selection: $stage.eqChannelMode) {
                ForEach(EQChannelMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: stage.eqChannelMode) { _, _ in appState.applyConfig() }

            Text(stage.eqChannelMode == .same
                 ? "Same EQ preset applied to both channels (typical for headphones)"
                 : "Separate EQ presets for left and right channels (typical for speakers)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }

        GroupBox("Preamp") {
            HStack {
                Text("Gain")
                    .frame(width: 40, alignment: .leading)
                Slider(value: $stage.eqPreampGain, in: -20...6, step: 0.5)
                    .onChange(of: stage.eqPreampGain) { _, _ in appState.applyConfig() }
                Text(String(format: "%+.1f dB", stage.eqPreampGain))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 65, alignment: .trailing)
            }
            Text("Reduces level before EQ to prevent clipping from boost filters")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if appState.eqPresets.isEmpty {
            GroupBox("No Presets") {
                Text("Add EQ presets in the \"EQ Presets\" section of the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            switch stage.eqChannelMode {
            case .same:
                GroupBox("EQ Preset") {
                    EQPresetPicker(selectedID: $stage.eqPresetID, label: "Preset", presets: appState.eqPresets)
                        .onChange(of: stage.eqPresetID) { _, _ in appState.applyConfig() }
                }

            case .separate:
                GroupBox("Left Channel") {
                    EQPresetPicker(selectedID: $stage.eqLeftPresetID, label: "Left Preset", presets: appState.eqPresets)
                        .onChange(of: stage.eqLeftPresetID) { _, _ in appState.applyConfig() }
                }
                GroupBox("Right Channel") {
                    EQPresetPicker(selectedID: $stage.eqRightPresetID, label: "Right Preset", presets: appState.eqPresets)
                        .onChange(of: stage.eqRightPresetID) { _, _ in appState.applyConfig() }
                }
            }
        }

        // Show selected preset band summary
        if let preset = activePreset {
            GroupBox("\(preset.name) — \(preset.bands.count) bands") {
                EQPresetBandSummary(preset: preset, sampleRate: appState.sampleRate)
            }
        }
    }

    private var activePreset: EQPreset? {
        switch stage.eqChannelMode {
        case .same:
            return appState.eqPresets.first { $0.id == stage.eqPresetID }
        case .separate:
            return appState.eqPresets.first { $0.id == stage.eqLeftPresetID }
        }
    }
}

struct EQPresetPicker: View {
    @Binding var selectedID: UUID?
    let label: String
    let presets: [EQPreset]

    var body: some View {
        Picker(label, selection: $selectedID) {
            Text("None").tag(nil as UUID?)
            ForEach(presets) { preset in
                Text(preset.name).tag(preset.id as UUID?)
            }
        }
    }
}

struct EQPresetBandSummary: View {
    @ObservedObject var preset: EQPreset
    let sampleRate: Int

    var body: some View {
        EQFrequencyResponseView(
            preset: preset,
            selectedBandID: .constant(nil),
            sampleRate: sampleRate
        )
        .frame(height: 150)
        .allowsHitTesting(false)
    }
}

// MARK: - Section 5: Loudness

struct LoudnessOptions: View {
    @ObservedObject var stage: PipelineStage
    @EnvironmentObject var appState: AppState

    var body: some View {
        GroupBox("Loudness Compensation") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Reference Level")
                        .frame(width: 110, alignment: .leading)
                    Slider(value: $stage.loudnessReference, in: -50...20, step: 1)
                        .onChange(of: stage.loudnessReference) { _, _ in appState.applyConfig() }
                    Text(String(format: "%.0f dB", stage.loudnessReference))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 55, alignment: .trailing)
                }

                HStack {
                    Text("Low Boost")
                        .frame(width: 110, alignment: .leading)
                    Slider(value: $stage.loudnessLowBoost, in: 0...15, step: 0.5)
                        .onChange(of: stage.loudnessLowBoost) { _, _ in appState.applyConfig() }
                    Text(String(format: "%.1f dB", stage.loudnessLowBoost))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 55, alignment: .trailing)
                }

                HStack {
                    Text("High Boost")
                        .frame(width: 110, alignment: .leading)
                    Slider(value: $stage.loudnessHighBoost, in: 0...15, step: 0.5)
                        .onChange(of: stage.loudnessHighBoost) { _, _ in appState.applyConfig() }
                    Text(String(format: "%.1f dB", stage.loudnessHighBoost))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 55, alignment: .trailing)
                }

                HStack {
                    Button("Reset to Default") {
                        stage.loudnessReference = -25.0
                        stage.loudnessHighBoost = 7.0
                        stage.loudnessLowBoost = 7.0
                        appState.applyConfig()
                    }
                    .controlSize(.small)

                    Spacer()

                    Text("Default: ref -25 dB, low 7 dB, high 7 dB")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Section 6: Emphasis (no "Off" — De-Emphasis/Pre-Emphasis only)

struct EmphasisOptions: View {
    @ObservedObject var stage: PipelineStage
    @EnvironmentObject var appState: AppState

    var body: some View {
        GroupBox("Emphasis") {
            Picker("Mode", selection: $stage.emphasisMode) {
                Text("De-Emphasis").tag(EmphasisMode.deEmphasis)
                Text("Pre-Emphasis").tag(EmphasisMode.preEmphasis)
            }
            .pickerStyle(.segmented)
            .onChange(of: stage.emphasisMode) { _, _ in appState.applyConfig() }

            Text(emphasisDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    var emphasisDescription: String {
        switch stage.emphasisMode {
        case .off: return ""
        case .deEmphasis: return "Highshelf at 5200 Hz, -9.5 dB, Q 0.5 (undo pre-emphasis)"
        case .preEmphasis: return "Highshelf at 5200 Hz, +9.5 dB, Q 0.5 (boost highs)"
        }
    }
}

// MARK: - Section 7: DC Protection (no sub-options — toggle is the control)

struct DCProtectionDescription: View {
    var body: some View {
        GroupBox("DC Protection") {
            Text("First-order highpass at 7 Hz — removes DC offset and subsonic content")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Resampler Detail View

struct ResamplerDetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title2)
                        .foregroundStyle(appState.resamplerEnabled ? Color.accentColor : .secondary)
                    Text("Sample Rate Converter")
                        .font(.title2.bold())
                    Spacer()
                    Toggle("Enabled", isOn: $appState.resamplerEnabled)
                }

                Divider()

                Group {
                    if appState.resamplerEnabled {
                        GroupBox("Resampler Type") {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Type", selection: $appState.resamplerType) {
                                    Text("Async Sinc (highest quality)").tag(ResamplerType.asyncSinc.rawValue)
                                    Text("Async Polynomial (lower latency)").tag(ResamplerType.asyncPoly.rawValue)
                                    Text("Synchronous (fixed ratio)").tag(ResamplerType.synchronous.rawValue)
                                }
                                .labelsHidden()

                                if appState.resamplerType == ResamplerType.asyncSinc.rawValue {
                                    Picker("Quality Profile", selection: $appState.resamplerProfile) {
                                        Text("Very Fast").tag(ResamplerProfile.veryFast.rawValue)
                                        Text("Fast").tag(ResamplerProfile.fast.rawValue)
                                        Text("Balanced").tag(ResamplerProfile.balanced.rawValue)
                                        Text("Accurate").tag(ResamplerProfile.accurate.rawValue)
                                    }
                                    .pickerStyle(.segmented)
                                }
                            }
                        }

                        GroupBox("Sample Rates") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Capture")
                                        .frame(width: 80, alignment: .leading)
                                        .foregroundStyle(.secondary)
                                    Text(formatRate(appState.captureSampleRate))
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                }
                                HStack {
                                    Text("Playback")
                                        .frame(width: 80, alignment: .leading)
                                        .foregroundStyle(.secondary)
                                    Text(formatRate(appState.playbackSampleRate))
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                }

                                let ratio = Double(appState.playbackSampleRate) / Double(appState.captureSampleRate)
                                Text(String(format: "Conversion ratio: %.4f", ratio))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Text("Resamples audio between capture and playback sample rates. Configure sample rates in the Devices page.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("When disabled, capture and playback use the same sample rate. Enable to convert between different rates.")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!appState.resamplerEnabled)
                .opacity(appState.resamplerEnabled ? 1.0 : 0.5)

                Spacer()
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func formatRate(_ rate: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return (formatter.string(from: NSNumber(value: rate)) ?? "\(rate)") + " Hz"
    }
}
