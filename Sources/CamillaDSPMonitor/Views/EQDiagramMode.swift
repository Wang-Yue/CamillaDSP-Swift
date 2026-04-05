// EQDiagramMode - Interactive frequency response diagram with draggable band handles

import SwiftUI
import CamillaDSPLib

// MARK: - Diagram Mode

struct EQDiagramMode: View {
    @ObservedObject var preset: EQPreset
    @Binding var selectedBandID: UUID?
    let sampleRate: Int

    var body: some View {
        VStack(spacing: 0) {
            // Frequency response diagram
            EQFrequencyResponseView(
                preset: preset,
                selectedBandID: $selectedBandID,
                sampleRate: sampleRate
            )
            .frame(minHeight: 300)
            .padding()

            Divider()

            // Band list below diagram
            EQBandListBar(preset: preset, selectedBandID: $selectedBandID)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
    }
}

// MARK: - Frequency Response View (Interactive Diagram)

struct EQFrequencyResponseView: View {
    @ObservedObject var preset: EQPreset
    @EnvironmentObject var appState: AppState
    @Binding var selectedBandID: UUID?
    let sampleRate: Int

    // Band colors
    static let bandColors: [Color] = [
        .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink,
        .mint, .teal, .indigo, .brown,
    ]

    private func colorFor(_ band: EQBand) -> Color {
        guard let idx = preset.bands.firstIndex(where: { $0.id == band.id }) else { return .gray }
        return Self.bandColors[idx % Self.bandColors.count]
    }

    // Display range
    private let minFreq = 20.0
    private let maxFreq = 20000.0
    private let minDB = -24.0
    private let maxDB = 24.0
    private let numPoints = 200

    private func freqToX(_ f: Double, width: Double) -> Double {
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        return (log10(max(f, minFreq)) - logMin) / (logMax - logMin) * width
    }

    private func xToFreq(_ x: Double, width: Double) -> Double {
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let logF = logMin + (x / width) * (logMax - logMin)
        return pow(10, logF)
    }

    private func dbToY(_ db: Double, height: Double) -> Double {
        let clamped = max(minDB, min(maxDB, db))
        return height * (1.0 - (clamped - minDB) / (maxDB - minDB))
    }

    private func yToDB(_ y: Double, height: Double) -> Double {
        let ratio = 1.0 - y / height
        return minDB + ratio * (maxDB - minDB)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))

                // Grid
                drawGrid(w: w, h: h)

                // Individual band curves (colored)
                ForEach(preset.bands) { band in
                    let color = colorFor(band)
                    bandCurve(band: band, w: w, h: h)
                        .stroke(
                            band.id == selectedBandID ? color : color.opacity(0.35),
                            lineWidth: band.id == selectedBandID ? 2 : 1
                        )
                }

                // Combined response curve
                combinedCurve(w: w, h: h)
                    .stroke(Color.accentColor, lineWidth: 2.5)

                // Draggable band handles
                ForEach(preset.bands) { band in
                    bandHandle(band: band, w: w, h: h)
                }
            }
        }
    }

    // MARK: - Grid

    private func drawGrid(w: Double, h: Double) -> some View {
        ZStack {
            // Horizontal grid lines (dB)
            ForEach([-18, -12, -6, 0, 6, 12, 18], id: \.self) { db in
                let y = dbToY(Double(db), height: h)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
                .stroke(db == 0 ? Color.primary.opacity(0.2) : Color.primary.opacity(0.06), lineWidth: db == 0 ? 1 : 0.5)

                Text("\(db) dB")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .position(x: 28, y: y - 8)
            }

            // Vertical grid lines (frequency)
            ForEach([20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000], id: \.self) { freq in
                let x = freqToX(Double(freq), width: w)
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                }
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)

                Text(formatFreq(freq))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .position(x: x, y: h - 8)
            }
        }
    }

    private func formatFreq(_ f: Int) -> String {
        if f >= 1000 { return "\(f / 1000)k" }
        return "\(f)"
    }

    // MARK: - Curves

    private func bandCurve(band: EQBand, w: Double, h: Double) -> Path {
        Path { path in
            guard band.isEnabled else { return }
            for i in 0...numPoints {
                let x = w * Double(i) / Double(numPoints)
                let f = xToFreq(x, width: w)
                let db = band.response(atFreq: f, sampleRate: sampleRate)
                let y = dbToY(db, height: h)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    private func combinedCurve(w: Double, h: Double) -> Path {
        Path { path in
            for i in 0...numPoints {
                let x = w * Double(i) / Double(numPoints)
                let f = xToFreq(x, width: w)
                let db = preset.combinedResponse(atFreq: f, sampleRate: sampleRate)
                let y = dbToY(db, height: h)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    // MARK: - Draggable Handles

    private func bandHandle(band: EQBand, w: Double, h: Double) -> some View {
        let x = freqToX(band.freq, width: w)
        let gain = band.type.hasGain ? band.gain : 0
        let y = dbToY(gain, height: h)
        let isSelected = band.id == selectedBandID

        let color = colorFor(band)
        return Circle()
            .fill(color)
            .frame(width: isSelected ? 14 : 10, height: isSelected ? 14 : 10)
            .overlay(
                Circle().stroke(Color.white, lineWidth: isSelected ? 2.5 : 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 2)
            .position(x: x, y: y)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        selectedBandID = band.id
                        let newFreq = xToFreq(value.location.x, width: w)
                        band.freq = max(minFreq, min(maxFreq, newFreq))
                        if band.type.hasGain {
                            let newDB = yToDB(value.location.y, height: h)
                            band.gain = max(-20, min(20, (newDB * 2).rounded() / 2))
                        }
                        // Trigger re-render of curves during drag
                        band.objectWillChange.send()
                        preset.objectWillChange.send()
                    }
                    .onEnded { _ in
                        appState.applyConfig()  // ensure final position is applied
                        appState.saveEQPresets()
                    }
            )
            .onTapGesture {
                selectedBandID = band.id
            }
    }
}

// MARK: - Band List Bar (below diagram)

struct EQBandListBar: View {
    @ObservedObject var preset: EQPreset
    @Binding var selectedBandID: UUID?

    var body: some View {
        HStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(preset.bands.enumerated()), id: \.element.id) { i, band in
                        let color = EQFrequencyResponseView.bandColors[i % EQFrequencyResponseView.bandColors.count]
                        EQBandChip(band: band, index: i + 1, isSelected: band.id == selectedBandID, color: color)
                            .onTapGesture { selectedBandID = band.id }
                    }
                }
            }

            Spacer()

            Button {
                preset.addBand()
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)

            if let id = selectedBandID, let idx = preset.bands.firstIndex(where: { $0.id == id }) {
                Button {
                    preset.removeBand(at: idx)
                    selectedBandID = nil
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct EQBandChip: View {
    @ObservedObject var band: EQBand
    let index: Int
    let isSelected: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text("#\(index) \(band.type.rawValue)")
                    .font(.system(size: 9, weight: isSelected ? .bold : .regular))
                Text(String(format: "%.0f Hz", band.freq))
                    .font(.system(size: 8, design: .monospaced))
                if band.type.hasGain {
                    Text(String(format: "%+.1f dB", band.gain))
                        .font(.system(size: 8, design: .monospaced))
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? color.opacity(0.15) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? color : Color.clear, lineWidth: 1)
        )
        .foregroundStyle(band.isEnabled ? .primary : .tertiary)
    }
}
