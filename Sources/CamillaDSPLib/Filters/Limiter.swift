// CamillaDSP-Swift: Limiter filter - hard or soft clipping
// Matches Rust: soft clip uses cubic polynomial (not tanh)

import Foundation

public final class LimiterFilter: Filter {
    public let name: String
    private var clipLimit: PrcFmt  // linear threshold
    private var softClip: Bool

    public init(name: String, config: FilterConfig) {
        self.name = name
        let params = config.parameters
        let clipDB = params.clipLimit ?? 0.0
        self.clipLimit = PrcFmt.fromDB(clipDB)
        self.softClip = params.softClip ?? false
    }

    public func process(waveform: inout [PrcFmt]) throws {
        if softClip {
            // Cubic soft clipping (matches Rust: scaled = clamp(val/limit, -1.5, 1.5); val = (scaled - scaled^3/6.75) * limit)
            for i in 0..<waveform.count {
                var scaled = waveform[i] / clipLimit
                scaled = max(-1.5, min(1.5, scaled))
                waveform[i] = (scaled - scaled * scaled * scaled / 6.75) * clipLimit
            }
        } else {
            // Hard clipping
            for i in 0..<waveform.count {
                waveform[i] = max(-clipLimit, min(clipLimit, waveform[i]))
            }
        }
    }

    public func updateParameters(_ config: FilterConfig) {
        let params = config.parameters
        clipLimit = PrcFmt.fromDB(params.clipLimit ?? 0.0)
        softClip = params.softClip ?? false
    }
}
