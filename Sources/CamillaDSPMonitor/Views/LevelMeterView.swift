// LevelMeterView - VU-style level meters with peak and RMS

import SwiftUI

// MARK: - Dual Peak/RMS Level Meter

struct DualLevelMeterView: View {
    let label: String
    let peak: Double  // dB
    let rms: Double   // dB

    private func normalized(_ db: Double) -> Double {
        max(0, min(1, (db + 60) / 60))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let halfH = h / 2

                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))

                    // RMS bar (top half) — solid color
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [.green, .yellow, .orange, .red],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: w * normalized(rms), height: halfH - 1)
                        .offset(y: -(halfH / 2) + 0.5)

                    // Peak bar (bottom half) — slightly brighter
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [.green.opacity(0.7), .yellow.opacity(0.7), .orange.opacity(0.7), .red.opacity(0.7)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: w * normalized(peak), height: halfH - 1)
                        .offset(y: (halfH / 2) - 0.5)

                    // Divider line between RMS and Peak
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)

                    // Scale marks
                    ForEach([-48, -36, -24, -12, -6, -3, 0], id: \.self) { db in
                        let pos = max(0, min(1, (Double(db) + 60) / 60))
                        Rectangle()
                            .fill(Color.primary.opacity(0.2))
                            .frame(width: 1, height: db == 0 ? h : h * 0.5)
                            .offset(x: w * pos - w / 2)
                    }
                }
            }
            .frame(height: 18)

            // dB values: RMS on top, Peak below
            VStack(alignment: .trailing, spacing: 0) {
                Text(String(format: "%5.1f", rms))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(String(format: "%5.1f", peak))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Simple Level Meter (single bar, used where only peak is needed)

struct LevelMeterView: View {
    let label: String
    let level: Double // dB, range -100 to 0

    private var normalizedLevel: Double {
        max(0, min(1, (level + 60) / 60))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [.green, .yellow, .orange, .red],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * normalizedLevel)
                }
            }
            .frame(height: 14)

            Text(String(format: "%5.1f", level))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Compact Level Meter Bar

struct CompactLevelMeterBar: View {
    @EnvironmentObject var meters: MeterState
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "mic")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                CompactMeterBar(level: meters.capturePeak.left)
                CompactMeterBar(level: meters.capturePeak.right)
            }

            HStack(spacing: 6) {
                Image(systemName: "hifispeaker")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                CompactMeterBar(level: meters.playbackPeak.left)
                CompactMeterBar(level: meters.playbackPeak.right)
            }

            Spacer()

            if appState.isRunning {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text(appState.engineState.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CompactMeterBar: View {
    let level: Double

    private var normalized: Double {
        max(0, min(1, (level + 60) / 60))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 2)
                    .fill(level > -6 ? Color.orange : Color.green)
                    .frame(width: geo.size.width * normalized)
            }
        }
        .frame(width: 80, height: 6)
    }
}
