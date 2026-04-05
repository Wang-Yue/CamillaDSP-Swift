// AppState+Devices - Audio device management, sample rate detection, and device listeners

import CoreAudio
import CamillaDSPLib

extension AppState {

    // MARK: - Device Management

    func refreshDevices() {
        captureDevices = CoreAudioCapture.listDevices().map { (id: $0.id, name: $0.name) }
        playbackDevices = CoreAudioPlayback.listDevices().map { (id: $0.id, name: $0.name) }
        refreshAvailableSampleRates()
    }

    func refreshAvailableSampleRates() {
        availableCaptureSampleRates = CoreAudioCapture.deviceAvailableSampleRates(name: selectedCaptureDevice)
        availablePlaybackSampleRates = CoreAudioPlayback.deviceAvailableSampleRates(name: selectedPlaybackDevice)
        let capSet = Set(availableCaptureSampleRates)
        commonSampleRates = availablePlaybackSampleRates.filter { capSet.contains($0) }
    }

    func detectSampleRate() {
        if let rate = CoreAudioCapture.deviceSampleRate(name: selectedCaptureDevice), rate > 0 {
            let detected = Int(rate)
            if detected != captureSampleRate {
                logger.info("Detected capture sample rate change: \(captureSampleRate) → \(detected) Hz")
                isLoadingPreferences = true
                captureSampleRate = detected
                if !resamplerEnabled {
                    // Without resampler, output must match input
                    playbackSampleRate = detected
                }
                isLoadingPreferences = false
                restartIfRunning()
            }
        }
    }

    /// Set the capture device's hardware sample rate (like Audio MIDI Setup does)
    func setHardwareSampleRate(_ rate: Int, deviceID: AudioDeviceID?, label: String) {
        guard let deviceID = deviceID else { return }
        var newRate = Float64(rate)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(deviceID, &rateAddr, 0, nil,
                                                 UInt32(MemoryLayout<Float64>.size), &newRate)
        if status == noErr {
            logger.info("Set \(label) device sample rate to \(rate) Hz")
        } else {
            logger.warning("Failed to set \(label) device sample rate: \(status)")
        }
    }

    /// Set hardware sample rates on the actual audio devices before engine restart
    func applyHardwareSampleRates() {
        setHardwareSampleRate(captureSampleRate, deviceID: captureDeviceID(), label: "capture")
        setHardwareSampleRate(playbackSampleRate, deviceID: playbackDeviceID(), label: "playback")
    }

    /// Resolve the AudioDeviceID for the selected capture device
    func captureDeviceID() -> AudioDeviceID? {
        if let name = selectedCaptureDevice {
            return captureDevices.first(where: { $0.name == name })?.id
        }
        // Default input device
        var defaultID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultID)
        return defaultID
    }

    func startDeviceChangeListener() {
        // Listen for device list changes (plug/unplug)
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.refreshDevices()
        }

        // Listen for sample rate changes on the capture device (e.g. from Audio MIDI Setup)
        startSampleRateListener()
    }

    func startSampleRateListener() {
        // Remove old listener if device changed
        if let oldID = sampleRateListenerDeviceID {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(oldID, &addr, DispatchQueue.main, sampleRateListenerBlock)
        }

        guard let deviceID = captureDeviceID() else { return }
        sampleRateListenerDeviceID = deviceID

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &addr, DispatchQueue.main, sampleRateListenerBlock)
    }

    // MARK: - Device Alive Monitoring

    func startDeviceAliveListeners() {
        stopDeviceAliveListeners()

        if let capID = captureDeviceID() {
            aliveListenerCaptureID = capID
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(capID, &addr, DispatchQueue.main, deviceAliveBlock)
        }
        if let pbID = playbackDeviceID() {
            aliveListenerPlaybackID = pbID
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(pbID, &addr, DispatchQueue.main, deviceAliveBlock)
        }
    }

    func stopDeviceAliveListeners() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let id = aliveListenerCaptureID {
            AudioObjectRemovePropertyListenerBlock(id, &addr, DispatchQueue.main, deviceAliveBlock)
            aliveListenerCaptureID = nil
        }
        if let id = aliveListenerPlaybackID {
            AudioObjectRemovePropertyListenerBlock(id, &addr, DispatchQueue.main, deviceAliveBlock)
            aliveListenerPlaybackID = nil
        }
    }

    func isDeviceAlive(_ deviceID: AudioDeviceID?) -> Bool {
        guard let deviceID = deviceID else { return true }  // default device always "alive"
        var alive: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &alive)
        return status == noErr && alive != 0
    }

    /// Resolve the AudioDeviceID for the selected playback device
    func playbackDeviceID() -> AudioDeviceID? {
        if let name = selectedPlaybackDevice {
            return playbackDevices.first(where: { $0.name == name })?.id
        }
        var defaultID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultID)
        return defaultID
    }

    /// Check if required devices are available before starting
    func devicesAvailable() -> Bool {
        // If using a named device, verify it's in the list
        if let name = selectedCaptureDevice {
            if !captureDevices.contains(where: { $0.name == name }) {
                lastError = "Capture device '\(name)' not available"
                return false
            }
        }
        if let name = selectedPlaybackDevice {
            if !playbackDevices.contains(where: { $0.name == name }) {
                lastError = "Playback device '\(name)' not available"
                return false
            }
        }
        return isDeviceAlive(captureDeviceID()) && isDeviceAlive(playbackDeviceID())
    }
}
