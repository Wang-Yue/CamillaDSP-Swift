// AppState+Monitoring - Spectrum analysis, level metering, and related types

import Foundation
import CamillaDSPLib
import Accelerate

// MARK: - Level Types

struct StereoLevel {
    var left: Double
    var right: Double

    static let silent = StereoLevel(left: -100, right: -100)
}

/// Separate ObservableObject for high-frequency meter/spectrum updates.
/// Only views that observe this (meters, spectrum) will re-render on updates,
/// not the entire app (sidebar, pipeline stages, device pickers, etc.)
@MainActor
final class MeterState: ObservableObject {
    var capturePeak: StereoLevel = .silent
    var captureRms: StereoLevel = .silent
    var playbackPeak: StereoLevel = .silent
    var playbackRms: StereoLevel = .silent
    var spectrumBands: [Double] = Array(repeating: -100, count: 30)
    var processingLoad: Double = 0

    func update(capturePeak: StereoLevel, captureRms: StereoLevel,
                playbackPeak: StereoLevel, playbackRms: StereoLevel,
                spectrumBands: [Double], processingLoad: Double) {
        self.capturePeak = capturePeak
        self.captureRms = captureRms
        self.playbackPeak = playbackPeak
        self.playbackRms = playbackRms
        self.spectrumBands = spectrumBands
        self.processingLoad = processingLoad
        objectWillChange.send()
    }

    func reset() {
        update(capturePeak: .silent, captureRms: .silent,
               playbackPeak: .silent, playbackRms: .silent,
               spectrumBands: Array(repeating: -100, count: 30), processingLoad: 0)
    }
}

// MARK: - Spectrum Mode

enum SpectrumMode: String, CaseIterable, Identifiable {
    case fft = "FFT"
    case filterBank = "Filter Bank"
    var id: String { rawValue }
}

enum SpectrumSource: String, CaseIterable, Identifiable {
    case preProcessing = "Pre"
    case postProcessing = "Post"
    var id: String { rawValue }
}

/// Common interface for spectrum analyzers
protocol SpectrumAnalyzerProtocol: AnyObject {
    func enqueueAudio(_ waveform: [PrcFmt])
    func readBands() -> [Double]
}

// MARK: - AppState Monitoring Extension

extension AppState {

    // MARK: - Spectrum Analyzer Management

    func recreateSpectrumAnalyzer() {
        // Only create the expensive filter bank when actually selected
        switch spectrumMode {
        case .filterBank:
            spectrumAnalyzer = FilterBankSpectrumAnalyzer(sampleRate: sampleRate, chunkSize: chunkSize)
        case .fft:
            spectrumAnalyzer = FFTSpectrumAnalyzer(sampleRate: sampleRate, chunkSize: chunkSize)
        }
    }

    func wireSpectrumTap() {
        let analyzer = spectrumAnalyzer
        let monoMix: (AudioChunk) -> Void = { [weak analyzer] chunk in
            guard chunk.channels >= 1 else { return }
            var mono = chunk.waveforms[0]
            if chunk.channels >= 2 {
                for i in 0..<mono.count {
                    mono[i] = (chunk.waveforms[0][i] + chunk.waveforms[1][i]) * 0.5
                }
            }
            analyzer?.enqueueAudio(mono)
        }

        // Wire to the correct tap point based on source selection
        switch spectrumSource {
        case .preProcessing:
            engine?.onChunkCaptured = monoMix
            engine?.onChunkProcessed = nil
        case .postProcessing:
            engine?.onChunkCaptured = nil
            engine?.onChunkProcessed = monoMix
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))  // 5 Hz — smooth enough with animation
        timer.setEventHandler { [weak self] in
            self?.updateLevels()
        }
        timer.resume()
        monitorTimer = timer
    }

    func stopMonitoring() {
        monitorTimer?.cancel()
        monitorTimer = nil
    }

    nonisolated func updateLevels() {
        MainActor.assumeIsolated {
            guard let params = engine?.processingParams else { return }

            let capPeak = params.captureSignalPeak
            let capRms = params.captureSignalRms
            let pbPeak = params.playbackSignalPeak
            let pbRms = params.playbackSignalRms
            let load = params.processingLoad
            let bands = spectrumAnalyzer?.readBands() ?? meters.spectrumBands

            let capPeakLevel = capPeak.count >= 2 ? StereoLevel(left: capPeak[0], right: capPeak[1]) : .silent
            let capRmsLevel = capRms.count >= 2 ? StereoLevel(left: capRms[0], right: capRms[1]) : .silent
            let pbPeakLevel = pbPeak.count >= 2 ? StereoLevel(left: pbPeak[0], right: pbPeak[1]) : .silent
            let pbRmsLevel = pbRms.count >= 2 ? StereoLevel(left: pbRms[0], right: pbRms[1]) : .silent

            meters.update(capturePeak: capPeakLevel, captureRms: capRmsLevel,
                          playbackPeak: pbPeakLevel, playbackRms: pbRmsLevel,
                          spectrumBands: bands, processingLoad: load)
        }
    }
}

// MARK: - Filter Bank Spectrum Analyzer (original, like CamillaDSP-Monitor)
// Uses 30 bandpass biquad filters. Accurate but CPU-heavy.

final class FilterBankSpectrumAnalyzer: SpectrumAnalyzerProtocol {
    static let centerFrequencies: [Double] = [
        25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200,
        250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000,
        2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000
    ]

    private let filters: [BiquadFilter]
    private let bandCount = 30

    // Thread-safe exchange between audio thread → spectrum thread → main thread
    private let bufferLock = NSLock()
    private var pendingBuffer: [PrcFmt]? = nil  // Latest audio from the audio thread

    private let resultsLock = NSLock()
    private var bandPeaks: [Double]

    private let spectrumQueue = DispatchQueue(label: "camilladsp.spectrum", qos: .utility)
    private var spectrumTimer: DispatchSourceTimer?

    init(sampleRate: Int, chunkSize: Int) {
        let q = 4.318
        let nyquist = Double(sampleRate) / 2.0

        var filters: [BiquadFilter] = []
        for (i, freq) in Self.centerFrequencies.enumerated() {
            var p = FilterParameters()
            if freq < 30 {
                p.subtype = BiquadType.lowpass.rawValue
                p.freq = min(freq * 1.2, nyquist * 0.95)
                p.q = 0.707
            } else if freq >= nyquist * 0.95 {
                p.subtype = BiquadType.lowpass.rawValue
                p.freq = nyquist * 0.9
                p.q = 0.707
            } else {
                p.subtype = BiquadType.bandpass.rawValue
                p.freq = freq
                p.q = q
            }
            if let coeffs = try? BiquadFilter.computeCoefficients(p, sampleRate: sampleRate) {
                filters.append(BiquadFilter(name: "spectrum_\(i)", coefficients: coeffs, sampleRate: sampleRate))
            }
        }

        self.filters = filters
        self.bandPeaks = Array(repeating: -100, count: bandCount)

        // Start background processing timer (~20 Hz update rate)
        let timer = DispatchSource.makeTimerSource(queue: spectrumQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.processLatestBuffer()
        }
        timer.resume()
        self.spectrumTimer = timer
    }

    deinit {
        spectrumTimer?.cancel()
    }

    /// Enqueue audio for spectrum analysis. Called from audio processing thread.
    /// This is O(n) memcpy only — no filtering happens here.
    func enqueueAudio(_ waveform: [PrcFmt]) {
        bufferLock.lock()
        pendingBuffer = waveform
        bufferLock.unlock()
    }

    /// Read the latest band levels (dB). Called from main thread.
    func readBands() -> [Double] {
        resultsLock.lock()
        let result = bandPeaks
        resultsLock.unlock()
        return result
    }

    /// Process the latest audio buffer through all 30 filters.
    /// Runs on the dedicated spectrum queue, NOT the audio thread.
    private func processLatestBuffer() {
        // Grab the latest buffer (drop older ones if we're behind)
        bufferLock.lock()
        guard let waveform = pendingBuffer else {
            bufferLock.unlock()
            return
        }
        pendingBuffer = nil
        bufferLock.unlock()

        // Run all 30 bandpass filters
        var newPeaks = [Double](repeating: -100, count: bandCount)
        for i in 0..<min(filters.count, bandCount) {
            var filtered = waveform
            try? filters[i].process(waveform: &filtered)
            let peak = DSPOps.peakAbsolute(filtered)
            newPeaks[i] = PrcFmt.toDB(max(peak, 1e-10))
        }

        resultsLock.lock()
        bandPeaks = newPeaks
        resultsLock.unlock()
    }
}

// MARK: - FFT Spectrum Analyzer
// Uses Accelerate vDSP real FFT + Hanning window, then bins magnitudes into
// the same 30 ISO 1/3-octave bands. Much lighter CPU than 30 biquad filters.

final class FFTSpectrumAnalyzer: SpectrumAnalyzerProtocol {
    static let centerFrequencies: [Double] = FilterBankSpectrumAnalyzer.centerFrequencies

    private let sampleRate: Int
    private let fftSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetupD
    private let window: [Double]
    private let bandBins: [(lo: Int, hi: Int)]  // FFT bin range for each 1/3-octave band
    private let bandCount = 30

    private let bufferLock = NSLock()
    private var pendingBuffer: [PrcFmt]? = nil

    private let resultsLock = NSLock()
    private var bandPeaks: [Double]

    private let spectrumQueue = DispatchQueue(label: "camilladsp.spectrum.fft", qos: .utility)
    private var spectrumTimer: DispatchSourceTimer?

    init(sampleRate: Int, chunkSize: Int) {
        self.sampleRate = sampleRate
        // Use next power of 2 >= chunkSize for FFT
        var fftN = 1
        while fftN < chunkSize { fftN *= 2 }
        // Use at least 4096 for reasonable low-frequency resolution
        fftN = max(fftN, 4096)
        self.fftSize = fftN
        self.log2n = vDSP_Length(log2(Double(fftN)))
        self.fftSetup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!

        // Hanning window
        var win = [Double](repeating: 0, count: fftN)
        vDSP_hann_windowD(&win, vDSP_Length(fftN), Int32(vDSP_HANN_NORM))
        self.window = win

        // Precompute which FFT bins correspond to each 1/3-octave band
        // Each band spans [f_center / 2^(1/6), f_center * 2^(1/6)]
        let binWidth = Double(sampleRate) / Double(fftN)
        let factor = pow(2.0, 1.0 / 6.0)  // half-band ratio for 1/3-octave
        var bins: [(lo: Int, hi: Int)] = []
        for freq in Self.centerFrequencies {
            let fLo = freq / factor
            let fHi = freq * factor
            let binLo = max(1, Int(fLo / binWidth))
            let binHi = min(fftN / 2 - 1, Int(fHi / binWidth))
            bins.append((lo: binLo, hi: max(binLo, binHi)))
        }
        self.bandBins = bins
        self.bandPeaks = Array(repeating: -100, count: bandCount)

        // Background timer at ~20 Hz
        let timer = DispatchSource.makeTimerSource(queue: spectrumQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.processLatestBuffer()
        }
        timer.resume()
        self.spectrumTimer = timer
    }

    deinit {
        spectrumTimer?.cancel()
        vDSP_destroy_fftsetupD(fftSetup)
    }

    func enqueueAudio(_ waveform: [PrcFmt]) {
        bufferLock.lock()
        pendingBuffer = waveform
        bufferLock.unlock()
    }

    func readBands() -> [Double] {
        resultsLock.lock()
        let result = bandPeaks
        resultsLock.unlock()
        return result
    }

    private func processLatestBuffer() {
        bufferLock.lock()
        guard let waveform = pendingBuffer else {
            bufferLock.unlock()
            return
        }
        pendingBuffer = nil
        bufferLock.unlock()

        // Zero-pad or truncate to fftSize, apply window
        var windowed = [Double](repeating: 0, count: fftSize)
        let copyLen = min(waveform.count, fftSize)
        for i in 0..<copyLen {
            windowed[i] = waveform[i] * window[i]
        }

        // Real FFT via vDSP
        let halfN = fftSize / 2
        var realp = [Double](repeating: 0, count: halfN)
        var imagp = [Double](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { rBuf in
            imagp.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPDoubleSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                windowed.withUnsafeBufferPointer { wBuf in
                    vDSP_ctozD(
                        UnsafePointer<DSPDoubleComplex>(OpaquePointer(wBuf.baseAddress!)),
                        2, &split, 1, vDSP_Length(halfN)
                    )
                }
                vDSP_fft_zripD(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        // Compute magnitude (amplitude) for each bin.
        // vDSP forward real FFT gives 2*DFT. A unit sine produces bin magnitude A*N
        // after vDSP's 2x factor. Hanning window has coherent gain 0.5, reducing it
        // to A*N*0.5. To get amplitude = A for a unit sine, scale by 2/N:
        //   (A*N*0.5) * (2/N) = A
        var magnitudes = [Double](repeating: 0, count: halfN)
        for i in 0..<halfN {
            magnitudes[i] = sqrt(realp[i] * realp[i] + imagp[i] * imagp[i])
        }
        var normScale = 2.0 / Double(fftSize)  // 2/N compensates Hanning coherent gain
        vDSP_vsmulD(magnitudes, 1, &normScale, &magnitudes, 1, vDSP_Length(halfN))

        // Bin into 1/3-octave bands: take peak magnitude in each band.
        // This matches the filter bank which measures peak amplitude of the
        // bandpass-filtered time-domain signal. A 1kHz sine at amplitude 1.0
        // should read 0 dB in the 1kHz band with both methods.
        var newPeaks = [Double](repeating: -100, count: bandCount)
        for i in 0..<min(bandBins.count, bandCount) {
            let (lo, hi) = bandBins[i]
            var peakMag = 0.0
            for bin in lo...hi {
                if bin < halfN && magnitudes[bin] > peakMag {
                    peakMag = magnitudes[bin]
                }
            }
            newPeaks[i] = 20.0 * log10(max(peakMag, 1e-10))
        }

        resultsLock.lock()
        bandPeaks = newPeaks
        resultsLock.unlock()
    }
}
