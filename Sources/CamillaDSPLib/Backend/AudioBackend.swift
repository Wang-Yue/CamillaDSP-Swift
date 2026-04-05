// CamillaDSP-Swift: Audio backend protocols

import Foundation

/// Engine state
public enum EngineState: String, Codable, Sendable {
    case inactive = "Inactive"
    case starting = "Starting"
    case running = "Running"
    case paused = "Paused"
    case stalled = "Stalled"
}

/// Reason for stopping
public enum StopReason: Sendable {
    case doneProcessing
    case captureError(String)
    case playbackError(String)
    case processingError(String)
    case captureFormatChanged
    case configChanged
    case userRequest
}

/// Protocol for audio capture backends
public protocol CaptureBackend: AnyObject {
    /// Open the capture device
    func open() throws
    /// Read a chunk of audio. Returns nil on end-of-stream.
    func read(frames: Int) throws -> AudioChunk?
    /// Close the capture device
    func close()
    /// Get the actual sample rate (may differ from configured if device adjusts)
    var actualSampleRate: Double { get }
}

/// Protocol for audio playback backends
public protocol PlaybackBackend: AnyObject {
    /// Open the playback device
    func open() throws
    /// Write a chunk of audio
    func write(chunk: AudioChunk) throws
    /// Close the playback device
    func close()
    /// Get the current playback buffer level in samples
    var bufferLevel: Int { get }
}
