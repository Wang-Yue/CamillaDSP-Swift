// AppState - Central observable state for the entire app
// Manages DSP engine, pipeline stages, audio monitoring, and device selection
// Auto-saves user preferences to UserDefaults

import SwiftUI
import Combine
import CoreAudio
import CamillaDSPLib
import Logging

@MainActor
final class AppState: ObservableObject {
    let logger = Logger(label: "monitor.appstate")
    let defaults = UserDefaults.standard

    // MARK: - Engine State (not persisted)
    @Published var engineState: EngineState = .inactive
    @Published var isRunning: Bool = false
    @Published var lastError: String?

    // MARK: - Devices (persisted)
    @Published var captureDevices: [(id: UInt32, name: String)] = []
    @Published var playbackDevices: [(id: UInt32, name: String)] = []
    @Published var availableCaptureSampleRates: [Int] = []
    @Published var availablePlaybackSampleRates: [Int] = []
    @Published var commonSampleRates: [Int] = []  // intersection of capture + playback
    @Published var selectedCaptureDevice: String? = nil {
        didSet {
            defaults.set(selectedCaptureDevice, forKey: Keys.captureDevice)
            refreshAvailableSampleRates()
            detectSampleRate()
            startSampleRateListener()
            restartIfRunning()
        }
    }
    @Published var selectedPlaybackDevice: String? = nil {
        didSet {
            defaults.set(selectedPlaybackDevice, forKey: Keys.playbackDevice)
            refreshAvailableSampleRates()
            restartIfRunning()
        }
    }
    @Published var captureChannels: Int = 2 {
        didSet { defaults.set(captureChannels, forKey: Keys.captureChannels); restartIfRunning() }
    }
    @Published var playbackChannels: Int = 2 {
        didSet { defaults.set(playbackChannels, forKey: Keys.playbackChannels); restartIfRunning() }
    }
    @Published var exclusiveMode: Bool = false {
        didSet { defaults.set(exclusiveMode, forKey: Keys.exclusiveMode); restartIfRunning() }
    }

    // MARK: - Processing (persisted)
    @Published var captureSampleRate: Int = 48000 {
        didSet {
            defaults.set(captureSampleRate, forKey: Keys.captureSampleRate)
            restartIfRunning()
        }
    }
    @Published var playbackSampleRate: Int = 48000 {
        didSet {
            defaults.set(playbackSampleRate, forKey: Keys.playbackSampleRate)
            if !resamplerEnabled && !isLoadingPreferences {
                // When resampler is off, capture rate follows playback rate
                if captureSampleRate != playbackSampleRate {
                    captureSampleRate = playbackSampleRate
                }
            }
            restartIfRunning()
        }
    }
    /// Convenience: the pipeline sample rate (= capture rate)
    var sampleRate: Int { captureSampleRate }
    @Published var chunkSize: Int = 1024 {
        didSet { defaults.set(chunkSize, forKey: Keys.chunkSize); restartIfRunning() }
    }
    @Published var enableRateAdjust: Bool = false {
        didSet { defaults.set(enableRateAdjust, forKey: Keys.enableRateAdjust); restartIfRunning() }
    }
    @Published var resamplerEnabled: Bool = false {
        didSet {
            defaults.set(resamplerEnabled, forKey: Keys.resamplerEnabled)
            if !resamplerEnabled && !isLoadingPreferences {
                // Sync capture rate to playback rate when disabling resampler
                if captureSampleRate != playbackSampleRate {
                    captureSampleRate = playbackSampleRate
                }
            }
            restartIfRunning()
        }
    }
    @Published var resamplerType: String = ResamplerType.asyncSinc.rawValue {
        didSet { defaults.set(resamplerType, forKey: Keys.resamplerType); restartIfRunning() }
    }
    @Published var resamplerProfile: String = ResamplerProfile.balanced.rawValue {
        didSet { defaults.set(resamplerProfile, forKey: Keys.resamplerProfile); restartIfRunning() }
    }

    // MARK: - Volume (persisted)
    var isSoftRamping = false
    @Published var volume: Double = 0.0 {
        didSet { if !isSoftRamping { defaults.set(volume, forKey: Keys.volume) } }
    }
    @Published var isMuted: Bool = false {
        didSet { defaults.set(isMuted, forKey: Keys.isMuted) }
    }

    // MARK: - Pipeline Stages (persisted)
    @Published var stages: [PipelineStage] = PipelineStage.defaultStages()

    // MARK: - EQ Presets (persisted)
    @Published var eqPresets: [EQPreset] = []

    // MARK: - Monitoring (separate observable to avoid re-rendering the entire UI)
    let meters = MeterState()

    // MARK: - Spectrum mode (persisted)
    @Published var spectrumMode: SpectrumMode = .fft {
        didSet {
            defaults.set(spectrumMode.rawValue, forKey: Keys.spectrumMode)
            recreateSpectrumAnalyzer()
            wireSpectrumTap()
        }
    }
    @Published var spectrumSource: SpectrumSource = .postProcessing {
        didSet {
            defaults.set(spectrumSource.rawValue, forKey: Keys.spectrumSource)
            wireSpectrumTap()
        }
    }

    // MARK: - Internal
    var engine: DSPEngine?
    var monitorTimer: DispatchSourceTimer?
    var isLoadingPreferences = false  // suppress restarts during init
    var spectrumAnalyzer: SpectrumAnalyzerProtocol?
    var softStartTimer: Timer?
    var isInitialStartup = true  // only soft-ramp on first launch

    // Soft ramp state
    var softRampStep = 0
    var softRampTarget = 0.0
    var softRampIncrement = 0.0
    var softRampCurrent = 0.0

    // Live config update
    var lastAppliedConfigYAML: String?

    // Device listener state
    var sampleRateListenerDeviceID: AudioDeviceID?
    var aliveListenerCaptureID: AudioDeviceID?
    var aliveListenerPlaybackID: AudioDeviceID?

    lazy var sampleRateListenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.detectSampleRate()
    }

    lazy var deviceAliveBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self = self else { return }
        if !self.isDeviceAlive(self.captureDeviceID()) || !self.isDeviceAlive(self.playbackDeviceID()) {
            self.logger.warning("Audio device disconnected — stopping engine")
            self.stopEngine()
            self.lastError = "Audio device disconnected"
        }
    }

    // MARK: - UserDefaults Keys

    enum Keys {
        static let captureDevice = "captureDevice"
        static let playbackDevice = "playbackDevice"
        static let captureChannels = "captureChannels"
        static let playbackChannels = "playbackChannels"
        static let captureSampleRate = "captureSampleRate"
        static let playbackSampleRate = "playbackSampleRate"
        static let chunkSize = "chunkSize"
        static let volume = "volume"
        static let isMuted = "isMuted"
        static let enableRateAdjust = "enableRateAdjust"
        static let exclusiveMode = "exclusiveMode"
        static let resamplerEnabled = "resamplerEnabled"
        static let resamplerType = "resamplerType"
        static let resamplerProfile = "resamplerProfile"
        static let spectrumMode = "spectrumMode"
        static let spectrumSource = "spectrumSource"
    }

    // MARK: - Init

    init() {
        isLoadingPreferences = true
        loadPreferences()
        eqPresets = loadEQPresets()
        createDefaultEQPresetsIfNeeded()
        loadPipelineStages()
        isLoadingPreferences = false
        refreshDevices()
        detectSampleRate()
        startDeviceChangeListener()

        // Auto-start the engine on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startEngine()
        }
    }

    func restartIfRunning() {
        guard !isLoadingPreferences, isRunning else { return }
        restartEngine()
    }

    private func loadPreferences() {
        selectedCaptureDevice = defaults.string(forKey: Keys.captureDevice)
        selectedPlaybackDevice = defaults.string(forKey: Keys.playbackDevice)

        let savedCaptureChannels = defaults.integer(forKey: Keys.captureChannels)
        captureChannels = savedCaptureChannels > 0 ? savedCaptureChannels : 2

        let savedPlaybackChannels = defaults.integer(forKey: Keys.playbackChannels)
        playbackChannels = savedPlaybackChannels > 0 ? savedPlaybackChannels : 2

        let savedCapRate = defaults.integer(forKey: Keys.captureSampleRate)
        if savedCapRate > 0 { captureSampleRate = savedCapRate }
        let savedPbRate = defaults.integer(forKey: Keys.playbackSampleRate)
        if savedPbRate > 0 { playbackSampleRate = savedPbRate }

        let savedChunkSize = defaults.integer(forKey: Keys.chunkSize)
        chunkSize = savedChunkSize > 0 ? savedChunkSize : 1024

        volume = defaults.double(forKey: Keys.volume)
        isMuted = defaults.bool(forKey: Keys.isMuted)
        enableRateAdjust = defaults.bool(forKey: Keys.enableRateAdjust)
        exclusiveMode = defaults.bool(forKey: Keys.exclusiveMode)
        resamplerEnabled = defaults.bool(forKey: Keys.resamplerEnabled)
        if let t = defaults.string(forKey: Keys.resamplerType), !t.isEmpty { resamplerType = t }
        if let p = defaults.string(forKey: Keys.resamplerProfile), !p.isEmpty { resamplerProfile = p }
        if let saved = defaults.string(forKey: Keys.spectrumMode), let mode = SpectrumMode(rawValue: saved) {
            spectrumMode = mode
        }
        if let saved = defaults.string(forKey: Keys.spectrumSource), let src = SpectrumSource(rawValue: saved) {
            spectrumSource = src
        }
    }
}
