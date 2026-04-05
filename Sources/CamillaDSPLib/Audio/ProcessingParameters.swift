// CamillaDSP-Swift: Shared processing state (volume faders, mute, load metrics)

import Foundation

/// Fader identifiers
public enum Fader: String, CaseIterable, Codable, Sendable {
    case main = "Main"
    case aux1 = "Aux1"
    case aux2 = "Aux2"
    case aux3 = "Aux3"
    case aux4 = "Aux4"

    /// Integer index for array access
    public var index: Int {
        switch self {
        case .main: return 0
        case .aux1: return 1
        case .aux2: return 2
        case .aux3: return 3
        case .aux4: return 4
        }
    }
}

/// Thread-safe shared processing parameters
public final class ProcessingParameters: @unchecked Sendable {
    /// Number of faders available
    public static let numFaders = Fader.allCases.count
    /// Default volume (dB) for newly-initialised faders
    public static let defaultVolume: PrcFmt = 0.0
    /// Default mute state
    public static let defaultMute = false

    private let lock = NSLock()

    /// Target volume in dB for each fader
    private var targetVolume: [PrcFmt]
    /// Current (ramped) volume in dB for each fader
    private var currentVolume: [PrcFmt]
    /// Mute state for each fader
    private var muted: [Bool]
    /// Processing load percentage (0-100)
    private var _processingLoad: Double = 0
    /// Resampler load percentage (0-100)
    private var _resamplerLoad: Double = 0
    /// Capture rate (actual measured)
    private var _captureRate: Double = 0
    /// Rate adjustment factor (1.0 = no adjustment)
    private var _rateAdjust: Double = 1.0
    /// Playback buffer level in frames
    private var _bufferLevel: Int = 0
    /// Number of clipped samples since last reset
    private var _clippedSamples: Int = 0
    /// Signal range (max absolute sample value in current capture chunk, linear)
    private var _signalRange: Double = 0.0
    /// Update interval (milliseconds between level updates)
    private var _updateInterval: Int = 100

    /// Capture signal peak per channel (dB)
    private var _captureSignalPeak: [PrcFmt] = []
    /// Capture signal RMS per channel (dB)
    private var _captureSignalRms: [PrcFmt] = []
    /// Playback signal peak per channel (dB)
    private var _playbackSignalPeak: [PrcFmt] = []
    /// Playback signal RMS per channel (dB)
    private var _playbackSignalRms: [PrcFmt] = []

    /// Peak levels since start (capture), linear — updated every chunk via element-wise max
    private var _capturePeaksSinceStart: [PrcFmt] = []
    /// Peak levels since start (playback), linear — updated every chunk via element-wise max
    private var _playbackPeaksSinceStart: [PrcFmt] = []

    /// Stop reason from last engine stop (nil if never stopped or running)
    private var _stopReason: StopReason?

    public init() {
        let count = Fader.allCases.count
        targetVolume = Array(repeating: 0.0, count: count)
        currentVolume = Array(repeating: 0.0, count: count)
        muted = Array(repeating: false, count: count)
    }

    // MARK: - Volume

    public func setTargetVolume(_ fader: Fader, _ db: PrcFmt) {
        lock.lock()
        targetVolume[fader.index] = db
        lock.unlock()
    }

    public func getTargetVolume(_ fader: Fader) -> PrcFmt {
        lock.lock()
        defer { lock.unlock() }
        return targetVolume[fader.index]
    }

    public func setCurrentVolume(_ fader: Fader, _ db: PrcFmt) {
        lock.lock()
        currentVolume[fader.index] = db
        lock.unlock()
    }

    public func getCurrentVolume(_ fader: Fader) -> PrcFmt {
        lock.lock()
        defer { lock.unlock() }
        return currentVolume[fader.index]
    }

    public func adjustVolume(_ fader: Fader, by db: PrcFmt) {
        lock.lock()
        targetVolume[fader.index] += db
        lock.unlock()
    }

    /// Adjust volume with optional clamping. Returns the new volume.
    public func adjustVolumeClamped(_ fader: Fader, by db: PrcFmt, min minDB: PrcFmt = -150.0, max maxDB: PrcFmt = 50.0) -> PrcFmt {
        lock.lock()
        var vol = targetVolume[fader.index] + db
        vol = Swift.min(Swift.max(vol, minDB), maxDB)
        targetVolume[fader.index] = vol
        lock.unlock()
        return vol
    }

    /// Get all target volumes as an array
    public func allVolumes() -> [PrcFmt] {
        lock.lock()
        defer { lock.unlock() }
        return targetVolume
    }

    /// Get all mute states as an array
    public func allMutes() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return muted
    }

    /// Clamp a volume value to safe range (-150..+50 dB)
    public static func clampVolume(_ vol: PrcFmt) -> PrcFmt {
        return Swift.min(Swift.max(vol, -150.0), 50.0)
    }

    // MARK: - Mute

    public func setMute(_ fader: Fader, _ mute: Bool) {
        lock.lock()
        muted[fader.index] = mute
        lock.unlock()
    }

    public func isMuted(_ fader: Fader) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return muted[fader.index]
    }

    /// Toggle mute and return the **previous** mute state (before toggling).
    @discardableResult
    public func toggleMute(_ fader: Fader) -> Bool {
        lock.lock()
        let previous = muted[fader.index]
        muted[fader.index].toggle()
        lock.unlock()
        return previous
    }

    // MARK: - Metrics

    public var processingLoad: Double {
        get { lock.lock(); defer { lock.unlock() }; return _processingLoad }
        set { lock.lock(); _processingLoad = newValue; lock.unlock() }
    }

    public var captureRate: Double {
        get { lock.lock(); defer { lock.unlock() }; return _captureRate }
        set { lock.lock(); _captureRate = newValue; lock.unlock() }
    }

    public var captureSignalPeak: [PrcFmt] {
        get { lock.lock(); defer { lock.unlock() }; return _captureSignalPeak }
        set { lock.lock(); _captureSignalPeak = newValue; lock.unlock() }
    }

    public var captureSignalRms: [PrcFmt] {
        get { lock.lock(); defer { lock.unlock() }; return _captureSignalRms }
        set { lock.lock(); _captureSignalRms = newValue; lock.unlock() }
    }

    public var playbackSignalPeak: [PrcFmt] {
        get { lock.lock(); defer { lock.unlock() }; return _playbackSignalPeak }
        set { lock.lock(); _playbackSignalPeak = newValue; lock.unlock() }
    }

    public var playbackSignalRms: [PrcFmt] {
        get { lock.lock(); defer { lock.unlock() }; return _playbackSignalRms }
        set { lock.lock(); _playbackSignalRms = newValue; lock.unlock() }
    }

    // MARK: - New metrics for WebSocket parity

    public var resamplerLoad: Double {
        get { lock.lock(); defer { lock.unlock() }; return _resamplerLoad }
        set { lock.lock(); _resamplerLoad = newValue; lock.unlock() }
    }

    public var rateAdjust: Double {
        get { lock.lock(); defer { lock.unlock() }; return _rateAdjust }
        set { lock.lock(); _rateAdjust = newValue; lock.unlock() }
    }

    public var bufferLevel: Int {
        get { lock.lock(); defer { lock.unlock() }; return _bufferLevel }
        set { lock.lock(); _bufferLevel = newValue; lock.unlock() }
    }

    public var clippedSamples: Int {
        get { lock.lock(); defer { lock.unlock() }; return _clippedSamples }
        set { lock.lock(); _clippedSamples = newValue; lock.unlock() }
    }

    /// Atomically increment clipped samples counter
    public func addClippedSamples(_ count: Int) {
        lock.lock()
        _clippedSamples += count
        lock.unlock()
    }

    public var signalRange: Double {
        get { lock.lock(); defer { lock.unlock() }; return _signalRange }
        set { lock.lock(); _signalRange = newValue; lock.unlock() }
    }

    public var updateInterval: Int {
        get { lock.lock(); defer { lock.unlock() }; return _updateInterval }
        set { lock.lock(); _updateInterval = newValue; lock.unlock() }
    }

    public var stopReason: StopReason? {
        get { lock.lock(); defer { lock.unlock() }; return _stopReason }
        set { lock.lock(); _stopReason = newValue; lock.unlock() }
    }

    // MARK: - Peaks since start

    public var capturePeaksSinceStart: [PrcFmt] {
        get { lock.lock(); defer { lock.unlock() }; return _capturePeaksSinceStart }
        set { lock.lock(); _capturePeaksSinceStart = newValue; lock.unlock() }
    }

    public var playbackPeaksSinceStart: [PrcFmt] {
        get { lock.lock(); defer { lock.unlock() }; return _playbackPeaksSinceStart }
        set { lock.lock(); _playbackPeaksSinceStart = newValue; lock.unlock() }
    }

    /// Update peaks-since-start with the latest per-channel peak values (dB).
    /// Keeps the element-wise maximum.
    public func updateCapturePeaksSinceStart(_ peaks: [PrcFmt]) {
        lock.lock()
        if _capturePeaksSinceStart.count != peaks.count {
            _capturePeaksSinceStart = peaks
        } else {
            for i in peaks.indices {
                _capturePeaksSinceStart[i] = Swift.max(_capturePeaksSinceStart[i], peaks[i])
            }
        }
        lock.unlock()
    }

    /// Update peaks-since-start with the latest per-channel peak values (dB).
    /// Keeps the element-wise maximum.
    public func updatePlaybackPeaksSinceStart(_ peaks: [PrcFmt]) {
        lock.lock()
        if _playbackPeaksSinceStart.count != peaks.count {
            _playbackPeaksSinceStart = peaks
        } else {
            for i in peaks.indices {
                _playbackPeaksSinceStart[i] = Swift.max(_playbackPeaksSinceStart[i], peaks[i])
            }
        }
        lock.unlock()
    }

    /// Reset peaks-since-start for both capture and playback
    public func resetPeaksSinceStart() {
        lock.lock()
        _capturePeaksSinceStart = Array(repeating: -1000.0, count: _capturePeaksSinceStart.count)
        _playbackPeaksSinceStart = Array(repeating: -1000.0, count: _playbackPeaksSinceStart.count)
        lock.unlock()
    }
}
