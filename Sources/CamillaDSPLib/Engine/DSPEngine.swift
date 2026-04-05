// CamillaDSP-Swift: Main DSP engine - coordinates capture, processing, and playback threads

import Foundation
import Logging

/// The main CamillaDSP engine that coordinates all threads
public final class DSPEngine {
    private let logger = Logger(label: "camilladsp.engine")

    // Configuration
    public private(set) var currentConfig: CamillaDSPConfig
    public let processingParams: ProcessingParameters

    // State
    public private(set) var state: EngineState = .inactive
    private var stopReason: StopReason?
    private var shouldStop = false

    // Components
    private var capture: CaptureBackend?
    private var playback: PlaybackBackend?
    private var pipeline: Pipeline?
    private var resampler: AudioResampler?
    private var webSocketServer: WebSocketServer?

    // Threading
    private var captureThread: Thread?
    private var processingThread: Thread?
    private var playbackThread: Thread?
    private let chunkQueue = DispatchQueue(label: "camilladsp.chunks", attributes: .concurrent)
    private var capturedChunks: [AudioChunk] = []
    private var processedChunks: [AudioChunk] = []
    private let chunkSemaphore = DispatchSemaphore(value: 0)
    private let playbackSemaphore = DispatchSemaphore(value: 0)
    private let chunkLock = NSLock()

    // Rate adjustment
    private var rateAdjustTimer: Timer?
    private var bufferLevelHistory: [Int] = []
    /// Serialises access to resampler.ratio between the rate-adjust timer
    /// (runs on the main/RunLoop thread) and the processing thread.
    private let resamplerRatioLock = NSLock()

    /// Optional callback invoked before pipeline processing, on the processing thread.
    /// Receives the raw captured audio (post-resample, pre-pipeline).
    public var onChunkCaptured: ((_ chunk: AudioChunk) -> Void)?

    /// Optional callback invoked after pipeline processing, on the processing thread.
    /// Receives the processed audio (post-pipeline, pre-playback).
    public var onChunkProcessed: ((_ chunk: AudioChunk) -> Void)?

    public init(config: CamillaDSPConfig) {
        self.currentConfig = config
        self.processingParams = ProcessingParameters()
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard state == .inactive else {
            logger.warning("Engine already running")
            return
        }

        state = .starting
        shouldStop = false
        logger.info("Starting CamillaDSP engine")

        // Create backends
        capture = try createCaptureBackend(config: currentConfig)
        playback = try createPlaybackBackend(config: currentConfig)

        // Create resampler if configured
        if let resamplerConfig = currentConfig.devices.resampler {
            resampler = createResampler(config: resamplerConfig,
                                        inputRate: currentConfig.devices.samplerate,
                                        outputRate: currentConfig.devices.samplerate,
                                        channels: currentConfig.devices.capture.channels)
        }

        // Create pipeline
        pipeline = try Pipeline(config: currentConfig, processingParams: processingParams)

        // Open devices
        try capture?.open()
        try playback?.open()

        // Start threads
        captureThread = Thread { [weak self] in self?.captureLoop() }
        captureThread?.qualityOfService = .userInteractive
        captureThread?.name = "camilladsp.capture"
        captureThread?.start()

        processingThread = Thread { [weak self] in self?.processingLoop() }
        processingThread?.qualityOfService = .userInteractive
        processingThread?.name = "camilladsp.processing"
        processingThread?.start()

        playbackThread = Thread { [weak self] in self?.playbackLoop() }
        playbackThread?.qualityOfService = .userInteractive
        playbackThread?.name = "camilladsp.playback"
        playbackThread?.start()

        // Start rate adjustment if enabled
        if currentConfig.devices.enableRateAdjust == true {
            startRateAdjustment()
        }

        state = .running
        logger.info("CamillaDSP engine started: \(currentConfig.devices.samplerate)Hz, chunk=\(currentConfig.devices.chunksize)")
    }

    public func stop(reason: StopReason = .userRequest) {
        guard state != .inactive else { return }

        logger.info("Stopping engine: \(reason)")
        shouldStop = true
        stopReason = reason

        // Signal semaphores to unblock threads
        chunkSemaphore.signal()
        playbackSemaphore.signal()

        rateAdjustTimer?.invalidate()

        // Wait for threads to finish
        Thread.sleep(forTimeInterval: 0.1)

        capture?.close()
        playback?.close()

        state = .inactive
        logger.info("Engine stopped")
    }

    public func reloadConfig(_ newConfig: CamillaDSPConfig) throws {
        logger.info("Reloading configuration")

        // If device settings changed, need full restart
        let devicesChanged = currentConfig.devices.samplerate != newConfig.devices.samplerate
            || currentConfig.devices.chunksize != newConfig.devices.chunksize
            || currentConfig.devices.capture.device != newConfig.devices.capture.device
            || currentConfig.devices.playback.device != newConfig.devices.playback.device
            || currentConfig.devices.capture.channels != newConfig.devices.capture.channels
            || currentConfig.devices.playback.channels != newConfig.devices.playback.channels

        if devicesChanged {
            logger.info("Device settings changed, full restart")
            let wasRunning = state == .running
            if wasRunning { stop(reason: .configChanged) }
            currentConfig = newConfig
            if wasRunning { try start() }
        } else {
            // Only rebuild pipeline — no audio device restart needed
            currentConfig = newConfig
            if state == .running {
                pipeline = try Pipeline(config: currentConfig, processingParams: processingParams)
                logger.info("Pipeline rebuilt without restart")
            }
        }
    }

    // MARK: - Thread Loops

    private func captureLoop() {
        logger.info("Capture thread started")
        let chunkSize = currentConfig.devices.chunksize
        var chunkCount = 0

        while !shouldStop {
            do {
                guard let chunk = try capture?.read(frames: chunkSize) else {
                    if !shouldStop {
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    continue
                }

                chunkCount += 1
                if chunkCount == 1 || chunkCount % 200 == 0 {
                    let peaks = chunk.peakDB()
                    logger.info("Capture chunk #\(chunkCount): \(chunk.frames) frames, \(chunk.channels)ch, peak=\(peaks)")
                }

                // Update capture signal levels
                processingParams.captureSignalPeak = chunk.peakDB()
                processingParams.captureSignalRms = chunk.rmsDB()

                // Enqueue for processing
                chunkLock.lock()
                capturedChunks.append(chunk)
                chunkLock.unlock()
                chunkSemaphore.signal()

            } catch {
                logger.error("Capture error: \(error)")
                stop(reason: .captureError("\(error)"))
                return
            }
        }
        logger.info("Capture thread stopped")
    }

    private func processingLoop() {
        logger.info("Processing thread started")

        // Set real-time thread priority
        setRealtimePriority()

        var processedCount = 0

        while !shouldStop {
            chunkSemaphore.wait()
            if shouldStop { break }

            chunkLock.lock()
            guard !capturedChunks.isEmpty else {
                chunkLock.unlock()
                continue
            }
            var chunk = capturedChunks.removeFirst()
            chunkLock.unlock()

            processedCount += 1

            do {
                let startTime = DispatchTime.now()

                // Resample if needed.
                // Acquire resamplerRatioLock so that a concurrent rate-adjust timer
                // cannot mutate the ratio while process() reads it.
                if let resampler = resampler {
                    resamplerRatioLock.lock()
                    defer { resamplerRatioLock.unlock() }
                    chunk = try resampler.process(chunk: chunk)
                }

                // Pre-processing tap for visualization
                onChunkCaptured?(chunk)

                // Process through pipeline
                try pipeline?.process(chunk: &chunk)

                // Measure processing load (covers resample + pipeline)
                let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
                let chunkDuration = Double(currentConfig.devices.chunksize) / Double(currentConfig.devices.samplerate) * 1_000_000_000.0
                processingParams.processingLoad = Double(elapsed) / chunkDuration * 100.0

                // Update playback signal levels
                processingParams.playbackSignalPeak = chunk.peakDB()
                processingParams.playbackSignalRms = chunk.rmsDB()

                // Post-processing tap for visualization
                onChunkProcessed?(chunk)

                // Enqueue for playback
                chunkLock.lock()
                processedChunks.append(chunk)
                chunkLock.unlock()
                playbackSemaphore.signal()

            } catch {
                logger.error("Processing error: \(error)")
                stop(reason: .processingError("\(error)"))
                return
            }
        }
        logger.info("Processing thread stopped")
    }

    private func playbackLoop() {
        logger.info("Playback thread started")

        while !shouldStop {
            playbackSemaphore.wait()
            if shouldStop { break }

            chunkLock.lock()
            guard !processedChunks.isEmpty else {
                chunkLock.unlock()
                continue
            }
            let chunk = processedChunks.removeFirst()
            chunkLock.unlock()

            do {
                try playback?.write(chunk: chunk)
            } catch {
                logger.error("Playback error: \(error)")
                stop(reason: .playbackError("\(error)"))
                return
            }
        }
        logger.info("Playback thread stopped")
    }

    // MARK: - Rate Adjustment

    private func startRateAdjustment() {
        let period = currentConfig.devices.adjustPeriod ?? 10.0
        let targetLevel = currentConfig.devices.targetLevel ?? 500

        rateAdjustTimer = Timer.scheduledTimer(withTimeInterval: period, repeats: true) { [weak self] _ in
            guard let self = self, let playback = self.playback, let resampler = self.resampler else { return }

            let level = playback.bufferLevel
            self.bufferLevelHistory.append(level)
            if self.bufferLevelHistory.count > 10 {
                self.bufferLevelHistory.removeFirst()
            }

            let avgLevel = self.bufferLevelHistory.reduce(0, +) / self.bufferLevelHistory.count
            let error = Double(avgLevel - targetLevel)

            // PID-like adjustment.
            // Hold resamplerRatioLock so that the processing thread cannot call
            // resampler.process() (which reads the ratio) while we update it.
            self.resamplerRatioLock.lock()
            let newRatio = resampler.ratio * (1.0 + (-error * 0.0001))
            resampler.setRatio(newRatio)
            self.resamplerRatioLock.unlock()

            self.logger.debug("Rate adjust: buffer=\(level), ratio=\(String(format: "%.6f", newRatio))")
        }
    }

    // MARK: - Helpers

    private func setRealtimePriority() {
        var policy = thread_time_constraint_policy_data_t(
            period: 0,
            computation: UInt32(5_000_000),    // 5ms
            constraint: UInt32(10_000_000),     // 10ms
            preemptible: 1
        )
        let thread = mach_thread_self()
        _ = withUnsafeMutablePointer(to: &policy) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(THREAD_TIME_CONSTRAINT_POLICY_COUNT)) { intPtr in
                thread_policy_set(thread, UInt32(THREAD_TIME_CONSTRAINT_POLICY),
                                  intPtr, THREAD_TIME_CONSTRAINT_POLICY_COUNT)
            }
        }
    }

    private func createCaptureBackend(config: CamillaDSPConfig) throws -> CaptureBackend {
        let captureConfig = config.devices.capture
        let sr = config.devices.samplerate
        let cs = config.devices.chunksize

        switch captureConfig.type {
        case .coreAudio:
            return CoreAudioCapture(config: captureConfig, sampleRate: sr, chunkSize: cs)
        case .rawFile:
            return RawFileCapture(path: captureConfig.device ?? "/dev/stdin",
                                  channels: captureConfig.channels,
                                  sampleRate: sr,
                                  format: captureConfig.format ?? .float32)
        case .stdin:
            return StdinCapture(channels: captureConfig.channels,
                                sampleRate: sr,
                                format: captureConfig.format ?? .float32)
        case .signalGenerator:
            // Default to a -20 dBFS 1 kHz sine if no signal params are provided in config.
            let signalConfig = captureConfig.signal ?? .sine(freq: 1000.0, level: -20.0)
            return SignalGeneratorCapture(channels: captureConfig.channels,
                                         sampleRate: sr,
                                         signal: signalConfig)
        default:
            throw AudioBackendError.initializationFailed("Unsupported capture type: \(captureConfig.type)")
        }
    }

    private func createPlaybackBackend(config: CamillaDSPConfig) throws -> PlaybackBackend {
        let playbackConfig = config.devices.playback
        let sr = config.devices.samplerate

        switch playbackConfig.type {
        case .coreAudio:
            return CoreAudioPlayback(config: playbackConfig, sampleRate: sr,
                                     chunkSize: config.devices.chunksize)
        case .rawFile:
            return RawFilePlayback(path: playbackConfig.device ?? "/dev/stdout",
                                   channels: playbackConfig.channels,
                                   format: playbackConfig.format ?? .float32)
        case .stdout:
            return StdoutPlayback(channels: playbackConfig.channels,
                                  format: playbackConfig.format ?? .float32)
        default:
            throw AudioBackendError.initializationFailed("Unsupported playback type: \(playbackConfig.type)")
        }
    }

    private func createResampler(config: ResamplerConfig, inputRate: Int, outputRate: Int, channels: Int) -> AudioResampler {
        switch config.type {
        case .asyncSinc:
            return AsyncSincResampler(channels: channels, inputRate: inputRate, outputRate: outputRate,
                                      profile: config.profile ?? .balanced)
        case .asyncPoly:
            return AsyncPolyResampler(channels: channels, inputRate: inputRate, outputRate: outputRate,
                                      interpolation: .cubic)
        case .synchronous:
            return SynchronousResampler(channels: channels, inputRate: inputRate, outputRate: outputRate)
        }
    }
}

// MARK: - Thread-safety helpers

private let THREAD_TIME_CONSTRAINT_POLICY_COUNT = mach_msg_type_number_t(
    MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size
)
