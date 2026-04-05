// EQFormMode - Form-based EQ band editing with pickers, sliders, and text fields

import SwiftUI

struct EQFormMode: View {
    @ObservedObject var preset: EQPreset
    @Binding var selectedBandID: UUID?
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Band table
            List {
                ForEach(Array(preset.bands.enumerated()), id: \.element.id) { i, band in
                    EQBandFormRow(band: band, index: i + 1, isSelected: band.id == selectedBandID)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedBandID = band.id }
                        .listRowBackground(band.id == selectedBandID ? Color.accentColor.opacity(0.1) : Color.clear)
                }
                .onDelete { indices in
                    for i in indices.sorted().reversed() {
                        preset.removeBand(at: i)
                    }
                    appState.saveEQPresets()
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Button {
                    preset.addBand()
                    appState.saveEQPresets()
                } label: {
                    Label("Add Band", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .padding()

                Spacer()
            }
        }
    }
}

struct EQBandFormRow: View {
    @ObservedObject var band: EQBand
    @EnvironmentObject var appState: AppState
    let index: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $band.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Text("#\(index)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            Picker("", selection: $band.type) {
                ForEach(EQBandType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 110)

            HStack(spacing: 4) {
                Text("Freq")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", value: $band.freq, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("Hz")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if band.type.hasGain {
                HStack(spacing: 4) {
                    Text("Gain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", value: $band.gain, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)
                    Text("dB")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if band.type.hasQ {
                HStack(spacing: 4) {
                    Text("Q")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", value: $band.q, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .onReceive(band.objectWillChange) { _ in
            appState.saveEQPresets()
        }
    }
}
