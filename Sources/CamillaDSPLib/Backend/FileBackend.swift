// CamillaDSP-Swift: File-based audio backends (raw files, WAV, stdin/stdout)

import Foundation
import Logging

// MARK: - Raw File Capture

public final class RawFileCapture: CaptureBackend {
    private let logger = Logger(label: "camilladsp.file.capture")
    private let filePath: String
    private let channels: Int
    private let sampleRate: Int
    private let format: SampleFormat

    private var fileHandle: FileHandle?
    private var bytesPerFrame: Int { channels * format.bytesPerSample }
    public var actualSampleRate: Double { Double(sampleRate) }

    public init(path: String, channels: Int, sampleRate: Int, format: SampleFormat) {
        self.filePath = path
        self.channels = channels
        self.sampleRate = sampleRate
        self.format = format
    }

    public func open() throws {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw AudioBackendError.deviceNotFound("File not found: \(filePath)")
        }
        fileHandle = FileHandle(forReadingAtPath: filePath)
        guard fileHandle != nil else {
            throw AudioBackendError.initializationFailed("Cannot open file: \(filePath)")
        }
        logger.info("Raw file capture opened: \(filePath)")
    }

    public func read(frames: Int) throws -> AudioChunk? {
        guard let handle = fileHandle else { return nil }

        let bytesNeeded = frames * bytesPerFrame
        let data = handle.readData(ofLength: bytesNeeded)

        if data.isEmpty { return nil } // EOF

        let actualFrames = data.count / bytesPerFrame
        let waveforms = data.withUnsafeBytes { ptr in
            bytesToWaveforms(ptr, format: format, channels: channels, frames: actualFrames)
        }

        return AudioChunk(waveforms: waveforms, validFrames: actualFrames)
    }

    public func close() {
        fileHandle?.closeFile()
        fileHandle = nil
    }
}

// MARK: - Raw File Playback

public final class RawFilePlayback: PlaybackBackend {
    private let logger = Logger(label: "camilladsp.file.playback")
    private let filePath: String
    private let channels: Int
    private let format: SampleFormat

    private var fileHandle: FileHandle?
    public var bufferLevel: Int { 0 }

    public init(path: String, channels: Int, format: SampleFormat) {
        self.filePath = path
        self.channels = channels
        self.format = format
    }

    public func open() throws {
        FileManager.default.createFile(atPath: filePath, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: filePath)
        guard fileHandle != nil else {
            throw AudioBackendError.initializationFailed("Cannot open file for writing: \(filePath)")
        }
        logger.info("Raw file playback opened: \(filePath)")
    }

    public func write(chunk: AudioChunk) throws {
        guard let handle = fileHandle else { return }
        let data = waveformsToBytes(chunk.waveforms, format: format, frames: chunk.validFrames)
        handle.write(data)
    }

    public func close() {
        fileHandle?.closeFile()
        fileHandle = nil
    }
}

// MARK: - Stdin Capture

public final class StdinCapture: CaptureBackend {
    private let channels: Int
    private let sampleRate: Int
    private let format: SampleFormat
    public var actualSampleRate: Double { Double(sampleRate) }

    public init(channels: Int, sampleRate: Int, format: SampleFormat) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.format = format
    }

    public func open() throws {}

    public func read(frames: Int) throws -> AudioChunk? {
        let bytesNeeded = frames * channels * format.bytesPerSample
        var data = Data(capacity: bytesNeeded)

        let handle = FileHandle.standardInput
        data = handle.readData(ofLength: bytesNeeded)
        if data.isEmpty { return nil }

        let actualFrames = data.count / (channels * format.bytesPerSample)
        let waveforms = data.withUnsafeBytes { ptr in
            bytesToWaveforms(ptr, format: format, channels: channels, frames: actualFrames)
        }
        return AudioChunk(waveforms: waveforms, validFrames: actualFrames)
    }

    public func close() {}
}

// MARK: - Stdout Playback

public final class StdoutPlayback: PlaybackBackend {
    private let channels: Int
    private let format: SampleFormat
    public var bufferLevel: Int { 0 }

    public init(channels: Int, format: SampleFormat) {
        self.channels = channels
        self.format = format
    }

    public func open() throws {}

    public func write(chunk: AudioChunk) throws {
        let data = waveformsToBytes(chunk.waveforms, format: format, frames: chunk.validFrames)
        FileHandle.standardOutput.write(data)
    }

    public func close() {}
}

// MARK: - Signal Generator Capture

public final class SignalGeneratorCapture: CaptureBackend {
    private let channels: Int
    private let sampleRate: Int
    private let signal: SignalConfig
    private var phase: Double = 0.0

    public var actualSampleRate: Double { Double(sampleRate) }

    /// Initialise from a `SignalConfig`.
    /// `level` in the config is dBFS; it is converted to a linear amplitude here so the
    /// generator loop never has to think about the dB domain.
    public init(channels: Int, sampleRate: Int, signal: SignalConfig) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.signal = signal
    }

    public func open() throws {}

    public func read(frames: Int) throws -> AudioChunk? {
        var waveforms = [[PrcFmt]](repeating: [PrcFmt](repeating: 0, count: frames), count: channels)

        switch signal {
        case .sine(let freq, let level):
            let amplitude = PrcFmt.fromDB(PrcFmt(level))
            let phaseIncrement = freq / Double(sampleRate)
            for i in 0..<frames {
                let sample = amplitude * PrcFmt(sin(2.0 * .pi * phase))
                for ch in 0..<channels { waveforms[ch][i] = sample }
                phase += phaseIncrement
                if phase >= 1.0 { phase -= 1.0 }
            }

        case .square(let freq, let level):
            let amplitude = PrcFmt.fromDB(PrcFmt(level))
            let phaseIncrement = freq / Double(sampleRate)
            for i in 0..<frames {
                let sample = amplitude * (sin(2.0 * .pi * phase) >= 0 ? 1.0 : -1.0)
                for ch in 0..<channels { waveforms[ch][i] = sample }
                phase += phaseIncrement
                if phase >= 1.0 { phase -= 1.0 }
            }

        case .whiteNoise(let level):
            let amplitude = PrcFmt.fromDB(PrcFmt(level))
            for i in 0..<frames {
                let sample = amplitude * PrcFmt.random(in: -1...1)
                for ch in 0..<channels { waveforms[ch][i] = sample }
            }
        }

        return AudioChunk(waveforms: waveforms)
    }

    public func close() {}
}
