// AppState+Engine - DSP engine control, config building, and volume management

import SwiftUI
import CamillaDSPLib

extension AppState {

    // MARK: - Engine Control

    func startEngine() {
        guard !isRunning else { return }
        lastError = nil
        lastAppliedConfigYAML = nil

        guard devicesAvailable() else {
            logger.warning("Cannot start: \(lastError ?? "device unavailable")")
            return
        }

        do {
            // Set hardware rates before opening audio devices
            isLoadingPreferences = true  // suppress listener feedback
            applyHardwareSampleRates()
            // Small delay to let CoreAudio settle after rate change
            Thread.sleep(forTimeInterval: 0.1)
            isLoadingPreferences = false

            let config = buildConfig()
            logger.info("Starting engine: capture=\(selectedCaptureDevice ?? "default"), playback=\(selectedPlaybackDevice ?? "default"), \(sampleRate)Hz, chunk=\(chunkSize)")
            engine = DSPEngine(config: config)
            try engine?.start()
            isRunning = true
            engineState = .running

            engine?.processingParams.setMute(.main, isMuted)

            if isInitialStartup {
                // Soft start on first launch: ramp from -30dB to target over 4s
                isInitialStartup = false
                let targetVolume = volume
                let softStartFrom = -30.0
                engine?.processingParams.setTargetVolume(.main, softStartFrom)
                volume = softStartFrom  // move slider to start position
                startSoftRamp(from: softStartFrom, to: targetVolume)
            } else {
                engine?.processingParams.setTargetVolume(.main, volume)
            }

            // Spectrum analyzer on its own background thread
            recreateSpectrumAnalyzer()
            wireSpectrumTap()

            startMonitoring()
            startDeviceAliveListeners()
            logger.info("Engine started successfully")
        } catch {
            let msg = "Failed to start engine: \(error)"
            logger.error("\(msg)")
            lastError = msg
            engineState = .inactive
        }
    }

    func stopEngine() {
        softStartTimer?.invalidate()
        softStartTimer = nil
        stopDeviceAliveListeners()
        stopMonitoring()
        engine?.stop()
        engine = nil
        spectrumAnalyzer = nil
        isRunning = false
        engineState = .inactive
        meters.reset()
        logger.info("Engine stopped")
    }

    func restartEngine() {
        stopEngine()
        startEngine()
    }

    func startSoftRamp(from startDB: Double, to targetDB: Double) {
        softStartTimer?.invalidate()
        isSoftRamping = true
        let steps = 80  // 80 steps × 50ms = 4 seconds
        softRampStep = 0
        softRampTarget = targetDB
        softRampIncrement = (targetDB - startDB) / Double(steps)
        softRampCurrent = startDB
        softStartTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self = self else { timer.invalidate(); return }
                self.softRampStep += 1
                self.softRampCurrent += self.softRampIncrement
                if self.softRampStep >= steps {
                    self.softRampCurrent = self.softRampTarget
                    self.isSoftRamping = false
                    self.defaults.set(self.softRampTarget, forKey: Keys.volume)
                    timer.invalidate()
                }
                // Update both engine volume and UI slider
                self.engine?.processingParams.setTargetVolume(.main, self.softRampCurrent)
                self.volume = self.softRampCurrent
            }
        }
    }

    // MARK: - Live Config Update

    func applyConfig() {
        savePipelineStages()

        guard isRunning, let engine = engine else { return }
        let config = buildConfig()

        // Skip if nothing actually changed (prevents spurious restarts from SwiftUI view init)
        let yaml = (try? ConfigLoader.toYAML(config)) ?? ""
        if yaml == lastAppliedConfigYAML { return }
        lastAppliedConfigYAML = yaml

        do {
            try engine.reloadConfig(config)
            logger.info("Config applied live")
        } catch {
            logger.error("Failed to apply config: \(error)")
        }
    }

    func setVolume(_ db: Double) {
        volume = db
        engine?.processingParams.setTargetVolume(.main, db)
    }

    func toggleMute() {
        isMuted.toggle()
        engine?.processingParams.setMute(.main, isMuted)
    }

    // MARK: - Config Builder

    func buildConfig() -> CamillaDSPConfig {
        var devices = DevicesConfig(
            samplerate: sampleRate,
            chunksize: chunkSize,
            capture: CaptureDeviceConfig(type: .coreAudio, channels: captureChannels, device: selectedCaptureDevice),
            playback: PlaybackDeviceConfig(type: .coreAudio, channels: playbackChannels, device: selectedPlaybackDevice, exclusive: exclusiveMode ? true : nil)
        )
        devices.enableRateAdjust = enableRateAdjust
        if resamplerEnabled, let type = ResamplerType(rawValue: resamplerType) {
            let profile = ResamplerProfile(rawValue: resamplerProfile)
            devices.resampler = ResamplerConfig(type: type, profile: profile)
        }
        var config = CamillaDSPConfig(devices: devices)

        var filters: [String: FilterConfig] = [:]
        var mixers: [String: MixerConfig] = [:]
        var pipelineSteps: [PipelineStep] = []

        for stage in stages {
            let stageFilters = stage.buildFilters()
            let stageMixers = stage.buildMixers()
            let stageSteps = stage.buildPipelineSteps()

            for (k, v) in stageFilters { filters[k] = v }
            for (k, v) in stageMixers { mixers[k] = v }
            pipelineSteps.append(contentsOf: stageSteps)

            // EQ stage uses presets
            if stage.type == .eq && stage.isActive {
                let eqFilters = stage.buildEQFilters(presets: eqPresets)
                let eqSteps = stage.buildEQPipelineSteps(presets: eqPresets)
                for (k, v) in eqFilters { filters[k] = v }
                pipelineSteps.append(contentsOf: eqSteps)
            }
        }

        config.filters = filters.isEmpty ? nil : filters
        config.mixers = mixers.isEmpty ? nil : mixers
        config.pipeline = pipelineSteps.isEmpty ? nil : pipelineSteps

        return config
    }
}
