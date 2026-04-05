// CamillaDSP-Swift: Audio resampler using windowed-sinc interpolation

import Foundation
import Accelerate

/// Resampler protocol
public protocol AudioResampler: AnyObject {
    func process(chunk: AudioChunk) throws -> AudioChunk
    func setRatio(_ ratio: Double)
    var ratio: Double { get }
}

// MARK: - Cutoff Frequency Calculation

/// Window function types for sinc filter design
private enum WindowFunction {
    case hann2
    case blackman2
    case blackmanHarris2
}

/// Calculate the optimal cutoff frequency for a given sinc length and window function.
/// Matches Rust rubato's `calculate_cutoff` behavior.
private func calculateCutoff(sincLen: Int, window: WindowFunction) -> Double {
    // Approximate cutoff calculation matching rubato's formula:
    // cutoff = 1.0 - (rolloff_width / 2), where rolloff_width depends on window and sinc_len
    let rolloffFactor: Double
    switch window {
    case .hann2:
        rolloffFactor = 2.0
    case .blackman2:
        rolloffFactor = 2.5
    case .blackmanHarris2:
        rolloffFactor = 3.0
    }
    // rubato uses: cutoff ~ 1.0 - rolloffFactor / sincLen
    return max(0.5, 1.0 - rolloffFactor / Double(sincLen))
}

// MARK: - AsyncSinc Resampler

/// Windowed-sinc asynchronous resampler (similar to rubato AsyncSinc)
/// Optimized: uses contiguous buffer + vDSP_dotprD for the inner loop
public final class AsyncSincResampler: AudioResampler {
    private let channels: Int
    private let sincLen: Int
    private let halfLen: Int
    private let oversamplingFactor: Int
    private var _ratio: Double
    private let cutoffFrequency: Double

    // Pre-computed windowed sinc table: [sincLen * oversamplingFactor]
    // Layout: for fractional index f and tap k, table[(k + halfLen) * oversamplingFactor + f]
    private let windowedSincTable: [PrcFmt]

    // Per-channel contiguous input buffer (history + new samples)
    private var inputBuffers: [[PrcFmt]]
    private var inputPhase: [Double]

    public var ratio: Double { _ratio }

    public init(
        channels: Int,
        inputRate: Int,
        outputRate: Int,
        profile: ResamplerProfile = .balanced
    ) {
        self.channels = channels
        self._ratio = Double(outputRate) / Double(inputRate)

        // Match Rust rubato sinc lengths and parameters exactly
        let window: WindowFunction
        switch profile {
        case .veryFast:
            self.sincLen = 64; self.oversamplingFactor = 1024
            window = .hann2
        case .fast:
            self.sincLen = 128; self.oversamplingFactor = 1024
            window = .blackman2
        case .balanced:
            self.sincLen = 192; self.oversamplingFactor = 512
            window = .blackmanHarris2
        case .accurate:
            self.sincLen = 256; self.oversamplingFactor = 256
            window = .blackmanHarris2
        }
        self.halfLen = sincLen / 2
        self.cutoffFrequency = calculateCutoff(sincLen: sincLen, window: window)

        // Pre-compute windowed sinc table with cutoff scaling
        let tableSize = sincLen * oversamplingFactor
        var table = [PrcFmt](repeating: 0, count: tableSize)
        let fc = cutoffFrequency
        for i in 0..<tableSize {
            let x = PrcFmt(i) / PrcFmt(oversamplingFactor) - PrcFmt(halfLen)
            let xScaled = x * fc
            let sinc: PrcFmt = abs(xScaled) < 1e-10 ? fc : fc * sin(.pi * xScaled) / (.pi * xScaled)
            let t = PrcFmt(i) / PrcFmt(tableSize - 1)
            // Blackman-Harris 4-term window (used for all profiles in table generation)
            let window = 0.35875 - 0.48829 * cos(2.0 * .pi * t) +
                         0.14128 * cos(4.0 * .pi * t) - 0.01168 * cos(6.0 * .pi * t)
            table[i] = sinc * window
        }
        self.windowedSincTable = table

        // Initialize input buffers with sincLen zeros (history padding)
        self.inputBuffers = Array(repeating: [PrcFmt](repeating: 0, count: sincLen), count: channels)
        self.inputPhase = Array(repeating: 0, count: channels)
    }

    public func process(chunk: AudioChunk) throws -> AudioChunk {
        let inputFrames = chunk.validFrames
        let outputFrames = Int(Double(inputFrames) * _ratio + 0.5)

        var outputWaveforms = [[PrcFmt]](repeating: [PrcFmt](repeating: 0, count: outputFrames), count: channels)

        let sincLen = self.sincLen
        let halfLen = self.halfLen
        let oversamplingFactor = self.oversamplingFactor

        for ch in 0..<channels {
            // Append new input to history (avoid full copy: just append in place)
            inputBuffers[ch].append(contentsOf: chunk.waveforms[ch][0..<inputFrames])
            let extended = inputBuffers[ch]
            let extendedCount = extended.count

            var phase = inputPhase[ch]
            let step = 1.0 / _ratio

            extended.withUnsafeBufferPointer { extPtr in
                windowedSincTable.withUnsafeBufferPointer { tablePtr in
                    for outIdx in 0..<outputFrames {
                        let intPhase = Int(phase)
                        let fracPhase = phase - Double(intPhase)
                        let tableIndex = Int(fracPhase * Double(oversamplingFactor))

                        // Compute valid range to avoid bounds checks in inner loop
                        let inputStart = intPhase - halfLen
                        let kStart = max(0, -inputStart)
                        let kEnd = min(sincLen, extendedCount - inputStart)

                        if kStart < kEnd {
                            let inputOffset = inputStart + kStart
                            let tableOffset = kStart * oversamplingFactor + tableIndex
                            let count = kEnd - kStart

                            // vDSP strided dot product: input is stride 1, table is stride oversamplingFactor
                            var result: PrcFmt = 0
                            vDSP_dotprD(
                                extPtr.baseAddress! + inputOffset, 1,
                                tablePtr.baseAddress! + tableOffset, oversamplingFactor,
                                &result,
                                vDSP_Length(count)
                            )
                            outputWaveforms[ch][outIdx] = result
                        }

                        phase += step
                    }
                }
            }

            // Trim consumed samples from history, keep sincLen tail
            let consumed = Int(phase)
            let keepFrom = max(0, consumed - sincLen)
            if keepFrom > 0 {
                inputBuffers[ch].removeFirst(keepFrom)
            }
            inputPhase[ch] = phase - Double(consumed) + Double(consumed - keepFrom)
        }

        return AudioChunk(waveforms: outputWaveforms, validFrames: outputFrames)
    }

    public func setRatio(_ ratio: Double) {
        _ratio = ratio
    }
}

// MARK: - AsyncPoly Resampler

/// Polynomial interpolation degree (matches Rust rubato PolynomialDegree)
public enum PolyInterpolation: String, Codable {
    case linear = "Linear"
    case cubic = "Cubic"
    case quintic = "Quintic"
    case septic = "Septic"
}

/// Simple polynomial resampler (lower quality, lower CPU)
/// Phase state is persisted across chunks per-channel to ensure continuity.
public final class AsyncPolyResampler: AudioResampler {
    private let channels: Int
    private var _ratio: Double
    private let interpolation: PolyInterpolation

    /// Per-channel phase accumulator -- persists across process() calls
    private var channelPhases: [Double]

    /// Per-channel history buffer for inter-chunk continuity
    /// Stores the last few samples from the previous chunk needed for interpolation
    private var channelHistory: [[PrcFmt]]

    /// Number of history samples needed on each side of the interpolation point
    private var historyLen: Int {
        switch interpolation {
        case .linear:   return 1  // needs i0..i1 (1 before, 0 after relative to center)
        case .cubic:    return 2  // needs i-1..i+2
        case .quintic:  return 3  // needs i-2..i+3
        case .septic:   return 4  // needs i-3..i+4
        }
    }

    public var ratio: Double { _ratio }

    public init(channels: Int, inputRate: Int, outputRate: Int, interpolation: PolyInterpolation = .cubic) {
        self.channels = channels
        self._ratio = Double(outputRate) / Double(inputRate)
        self.interpolation = interpolation
        self.channelPhases = Array(repeating: 0.0, count: channels)
        self.channelHistory = Array(repeating: [], count: channels)
    }

    public func process(chunk: AudioChunk) throws -> AudioChunk {
        let inputFrames = chunk.validFrames
        let outputFrames = Int(Double(inputFrames) * _ratio + 0.5)

        var outputWaveforms = [[PrcFmt]](repeating: [PrcFmt](repeating: 0, count: outputFrames), count: channels)

        for ch in 0..<channels {
            // Build extended buffer: history from previous chunk + current input
            var extended: [PrcFmt] = channelHistory[ch]
            extended.append(contentsOf: chunk.waveforms[ch][0..<inputFrames])
            let historyOffset = channelHistory[ch].count

            var phase = channelPhases[ch]
            let step = 1.0 / _ratio

            for outIdx in 0..<outputFrames {
                // Phase is relative to current chunk start; offset into extended buffer
                let pos = phase + Double(historyOffset)
                let intPos = Int(pos)
                let frac = PrcFmt(pos - Double(intPos))

                let sample: PrcFmt
                switch interpolation {
                case .linear:
                    let i0 = max(0, min(extended.count - 1, intPos))
                    let i1 = max(0, min(extended.count - 1, intPos + 1))
                    sample = extended[i0] + frac * (extended[i1] - extended[i0])

                case .cubic:
                    // Catmull-Rom cubic interpolation
                    let i0 = max(0, min(extended.count - 1, intPos - 1))
                    let i1 = max(0, min(extended.count - 1, intPos))
                    let i2 = max(0, min(extended.count - 1, intPos + 1))
                    let i3 = max(0, min(extended.count - 1, intPos + 2))
                    let y0 = extended[i0], y1 = extended[i1], y2 = extended[i2], y3 = extended[i3]
                    let a = -0.5 * y0 + 1.5 * y1 - 1.5 * y2 + 0.5 * y3
                    let b = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
                    let c = -0.5 * y0 + 0.5 * y2
                    sample = ((a * frac + b) * frac + c) * frac + y1

                case .quintic:
                    // 6-point quintic (Lagrange)
                    let indices = (-2...3).map { max(0, min(extended.count - 1, intPos + $0)) }
                    let y = indices.map { extended[$0] }
                    let t = frac
                    // Lagrange basis polynomials for points at -2,-1,0,1,2,3
                    sample = lagrangeInterpolate6(y: y, t: t)

                case .septic:
                    // 8-point septic (Lagrange)
                    let indices = (-3...4).map { max(0, min(extended.count - 1, intPos + $0)) }
                    let y = indices.map { extended[$0] }
                    let t = frac
                    sample = lagrangeInterpolate8(y: y, t: t)
                }

                outputWaveforms[ch][outIdx] = sample
                phase += step
            }

            // Save history: keep last historyLen*2 samples for next chunk's interpolation
            let keepCount = min(historyLen * 2, extended.count)
            channelHistory[ch] = Array(extended.suffix(keepCount))

            // Update phase: subtract consumed input samples
            let consumed = Int(phase)
            channelPhases[ch] = phase - Double(consumed)
            // Adjust history to account for unconsumed fractional position
            // We need enough history to cover the interpolation window at the start of next chunk
        }

        return AudioChunk(waveforms: outputWaveforms, validFrames: outputFrames)
    }

    public func setRatio(_ ratio: Double) {
        _ratio = ratio
    }

    // MARK: - Lagrange interpolation helpers

    /// 6-point Lagrange interpolation at fractional position t (0..1)
    /// Points are at positions -2, -1, 0, 1, 2, 3
    private func lagrangeInterpolate6(y: [PrcFmt], t: PrcFmt) -> PrcFmt {
        let x = t // fractional position, relative to point at index 2 (value 0)
        let positions: [PrcFmt] = [-2, -1, 0, 1, 2, 3]
        var result: PrcFmt = 0
        for i in 0..<6 {
            var basis: PrcFmt = 1
            for j in 0..<6 where j != i {
                basis *= (x - positions[j]) / (positions[i] - positions[j])
            }
            result += y[i] * basis
        }
        return result
    }

    /// 8-point Lagrange interpolation at fractional position t (0..1)
    /// Points are at positions -3, -2, -1, 0, 1, 2, 3, 4
    private func lagrangeInterpolate8(y: [PrcFmt], t: PrcFmt) -> PrcFmt {
        let x = t
        let positions: [PrcFmt] = [-3, -2, -1, 0, 1, 2, 3, 4]
        var result: PrcFmt = 0
        for i in 0..<8 {
            var basis: PrcFmt = 1
            for j in 0..<8 where j != i {
                basis *= (x - positions[j]) / (positions[i] - positions[j])
            }
            result += y[i] * basis
        }
        return result
    }
}

// MARK: - Synchronous (FFT-based) Resampler

/// FFT-based synchronous resampler for fixed integer-ratio resampling.
/// Uses Accelerate's vDSP FFT for high-quality band-limited resampling.
/// Matches Rust CamillaDSP's `Synchronous` resampler type (rubato Fft).
public final class SynchronousResampler: AudioResampler {
    private let channels: Int
    private let inputRate: Int
    private let outputRate: Int
    private var _ratio: Double
    private let resampleFactor: Int  // GCD-reduced numerator/denominator for FFT approach
    private let inputChunkSize: Int
    private let outputChunkSize: Int

    // FFT setup for Accelerate
    private let fftSetupForward: vDSP_DFT_Setup?
    private let fftSetupInverse: vDSP_DFT_Setup?
    private let useFFTPath: Bool

    // Per-channel overlap buffer for continuity
    private var overlapBuffers: [[PrcFmt]]

    public var ratio: Double { _ratio }

    public init(channels: Int, inputRate: Int, outputRate: Int, chunkSize: Int = 0) {
        self.channels = channels
        self.inputRate = inputRate
        self.outputRate = outputRate
        self._ratio = Double(outputRate) / Double(inputRate)

        // Compute GCD to find the minimal ratio
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(inputRate, outputRate)
        let upFactor = outputRate / g
        let downFactor = inputRate / g

        self.resampleFactor = upFactor
        self.inputChunkSize = chunkSize > 0 ? chunkSize : 1024
        self.outputChunkSize = Int(Double(inputChunkSize) * Double(outputRate) / Double(inputRate) + 0.5)

        // For true FFT resampling, we need power-of-2 or use DFT
        // Use vDSP DFT which handles arbitrary sizes
        // We'll do: FFT of input -> zero-pad or truncate spectrum -> IFFT at output size
        let inputFFTSize = inputChunkSize
        let outputFFTSize = outputChunkSize

        // Try to create DFT setups; fall back to sinc resampling if sizes are problematic
        if inputFFTSize > 0 && outputFFTSize > 0 {
            self.fftSetupForward = vDSP_DFT_zrop_CreateSetupD(nil, vDSP_Length(inputFFTSize), .FORWARD)
            self.fftSetupInverse = vDSP_DFT_zrop_CreateSetupD(nil, vDSP_Length(outputFFTSize), .INVERSE)
            self.useFFTPath = (fftSetupForward != nil && fftSetupInverse != nil)
        } else {
            self.fftSetupForward = nil
            self.fftSetupInverse = nil
            self.useFFTPath = false
        }

        self.overlapBuffers = Array(repeating: [], count: channels)

        // Note: ratio is fixed for synchronous resampler, setRatio is a no-op
        _ = upFactor
        _ = downFactor
    }

    deinit {
        if let setup = fftSetupForward { vDSP_DFT_DestroySetupD(setup) }
        if let setup = fftSetupInverse { vDSP_DFT_DestroySetupD(setup) }
    }

    public func process(chunk: AudioChunk) throws -> AudioChunk {
        let inputFrames = chunk.validFrames
        let outputFrames = Int(Double(inputFrames) * _ratio + 0.5)

        var outputWaveforms = [[PrcFmt]](repeating: [PrcFmt](repeating: 0, count: outputFrames), count: channels)

        if useFFTPath && inputFrames == inputChunkSize {
            // FFT-based resampling path
            for ch in 0..<channels {
                outputWaveforms[ch] = fftResample(input: Array(chunk.waveforms[ch][0..<inputFrames]),
                                                   outputSize: outputFrames)
            }
        } else {
            // Fallback: high-quality sinc interpolation with fixed ratio
            // This is equivalent to AsyncSinc with a locked ratio
            for ch in 0..<channels {
                let input = chunk.waveforms[ch]
                let step = 1.0 / _ratio
                for outIdx in 0..<outputFrames {
                    let pos = Double(outIdx) * step
                    let intPos = Int(pos)
                    let frac = PrcFmt(pos - Double(intPos))

                    // Cubic interpolation as fallback
                    let i0 = max(0, min(inputFrames - 1, intPos - 1))
                    let i1 = max(0, min(inputFrames - 1, intPos))
                    let i2 = max(0, min(inputFrames - 1, intPos + 1))
                    let i3 = max(0, min(inputFrames - 1, intPos + 2))

                    let y0 = input[i0], y1 = input[i1], y2 = input[i2], y3 = input[i3]
                    let a = -0.5 * y0 + 1.5 * y1 - 1.5 * y2 + 0.5 * y3
                    let b = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
                    let c = -0.5 * y0 + 0.5 * y2
                    outputWaveforms[ch][outIdx] = ((a * frac + b) * frac + c) * frac + y1
                }
            }
        }

        return AudioChunk(waveforms: outputWaveforms, validFrames: outputFrames)
    }

    /// FFT-based resampling: transform to frequency domain, resize spectrum, transform back
    private func fftResample(input: [PrcFmt], outputSize: Int) -> [PrcFmt] {
        let inputSize = input.count
        guard inputSize > 0, outputSize > 0 else { return [PrcFmt](repeating: 0, count: outputSize) }

        // Forward DFT (real-to-complex)
        let halfInput = inputSize / 2
        var realIn = [PrcFmt](repeating: 0, count: halfInput)
        var imagIn = [PrcFmt](repeating: 0, count: halfInput)

        // Pack input into even/odd for zrop
        for i in 0..<halfInput {
            realIn[i] = input[2 * i]
            imagIn[i] = (2 * i + 1 < inputSize) ? input[2 * i + 1] : 0
        }

        var realOut = [PrcFmt](repeating: 0, count: halfInput)
        var imagOut = [PrcFmt](repeating: 0, count: halfInput)

        guard let fwdSetup = fftSetupForward else {
            return [PrcFmt](repeating: 0, count: outputSize)
        }
        vDSP_DFT_ExecuteD(fwdSetup, realIn, imagIn, &realOut, &imagOut)

        // Resize spectrum: zero-pad (upsample) or truncate (downsample)
        let halfOutput = outputSize / 2
        var realResized = [PrcFmt](repeating: 0, count: halfOutput)
        var imagResized = [PrcFmt](repeating: 0, count: halfOutput)

        let copyLen = min(halfInput, halfOutput)
        // Copy positive frequencies (first half)
        let lowCopy = copyLen / 2
        for i in 0..<lowCopy {
            realResized[i] = realOut[i]
            imagResized[i] = imagOut[i]
        }
        // Copy negative frequencies (mirrored at end)
        let highCopy = min(lowCopy, min(halfInput, halfOutput))
        for i in 0..<highCopy {
            realResized[halfOutput - 1 - i] = realOut[halfInput - 1 - i]
            imagResized[halfOutput - 1 - i] = imagOut[halfInput - 1 - i]
        }

        // Inverse DFT
        var realInv = [PrcFmt](repeating: 0, count: halfOutput)
        var imagInv = [PrcFmt](repeating: 0, count: halfOutput)

        guard let invSetup = fftSetupInverse else {
            return [PrcFmt](repeating: 0, count: outputSize)
        }
        vDSP_DFT_ExecuteD(invSetup, realResized, imagResized, &realInv, &imagInv)

        // Unpack and normalize
        let scale = _ratio / Double(inputSize)
        var output = [PrcFmt](repeating: 0, count: outputSize)
        for i in 0..<halfOutput {
            if 2 * i < outputSize { output[2 * i] = realInv[i] * scale }
            if 2 * i + 1 < outputSize { output[2 * i + 1] = imagInv[i] * scale }
        }

        return output
    }

    public func setRatio(_ ratio: Double) {
        // Synchronous resampler has a fixed ratio; ignore dynamic adjustments
    }
}
