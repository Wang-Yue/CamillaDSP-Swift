// CamillaDSP-Swift: DiffEq filter - general difference equation (arbitrary-order IIR)

import Foundation

public final class DiffEqFilter: Filter {
    public let name: String
    private var aCoeffs: [PrcFmt]  // denominator (feedback), a[0] = 1.0
    private var bCoeffs: [PrcFmt]  // numerator (feedforward)
    private var xHistory: [PrcFmt] // input history
    private var yHistory: [PrcFmt] // output history

    public init(name: String, config: FilterConfig) {
        self.name = name
        let params = config.parameters

        self.aCoeffs = params.a ?? [1.0]
        self.bCoeffs = params.b ?? [1.0]

        // Normalize by a[0]
        if let a0 = aCoeffs.first, a0 != 0 && a0 != 1.0 {
            let scale = 1.0 / a0
            aCoeffs = aCoeffs.map { $0 * scale }
            bCoeffs = bCoeffs.map { $0 * scale }
        }

        self.xHistory = [PrcFmt](repeating: 0, count: bCoeffs.count)
        self.yHistory = [PrcFmt](repeating: 0, count: aCoeffs.count)
    }

    public func process(waveform: inout [PrcFmt]) throws {
        let nb = bCoeffs.count
        let na = aCoeffs.count

        for i in 0..<waveform.count {
            // Shift input history
            for j in stride(from: nb - 1, through: 1, by: -1) {
                xHistory[j] = xHistory[j - 1]
            }
            xHistory[0] = waveform[i]

            // Compute output: y[n] = sum(b[k]*x[n-k]) - sum(a[k]*y[n-k]) for k>=1
            var output: PrcFmt = 0.0
            for k in 0..<nb {
                output += bCoeffs[k] * xHistory[k]
            }
            for k in 1..<na {
                output -= aCoeffs[k] * yHistory[k - 1]
            }

            // Shift output history
            for j in stride(from: na - 1, through: 1, by: -1) {
                yHistory[j] = yHistory[j - 1]
            }
            yHistory[0] = output

            waveform[i] = output
        }
    }

    public func updateParameters(_ config: FilterConfig) {
        let params = config.parameters
        aCoeffs = params.a ?? [1.0]
        bCoeffs = params.b ?? [1.0]
        // Normalize by a[0]
        if let a0 = aCoeffs.first, a0 != 0 && a0 != 1.0 {
            let scale = 1.0 / a0
            aCoeffs = aCoeffs.map { $0 * scale }
            bCoeffs = bCoeffs.map { $0 * scale }
        }
        xHistory = [PrcFmt](repeating: 0, count: bCoeffs.count)
        yHistory = [PrcFmt](repeating: 0, count: aCoeffs.count)
    }
}
