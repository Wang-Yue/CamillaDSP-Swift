// CamillaDSP-Swift: FIR Convolution filter using FFT overlap-save method
// Uses Accelerate framework for FFT operations

import Foundation
import Accelerate

public final class ConvolutionFilter: Filter {
    public let name: String

    // FFT setup
    private let fftSize: Int       // FFT length (next power of 2 >= chunkSize + irLength - 1)
    private let chunkSize: Int
    private let sampleRate: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetupD

    // Segmented convolution state
    private let nsegments: Int
    private var coeffsF: [DSPDoubleSplitComplex]  // Pre-FFT'd IR segments
    private var inputF: [DSPDoubleSplitComplex]    // History of input FFTs
    private var overlap: [PrcFmt]                   // Overlap buffer
    private var segmentIndex: Int = 0

    // Temporary buffers
    private var fftBuffer: DSPDoubleSplitComplex
    private var accumReal: [PrcFmt]
    private var accumImag: [PrcFmt]

    public init(name: String, config: FilterConfig, chunkSize: Int, sampleRate: Int) throws {
        self.name = name
        self.chunkSize = chunkSize
        self.sampleRate = sampleRate

        // Load impulse response coefficients
        let ir = try ConvolutionFilter.loadCoefficients(config.parameters, sampleRate: sampleRate)

        guard !ir.isEmpty else {
            throw ConfigError.invalidFilter("Conv filter '\(name)' has empty impulse response")
        }

        // Compute segmented convolution parameters
        // Segment length = chunkSize, FFT length = 2 * chunkSize
        let segmentLength = chunkSize
        self.fftSize = segmentLength * 2
        self.nsegments = (ir.count + segmentLength - 1) / segmentLength
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
        self.overlap = [PrcFmt](repeating: 0, count: chunkSize)

        // vDSP_fft_zripD packs a real N-point FFT into N/2 complex elements (DC in realp[0],
        // Nyquist in imagp[0], positive bins 1..N/2-1).  The valid region is exactly N/2 elements.
        let halfFFT = fftSize / 2

        // Pre-compute FFT of each IR segment
        self.coeffsF = []
        for seg in 0..<nsegments {
            let start = seg * segmentLength
            let end = min(start + segmentLength, ir.count)
            var padded = [PrcFmt](repeating: 0, count: fftSize)
            for i in start..<end {
                padded[i - start] = ir[i]
            }

            var splitComplex = ConvolutionFilter.allocSplitComplex(count: halfFFT)
            ConvolutionFilter.forwardFFT(padded, setup: fftSetup, log2n: log2n, fftSize: fftSize, result: &splitComplex)
            coeffsF.append(splitComplex)
        }

        // Allocate input history buffers
        self.inputF = (0..<nsegments).map { _ in ConvolutionFilter.allocSplitComplex(count: halfFFT) }

        // Temp buffers
        self.fftBuffer = ConvolutionFilter.allocSplitComplex(count: halfFFT)
        self.accumReal = [PrcFmt](repeating: 0, count: halfFFT)
        self.accumImag = [PrcFmt](repeating: 0, count: halfFFT)
    }

    deinit {
        vDSP_destroy_fftsetupD(fftSetup)
    }

    public func process(waveform: inout [PrcFmt]) throws {
        // Same valid region as in init: N/2 complex elements in the packed real-FFT format.
        let halfFFT = fftSize / 2

        // Zero-pad input to FFT size
        var padded = [PrcFmt](repeating: 0, count: fftSize)
        for i in 0..<min(waveform.count, chunkSize) {
            padded[i] = waveform[i]
        }

        // Forward FFT of input
        ConvolutionFilter.forwardFFT(padded, setup: fftSetup, log2n: log2n, fftSize: fftSize, result: &inputF[segmentIndex])

        // Accumulate: sum of (inputF[i] * coeffsF[i]) for all segments
        accumReal = [PrcFmt](repeating: 0, count: halfFFT)
        accumImag = [PrcFmt](repeating: 0, count: halfFFT)

        for seg in 0..<nsegments {
            let inputIdx = (segmentIndex + nsegments - seg) % nsegments
            // Complex multiply using vDSP_zvmulD for proper handling
            var tempResult = ConvolutionFilter.allocSplitComplex(count: halfFFT)
            var inputSplit = inputF[inputIdx]
            var coeffSplit = coeffsF[seg]
            vDSP_zvmulD(&inputSplit, 1, &coeffSplit, 1, &tempResult, 1, vDSP_Length(halfFFT), 1)

            // Fix packed format bin 0: DC and Nyquist are real values stored in realp[0]/imagp[0]
            // zvmulD treats them as a complex pair, but they should be multiplied independently
            tempResult.realp[0] = inputF[inputIdx].realp[0] * coeffsF[seg].realp[0]
            tempResult.imagp[0] = inputF[inputIdx].imagp[0] * coeffsF[seg].imagp[0]

            // Accumulate
            vDSP_vaddD(accumReal, 1, tempResult.realp, 1, &accumReal, 1, vDSP_Length(halfFFT))
            vDSP_vaddD(accumImag, 1, tempResult.imagp, 1, &accumImag, 1, vDSP_Length(halfFFT))

            tempResult.realp.deallocate()
            tempResult.imagp.deallocate()
        }

        // Inverse FFT
        fftBuffer.realp.update(from: accumReal, count: halfFFT)
        fftBuffer.imagp.update(from: accumImag, count: halfFFT)

        var output = [PrcFmt](repeating: 0, count: fftSize)
        ConvolutionFilter.inverseFFT(fftBuffer, setup: fftSetup, log2n: log2n, fftSize: fftSize, result: &output)

        // Overlap-save: take the last chunkSize samples (discard first chunkSize)
        // Actually for overlap-save, we take samples [chunkSize..<2*chunkSize] but since
        // we use overlap-add here, we add the overlap from previous block
        for i in 0..<chunkSize {
            waveform[i] = output[i] + overlap[i]
        }

        // Save overlap for next block
        for i in 0..<chunkSize {
            overlap[i] = (chunkSize + i < fftSize) ? output[chunkSize + i] : 0
        }

        segmentIndex = (segmentIndex + 1) % nsegments
    }

    public func updateParameters(_ config: FilterConfig) {
        // Convolution IR reload requires rebuilding FFT'd segments
        guard let newFilter = try? ConvolutionFilter(
            name: name, config: config, chunkSize: chunkSize, sampleRate: sampleRate
        ) else { return }
        let segmentCountChanged = newFilter.coeffsF.count != coeffsF.count
        coeffsF = newFilter.coeffsF
        accumReal = newFilter.accumReal
        accumImag = newFilter.accumImag
        // Preserve overlap buffer (avoid transient)
        // Reset input history only if segment count changed
        if segmentCountChanged {
            inputF = newFilter.inputF
            segmentIndex = 0
        }
    }

    // MARK: - FFT Helpers

    private static func allocSplitComplex(count: Int) -> DSPDoubleSplitComplex {
        let real = UnsafeMutablePointer<Double>.allocate(capacity: count)
        let imag = UnsafeMutablePointer<Double>.allocate(capacity: count)
        real.initialize(repeating: 0, count: count)
        imag.initialize(repeating: 0, count: count)
        return DSPDoubleSplitComplex(realp: real, imagp: imag)
    }

    private static func forwardFFT(
        _ input: [PrcFmt], setup: FFTSetupD, log2n: vDSP_Length, fftSize: Int,
        result: inout DSPDoubleSplitComplex
    ) {
        var inputCopy = input
        inputCopy.withUnsafeMutableBufferPointer { buf in
            var split = DSPDoubleSplitComplex(
                realp: result.realp,
                imagp: result.imagp
            )
            vDSP_ctozD(
                UnsafePointer<DSPDoubleComplex>(OpaquePointer(buf.baseAddress!)),
                2, &split, 1, vDSP_Length(fftSize / 2)
            )
            vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        }
    }

    private static func inverseFFT(
        _ input: DSPDoubleSplitComplex, setup: FFTSetupD, log2n: vDSP_Length, fftSize: Int,
        result: inout [PrcFmt]
    ) {
        var split = DSPDoubleSplitComplex(realp: input.realp, imagp: input.imagp)
        vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))

        result.withUnsafeMutableBufferPointer { buf in
            vDSP_ztocD(
                &split, 1,
                UnsafeMutablePointer<DSPDoubleComplex>(OpaquePointer(buf.baseAddress!)),
                2, vDSP_Length(fftSize / 2)
            )
        }

        // Scale by 1/(4*fftSize) to account for vDSP's 2x forward scaling on both operands
        var scale = 1.0 / PrcFmt(4 * fftSize)
        vDSP_vsmulD(result, 1, &scale, &result, 1, vDSP_Length(fftSize))
    }

    // MARK: - Coefficient Loading

    private static func loadCoefficients(_ params: FilterParameters, sampleRate: Int) throws -> [PrcFmt] {
        guard let convType = params.convType else {
            throw ConfigError.invalidFilter("Conv filter missing coefficient type")
        }

        switch convType {
        case .values:
            return params.values ?? []

        case .wav:
            guard let filename = params.filename else {
                throw ConfigError.invalidFilter("Conv Wav filter missing filename")
            }
            let resolved = filename.replacingOccurrences(of: "$samplerate$", with: "\(sampleRate)")
            return try loadWavFile(resolved, channel: params.channel ?? 0)

        case .raw:
            guard let filename = params.filename else {
                throw ConfigError.invalidFilter("Conv Raw filter missing filename")
            }
            let resolved = filename.replacingOccurrences(of: "$samplerate$", with: "\(sampleRate)")
            return try loadRawFile(resolved, format: params.rawFormat ?? "FLOAT64")
        }
    }

    private static func loadWavFile(_ path: String, channel: Int) throws -> [PrcFmt] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw ConfigError.invalidFilter("WAV file not found: \(path)")
        }

        let data = try Data(contentsOf: url)

        // Simple WAV parser
        guard data.count > 44 else {
            throw ConfigError.invalidFilter("WAV file too small: \(path)")
        }

        // Read header
        let numChannels = data.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) }
        let bitsPerSample = data.withUnsafeBytes { $0.load(fromByteOffset: 34, as: UInt16.self) }
        let dataSize = data.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }

        guard channel < Int(numChannels) else {
            throw ConfigError.invalidFilter("WAV channel \(channel) out of range (file has \(numChannels) channels)")
        }

        let bytesPerSample = Int(bitsPerSample) / 8
        let numFrames = Int(dataSize) / (Int(numChannels) * bytesPerSample)
        var result = [PrcFmt](repeating: 0, count: numFrames)

        let headerSize = 44 // Standard WAV header
        for frame in 0..<numFrames {
            let offset = headerSize + (frame * Int(numChannels) + channel) * bytesPerSample
            guard offset + bytesPerSample <= data.count else { break }

            switch bitsPerSample {
            case 16:
                let raw = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int16.self) }
                result[frame] = PrcFmt(raw) / PrcFmt(Int16.max)
            case 24:
                let b0 = Int32(data[offset])
                let b1 = Int32(data[offset + 1])
                let b2 = Int32(data[offset + 2])
                var raw = b0 | (b1 << 8) | (b2 << 16)
                if raw & 0x800000 != 0 { raw |= -0x800000 }
                result[frame] = PrcFmt(raw) / PrcFmt((1 << 23) - 1)
            case 32:
                let raw = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Float.self) }
                result[frame] = PrcFmt(raw)
            case 64:
                let raw = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Double.self) }
                result[frame] = PrcFmt(raw)
            default:
                throw ConfigError.invalidFilter("Unsupported WAV bit depth: \(bitsPerSample)")
            }
        }
        return result
    }

    private static func loadRawFile(_ path: String, format: String) throws -> [PrcFmt] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw ConfigError.invalidFilter("Raw file not found: \(path)")
        }

        // Check if it's a text file
        if format == "TEXT" {
            let text = try String(contentsOf: url, encoding: .utf8)
            return text.split(separator: "\n").compactMap { PrcFmt($0.trimmingCharacters(in: .whitespaces)) }
        }

        let data = try Data(contentsOf: url)

        switch format {
        case "FLOAT64", "F64_LE":
            let count = data.count / 8
            return data.withUnsafeBytes { buf in
                (0..<count).map { PrcFmt(buf.load(fromByteOffset: $0 * 8, as: Double.self)) }
            }
        case "FLOAT32", "F32_LE":
            let count = data.count / 4
            return data.withUnsafeBytes { buf in
                (0..<count).map { PrcFmt(buf.load(fromByteOffset: $0 * 4, as: Float.self)) }
            }
        case "S32_LE":
            let count = data.count / 4
            let scale = 1.0 / PrcFmt(Int32.max)
            return data.withUnsafeBytes { buf in
                (0..<count).map { PrcFmt(buf.load(fromByteOffset: $0 * 4, as: Int32.self)) * scale }
            }
        case "S16_LE":
            let count = data.count / 2
            let scale = 1.0 / PrcFmt(Int16.max)
            return data.withUnsafeBytes { buf in
                (0..<count).map { PrcFmt(buf.load(fromByteOffset: $0 * 2, as: Int16.self)) * scale }
            }
        default:
            throw ConfigError.invalidFilter("Unsupported raw format: \(format)")
        }
    }
}
