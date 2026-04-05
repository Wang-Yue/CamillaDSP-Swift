// EQYAMLMode - Raw YAML text editor for EQ presets

import SwiftUI

struct EQYAMLMode: View {
    @ObservedObject var preset: EQPreset
    @EnvironmentObject var appState: AppState
    @State private var yamlText: String = ""
    @State private var parseError: String?
    @State private var copyFeedback: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CamillaDSP YAML format — edit and Apply, or copy/paste from external tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    yamlText = preset.toYAML()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(yamlText, forType: .string)
                    copyFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copyFeedback = false }
                } label: {
                    Label(copyFeedback ? "Copied!" : "Copy YAML", systemImage: copyFeedback ? "checkmark" : "doc.on.doc")
                }
                Button("Refresh") {
                    yamlText = preset.toYAML()
                }
                Button("Apply") {
                    if let bands = EQPreset.fromYAML(yamlText) {
                        preset.bands = bands
                        preset.objectWillChange.send()
                        appState.saveEQPresets()
                        parseError = nil
                    } else {
                        parseError = "Failed to parse YAML — check format"
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if let error = parseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            TextEditor(text: $yamlText)
                .font(.system(.body, design: .monospaced))
                .padding(4)
        }
        .onAppear {
            yamlText = preset.toYAML()
        }
    }
}
