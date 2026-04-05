// EQPresetDetailView - Biquad EQ preset editor with three modes:
// 1) Interactive frequency response diagram with draggable bands
// 2) Form-based editing with pickers/sliders/text fields
// 3) Raw YAML text editor

import SwiftUI
import CamillaDSPLib

// MARK: - Edit Mode

enum EQEditMode: String, CaseIterable {
    case diagram = "Diagram"
    case form = "Form"
    case yaml = "YAML"

    var icon: String {
        switch self {
        case .diagram: return "waveform.path.ecg"
        case .form: return "slider.horizontal.3"
        case .yaml: return "doc.plaintext"
        }
    }
}

// MARK: - Main Detail View

struct EQPresetDetailView: View {
    @ObservedObject var preset: EQPreset
    @EnvironmentObject var appState: AppState
    @State private var editMode: EQEditMode = .diagram
    @State private var selectedBandID: UUID?
    @State private var lastApplyTime: Date = .distantPast

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                TextField("Preset Name", text: $preset.name)
                    .font(.title2.bold())
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .onSubmit { NSApp.keyWindow?.makeFirstResponder(nil) }
                    .onChange(of: preset.name) { _, _ in appState.saveEQPresets() }
                Spacer()
                Picker("", selection: $editMode) {
                    ForEach(EQEditMode.allCases, id: \.rawValue) { mode in
                        Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding()

            Divider()

            // Content based on edit mode
            switch editMode {
            case .diagram:
                EQDiagramMode(preset: preset, selectedBandID: $selectedBandID, sampleRate: appState.sampleRate)
            case .form:
                EQFormMode(preset: preset, selectedBandID: $selectedBandID)
            case .yaml:
                EQYAMLMode(preset: preset)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: preset.bands.count) { _, _ in appState.saveEQPresets() }
        .onReceive(preset.objectWillChange) { _ in
            // Throttle live config updates to ~5Hz to avoid excessive CPU
            let now = Date()
            if now.timeIntervalSince(lastApplyTime) >= 0.2 {
                lastApplyTime = now
                appState.applyConfig()
            }
        }
    }
}
