// CamillaDSP-Swift: WebSocket control server
// Provides runtime control API compatible with CamillaDSP's protocol

import Foundation
import Network
import Logging

// MARK: - JSON Response Helpers

/// Result codes matching Rust CamillaDSP WsResult
private enum WsResult: String {
    case ok = "Ok"
    case invalidFaderError = "InvalidFaderError"
    case configValidationError = "ConfigValidationError"
    case configReadError = "ConfigReadError"
    case invalidValueError = "InvalidValueError"
    case invalidRequestError = "InvalidRequestError"
}

/// Encode a JSON response with result and optional value
private func jsonReply(_ command: String, result: WsResult, value: String? = nil) -> String {
    if let value = value {
        return "{\"\(command)\":{\"result\":\"\(result.rawValue)\",\"value\":\(value)}}"
    }
    return "{\"\(command)\":{\"result\":\"\(result.rawValue)\"}}"
}

/// Encode an array of PrcFmt as a JSON array string
private func jsonArray(_ values: [PrcFmt]) -> String {
    return "[\(values.map { String($0) }.joined(separator: ","))]"
}

/// Encode an array of Int as a JSON array string
private func jsonIntArray(_ values: [Int]) -> String {
    return "[\(values.map { String($0) }.joined(separator: ","))]"
}

// MARK: - WebSocket Server

/// WebSocket command handler
public final class WebSocketServer {
    private let logger = Logger(label: "camilladsp.websocket")
    private let port: UInt16
    private let host: String
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    // References to engine state
    private weak var engine: DSPEngine?
    private let processingParams: ProcessingParameters

    // State tracking (mirrors Rust SharedData fields)
    /// Current config file path (set via SetConfigFilePath or at startup)
    public var configFilePath: String?
    /// State file path for persisting volumes/mutes across restarts
    public var stateFilePath: String?
    /// YAML of the config before the last reload
    public var previousConfig: String?
    /// Whether state file has unsaved changes (volumes/mutes changed since last save)
    public var unsavedStateChanges: Bool = false
    /// Current active config (mutable for PatchConfig/SetConfigValue)
    public var activeConfig: CamillaDSPConfig?

    public init(port: UInt16, host: String = "127.0.0.1", processingParams: ProcessingParameters) {
        self.port = port
        self.host = host
        self.processingParams = processingParams
    }

    public func setEngine(_ engine: DSPEngine) {
        self.engine = engine
        self.activeConfig = engine.currentConfig
    }

    public func start() throws {
        let params = NWParameters(tls: nil)
        let wsOptions = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.info("WebSocket server listening on \(self?.host ?? ""):\(self?.port ?? 0)")
            case .failed(let error):
                self?.logger.error("WebSocket server failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: DispatchQueue(label: "camilladsp.websocket.listener"))
    }

    public func stop() {
        listener?.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
        logger.info("WebSocket server stopped")
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connections.append(connection)

        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.connections.removeAll { $0 === connection }
            }
        }

        connection.start(queue: DispatchQueue(label: "camilladsp.websocket.connection"))
        receiveMessage(from: connection)
    }

    private func receiveMessage(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self = self, let data = data else { return }

            if let message = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               message.opcode == .text {
                if let text = String(data: data, encoding: .utf8) {
                    let response = self.handleCommand(text)
                    self.send(response, to: connection)
                }
            }

            // Continue receiving
            self.receiveMessage(from: connection)
        }
    }

    private func send(_ text: String, to connection: NWConnection) {
        let data = text.data(using: .utf8)!
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    // MARK: - Command Handler

    private func handleCommand(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Simple string commands (quoted, e.g. "GetVersion")
        let simpleCommand = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        switch simpleCommand {

        // ----------------------------------------------------------------
        // Version / State
        // ----------------------------------------------------------------

        case "GetVersion":
            return jsonReply("GetVersion", result: .ok, value: "\"CamillaDSP-Swift 1.0.0\"")

        case "GetState":
            let state = engine?.state.rawValue ?? EngineState.inactive.rawValue
            return jsonReply("GetState", result: .ok, value: "\"\(state)\"")

        case "GetStopReason":
            let reason = stopReasonString(processingParams.stopReason)
            return jsonReply("GetStopReason", result: .ok, value: "\"\(reason)\"")

        // ----------------------------------------------------------------
        // Volume / Mute (fader 0 = main)
        // ----------------------------------------------------------------

        case "GetVolume":
            let vol = processingParams.getTargetVolume(.main)
            return jsonReply("GetVolume", result: .ok, value: "\(vol)")

        case "GetMute":
            let muted = processingParams.isMuted(.main)
            return jsonReply("GetMute", result: .ok, value: "\(muted)")

        case "ToggleMute":
            let wasMuted = processingParams.toggleMute(.main)
            unsavedStateChanges = true
            return jsonReply("ToggleMute", result: .ok, value: "\(!wasMuted)")

        case "GetFaders":
            let volumes = processingParams.allVolumes()
            let mutes = processingParams.allMutes()
            var faders: [String] = []
            for i in 0..<volumes.count {
                faders.append("{\"volume\":\(volumes[i]),\"mute\":\(mutes[i])}")
            }
            return jsonReply("GetFaders", result: .ok, value: "[\(faders.joined(separator: ","))]")

        // ----------------------------------------------------------------
        // Signal levels (instantaneous)
        // ----------------------------------------------------------------

        case "GetCaptureSignalRms":
            let rms = processingParams.captureSignalRms
            return jsonReply("GetCaptureSignalRms", result: .ok, value: jsonArray(rms))

        case "GetCaptureSignalPeak":
            let peaks = processingParams.captureSignalPeak
            return jsonReply("GetCaptureSignalPeak", result: .ok, value: jsonArray(peaks))

        case "GetPlaybackSignalRms":
            let rms = processingParams.playbackSignalRms
            return jsonReply("GetPlaybackSignalRms", result: .ok, value: jsonArray(rms))

        case "GetPlaybackSignalPeak":
            let peaks = processingParams.playbackSignalPeak
            return jsonReply("GetPlaybackSignalPeak", result: .ok, value: jsonArray(peaks))

        // ----------------------------------------------------------------
        // Signal levels - "Since" variants (simplified: return current values)
        // ----------------------------------------------------------------

        case "GetCaptureSignalRmsSinceLast":
            let rms = processingParams.captureSignalRms
            return jsonReply("GetCaptureSignalRmsSinceLast", result: .ok, value: jsonArray(rms))

        case "GetCaptureSignalPeakSinceLast":
            let peaks = processingParams.captureSignalPeak
            return jsonReply("GetCaptureSignalPeakSinceLast", result: .ok, value: jsonArray(peaks))

        case "GetPlaybackSignalRmsSinceLast":
            let rms = processingParams.playbackSignalRms
            return jsonReply("GetPlaybackSignalRmsSinceLast", result: .ok, value: jsonArray(rms))

        case "GetPlaybackSignalPeakSinceLast":
            let peaks = processingParams.playbackSignalPeak
            return jsonReply("GetPlaybackSignalPeakSinceLast", result: .ok, value: jsonArray(peaks))

        // ----------------------------------------------------------------
        // Combined signal levels
        // ----------------------------------------------------------------

        case "GetSignalLevels":
            return signalLevelsResponse("GetSignalLevels")

        case "GetSignalLevelsSinceLast":
            return signalLevelsResponse("GetSignalLevelsSinceLast")

        // ----------------------------------------------------------------
        // Peaks since start
        // ----------------------------------------------------------------

        case "GetSignalPeaksSinceStart":
            let capPeaks = processingParams.capturePeaksSinceStart
            let pbPeaks = processingParams.playbackPeaksSinceStart
            let value = "{\"playback\":\(jsonArray(pbPeaks)),\"capture\":\(jsonArray(capPeaks))}"
            return jsonReply("GetSignalPeaksSinceStart", result: .ok, value: value)

        case "ResetSignalPeaksSinceStart":
            processingParams.resetPeaksSinceStart()
            return jsonReply("ResetSignalPeaksSinceStart", result: .ok)

        // ----------------------------------------------------------------
        // Signal range
        // ----------------------------------------------------------------

        case "GetSignalRange":
            let range = processingParams.signalRange
            return jsonReply("GetSignalRange", result: .ok, value: "\(range)")

        // ----------------------------------------------------------------
        // Capture rate & rate adjust
        // ----------------------------------------------------------------

        case "GetCaptureRate":
            let rate = processingParams.captureRate
            return jsonReply("GetCaptureRate", result: .ok, value: "\(Int(rate))")

        case "GetRateAdjust":
            let adj = processingParams.rateAdjust
            return jsonReply("GetRateAdjust", result: .ok, value: "\(adj)")

        // ----------------------------------------------------------------
        // Buffer, clipping, load
        // ----------------------------------------------------------------

        case "GetBufferLevel":
            let level = processingParams.bufferLevel
            return jsonReply("GetBufferLevel", result: .ok, value: "\(level)")

        case "GetClippedSamples":
            let clipped = processingParams.clippedSamples
            return jsonReply("GetClippedSamples", result: .ok, value: "\(clipped)")

        case "ResetClippedSamples":
            processingParams.clippedSamples = 0
            return jsonReply("ResetClippedSamples", result: .ok)

        case "GetProcessingLoad":
            let load = processingParams.processingLoad
            return jsonReply("GetProcessingLoad", result: .ok, value: "\(load)")

        case "GetResamplerLoad":
            let load = processingParams.resamplerLoad
            return jsonReply("GetResamplerLoad", result: .ok, value: "\(load)")

        // ----------------------------------------------------------------
        // Update interval
        // ----------------------------------------------------------------

        case "GetUpdateInterval":
            let interval = processingParams.updateInterval
            return jsonReply("GetUpdateInterval", result: .ok, value: "\(interval)")

        // ----------------------------------------------------------------
        // Supported device types
        // ----------------------------------------------------------------

        case "GetSupportedDeviceTypes":
            // Report capture and playback backend types supported on this platform
            let captureTypes = ["CoreAudio", "Stdin", "RawFile", "SignalGenerator"]
            let playbackTypes = ["CoreAudio", "Stdout", "RawFile"]
            let capJson = "[\(captureTypes.map { "\"\($0)\"" }.joined(separator: ","))]"
            let pbJson = "[\(playbackTypes.map { "\"\($0)\"" }.joined(separator: ","))]"
            return jsonReply("GetSupportedDeviceTypes", result: .ok, value: "[\(capJson),\(pbJson)]")

        // ----------------------------------------------------------------
        // Device listing
        // ----------------------------------------------------------------

        case "GetAvailableCaptureDevices":
            let devices = CoreAudioCapture.listDevices()
            let json = devices.map { "[\"\($0.name)\",\"\($0.id)\"]" }.joined(separator: ",")
            return jsonReply("GetAvailableCaptureDevices", result: .ok, value: "[\(json)]")

        case "GetAvailablePlaybackDevices":
            let devices = CoreAudioPlayback.listDevices()
            let json = devices.map { "[\"\($0.name)\",\"\($0.id)\"]" }.joined(separator: ",")
            return jsonReply("GetAvailablePlaybackDevices", result: .ok, value: "[\(json)]")

        // ----------------------------------------------------------------
        // Config queries
        // ----------------------------------------------------------------

        case "GetConfigFilePath":
            if let path = configFilePath {
                return jsonReply("GetConfigFilePath", result: .ok, value: "\"\(escapeJsonString(path))\"")
            }
            return jsonReply("GetConfigFilePath", result: .ok, value: "null")

        case "GetPreviousConfig":
            if let prev = previousConfig {
                return jsonReply("GetPreviousConfig", result: .ok, value: "\"\(escapeJsonString(prev))\"")
            }
            return jsonReply("GetPreviousConfig", result: .ok, value: "\"\"")

        case "GetStateFilePath":
            if let path = stateFilePath {
                return jsonReply("GetStateFilePath", result: .ok, value: "\"\(escapeJsonString(path))\"")
            }
            return jsonReply("GetStateFilePath", result: .ok, value: "null")

        case "GetStateFileUpdated":
            let updated = !unsavedStateChanges
            return jsonReply("GetStateFileUpdated", result: .ok, value: "\(updated)")

        case "GetChannelLabels":
            return handleGetChannelLabels()

        case "GetConfig":
            if let config = engine?.currentConfig,
               let yaml = try? ConfigLoader.toYAML(config) {
                let escaped = escapeJsonString(yaml)
                return jsonReply("GetConfig", result: .ok, value: "\"\(escaped)\"")
            }
            return jsonReply("GetConfig", result: .ok, value: "\"\"")

        case "GetConfigJson":
            if let config = engine?.currentConfig,
               let jsonData = try? JSONEncoder().encode(config),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                let escaped = escapeJsonString(jsonString)
                return jsonReply("GetConfigJson", result: .ok, value: "\"\(escaped)\"")
            }
            return jsonReply("GetConfigJson", result: .ok, value: "\"\"")

        case "GetConfigTitle":
            let title = engine?.currentConfig.title ?? ""
            return jsonReply("GetConfigTitle", result: .ok, value: "\"\(escapeJsonString(title))\"")

        case "GetConfigDescription":
            let desc = engine?.currentConfig.description ?? ""
            return jsonReply("GetConfigDescription", result: .ok, value: "\"\(escapeJsonString(desc))\"")

        // ----------------------------------------------------------------
        // Reload
        // ----------------------------------------------------------------

        case "Reload":
            return handleReload()

        // ----------------------------------------------------------------
        // Lifecycle
        // ----------------------------------------------------------------

        case "Stop":
            engine?.stop(reason: .userRequest)
            return jsonReply("Stop", result: .ok)

        case "Exit":
            engine?.stop(reason: .userRequest)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                exit(0)
            }
            return jsonReply("Exit", result: .ok)

        default:
            // Try JSON object commands
            return handleJSONCommand(trimmed)
        }
    }

    // MARK: - JSON Object Commands

    private func handleJSONCommand(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "{\"Invalid\":{\"error\":\"Invalid command: could not parse JSON\"}}"
        }

        // ----------------------------------------------------------------
        // SetVolume
        // ----------------------------------------------------------------
        if let volume = json["SetVolume"] as? Double {
            let clamped = ProcessingParameters.clampVolume(volume)
            processingParams.setTargetVolume(.main, clamped)
            unsavedStateChanges = true
            return jsonReply("SetVolume", result: .ok)
        }

        // ----------------------------------------------------------------
        // AdjustVolume - supports plain value or [value, min, max]
        // ----------------------------------------------------------------
        if let adjust = json["AdjustVolume"] {
            return handleAdjustVolume(adjust, faderIndex: 0)
        }

        // ----------------------------------------------------------------
        // SetMute
        // ----------------------------------------------------------------
        if let mute = json["SetMute"] as? Bool {
            processingParams.setMute(.main, mute)
            unsavedStateChanges = true
            return jsonReply("SetMute", result: .ok)
        }

        // ----------------------------------------------------------------
        // SetUpdateInterval
        // ----------------------------------------------------------------
        if let interval = json["SetUpdateInterval"] as? Int {
            processingParams.updateInterval = interval
            return jsonReply("SetUpdateInterval", result: .ok)
        }

        // ----------------------------------------------------------------
        // Fader commands (array-style: {"GetFaderVolume": 0})
        // ----------------------------------------------------------------

        if let idx = json["GetFaderVolume"] as? Int {
            guard let fader = faderForIndex(idx) else {
                return jsonReply("GetFaderVolume", result: .invalidFaderError,
                                 value: "[\(idx),\(ProcessingParameters.defaultVolume)]")
            }
            let vol = processingParams.getTargetVolume(fader)
            return jsonReply("GetFaderVolume", result: .ok, value: "[\(idx),\(vol)]")
        }

        if let arr = json["SetFaderVolume"] as? [Any], arr.count >= 2,
           let idx = arr[0] as? Int, let vol = arr[1] as? Double {
            guard let fader = faderForIndex(idx) else {
                return jsonReply("SetFaderVolume", result: .invalidFaderError)
            }
            let clamped = ProcessingParameters.clampVolume(vol)
            processingParams.setTargetVolume(fader, clamped)
            unsavedStateChanges = true
            return jsonReply("SetFaderVolume", result: .ok)
        }

        if let arr = json["SetFaderExternalVolume"] as? [Any], arr.count >= 2,
           let idx = arr[0] as? Int, let vol = arr[1] as? Double {
            guard let fader = faderForIndex(idx) else {
                return jsonReply("SetFaderExternalVolume", result: .invalidFaderError)
            }
            let clamped = ProcessingParameters.clampVolume(vol)
            processingParams.setTargetVolume(fader, clamped)
            processingParams.setCurrentVolume(fader, clamped)
            unsavedStateChanges = true
            return jsonReply("SetFaderExternalVolume", result: .ok)
        }

        if let arr = json["AdjustFaderVolume"] as? [Any], arr.count >= 2,
           let idx = arr[0] as? Int {
            guard let fader = faderForIndex(idx) else {
                return jsonReply("AdjustFaderVolume", result: .invalidFaderError,
                                 value: "[\(idx),0.0]")
            }
            let volArg = arr.count > 1 ? arr[1] : nil
            return handleAdjustFaderVolume(fader: fader, index: idx, volArg: volArg,
                                           extraArgs: arr.count > 2 ? Array(arr[2...]) : [])
        }

        if let idx = json["GetFaderMute"] as? Int {
            guard let fader = faderForIndex(idx) else {
                return jsonReply("GetFaderMute", result: .invalidFaderError,
                                 value: "[\(idx),\(ProcessingParameters.defaultMute)]")
            }
            let muted = processingParams.isMuted(fader)
            return jsonReply("GetFaderMute", result: .ok, value: "[\(idx),\(muted)]")
        }

        if let arr = json["SetFaderMute"] as? [Any], arr.count >= 2,
           let idx = arr[0] as? Int, let mute = arr[1] as? Bool {
            guard let fader = faderForIndex(idx) else {
                return jsonReply("SetFaderMute", result: .invalidFaderError)
            }
            processingParams.setMute(fader, mute)
            unsavedStateChanges = true
            return jsonReply("SetFaderMute", result: .ok)
        }

        if let idx = json["ToggleFaderMute"] as? Int {
            guard let fader = faderForIndex(idx) else {
                return jsonReply("ToggleFaderMute", result: .invalidFaderError,
                                 value: "[\(idx),\(ProcessingParameters.defaultMute)]")
            }
            let wasMuted = processingParams.toggleMute(fader)
            unsavedStateChanges = true
            return jsonReply("ToggleFaderMute", result: .ok, value: "[\(idx),\(!wasMuted)]")
        }

        // ----------------------------------------------------------------
        // Signal levels with "Since" parameter
        // ----------------------------------------------------------------

        if let secs = json["GetCaptureSignalRmsSince"] as? Double {
            _ = secs  // simplified: return current values
            let rms = processingParams.captureSignalRms
            return jsonReply("GetCaptureSignalRmsSince", result: .ok, value: jsonArray(rms))
        }

        if let secs = json["GetCaptureSignalPeakSince"] as? Double {
            _ = secs
            let peaks = processingParams.captureSignalPeak
            return jsonReply("GetCaptureSignalPeakSince", result: .ok, value: jsonArray(peaks))
        }

        if let secs = json["GetPlaybackSignalRmsSince"] as? Double {
            _ = secs
            let rms = processingParams.playbackSignalRms
            return jsonReply("GetPlaybackSignalRmsSince", result: .ok, value: jsonArray(rms))
        }

        if let secs = json["GetPlaybackSignalPeakSince"] as? Double {
            _ = secs
            let peaks = processingParams.playbackSignalPeak
            return jsonReply("GetPlaybackSignalPeakSince", result: .ok, value: jsonArray(peaks))
        }

        if let secs = json["GetSignalLevelsSince"] as? Double {
            _ = secs
            return signalLevelsResponse("GetSignalLevelsSince")
        }

        // ----------------------------------------------------------------
        // Config commands with payload
        // ----------------------------------------------------------------

        if let configYaml = json["SetConfig"] as? String {
            return handleSetConfig(yaml: configYaml)
        }

        if let configJson = json["SetConfigJson"] as? String {
            return handleSetConfigJson(configJson)
        }

        if let configYaml = json["ValidateConfig"] as? String {
            return handleValidateConfig(yaml: configYaml, commandName: "ValidateConfig")
        }

        if let configJson = json["ValidateConfigJson"] as? String {
            return handleValidateConfigJson(configJson)
        }

        // ----------------------------------------------------------------
        // Config file path management
        // ----------------------------------------------------------------

        if let path = json["SetConfigFilePath"] as? String {
            return handleSetConfigFilePath(path)
        }

        if let path = json["ReadConfig"] as? String {
            return handleReadConfigFromDisk(path, commandName: "ReadConfig")
        }

        if let path = json["ReadConfigFile"] as? String {
            return handleReadConfigFromDisk(path, commandName: "ReadConfigFile")
        }

        if let path = json["ReadConfigJson"] as? String {
            return handleReadConfigJsonFromDisk(path)
        }

        if let pointer = json["GetConfigValue"] as? String {
            return handleGetConfigValue(pointer)
        }

        if let patchValue = json["SetConfigValue"] as? [String: Any],
           let pointer = patchValue["pointer"] as? String ?? (patchValue.keys.first.flatMap { $0 != "value" ? $0 : nil }),
           let newValue = patchValue["value"] ?? patchValue[pointer] {
            guard var config = activeConfig else {
                return jsonReply("SetConfigValue", result: .invalidRequestError, value: "\"No active config to modify\"")
            }
            do {
                var configJSON = try jsonFromConfig(config)
                if setValueAtPointer(&configJSON, pointer: pointer, value: newValue) {
                    let data = try JSONSerialization.data(withJSONObject: configJSON)
                    config = try JSONDecoder().decode(CamillaDSPConfig.self, from: data)
                    try ConfigLoader.validate(config)
                    try engine?.reloadConfig(config)
                    activeConfig = config
                    return jsonReply("SetConfigValue", result: .ok)
                } else {
                    return jsonReply("SetConfigValue", result: .invalidRequestError, value: "\"Path not found: \(pointer)\"")
                }
            } catch {
                return jsonReply("SetConfigValue", result: .invalidRequestError, value: "\"\(error)\"")
            }
        }

        if let patchData = json["PatchConfig"] {
            guard var config = activeConfig else {
                return jsonReply("PatchConfig", result: .invalidRequestError, value: "\"No active config to patch\"")
            }
            do {
                var configJSON = try jsonFromConfig(config)
                if let patch = patchData as? [String: Any] {
                    mergeJSON(&configJSON, patch: patch)
                }
                let data = try JSONSerialization.data(withJSONObject: configJSON)
                config = try JSONDecoder().decode(CamillaDSPConfig.self, from: data)
                try ConfigLoader.validate(config)
                try engine?.reloadConfig(config)
                activeConfig = config
                return jsonReply("PatchConfig", result: .ok)
            } catch {
                return jsonReply("PatchConfig", result: .invalidRequestError, value: "\"\(error)\"")
            }
        }

        // ----------------------------------------------------------------
        // Device listing with backend parameter
        // ----------------------------------------------------------------

        if let _ = json["GetAvailableCaptureDevices"] as? String {
            let devices = CoreAudioCapture.listDevices()
            let devJson = devices.map { "[\"\($0.name)\",\"\($0.id)\"]" }.joined(separator: ",")
            return jsonReply("GetAvailableCaptureDevices", result: .ok, value: "[\(devJson)]")
        }

        if let _ = json["GetAvailablePlaybackDevices"] as? String {
            let devices = CoreAudioPlayback.listDevices()
            let devJson = devices.map { "[\"\($0.name)\",\"\($0.id)\"]" }.joined(separator: ",")
            return jsonReply("GetAvailablePlaybackDevices", result: .ok, value: "[\(devJson)]")
        }

        return "{\"Invalid\":{\"error\":\"Unknown command\"}}"
    }

    // MARK: - Command Helpers

    private func signalLevelsResponse(_ commandName: String) -> String {
        let capRms = processingParams.captureSignalRms
        let capPeak = processingParams.captureSignalPeak
        let pbRms = processingParams.playbackSignalRms
        let pbPeak = processingParams.playbackSignalPeak
        let value = """
        {"playback_rms":\(jsonArray(pbRms)),"playback_peak":\(jsonArray(pbPeak)),\
        "capture_rms":\(jsonArray(capRms)),"capture_peak":\(jsonArray(capPeak))}
        """
        return jsonReply(commandName, result: .ok, value: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func handleReload() -> String {
        guard let engine = engine else {
            return jsonReply("Reload", result: .invalidRequestError,
                             value: nil)
        }
        guard let path = configFilePath else {
            return jsonReply("Reload", result: .invalidRequestError,
                             value: nil)
        }
        do {
            // Save previous config YAML before reloading
            if let currentYaml = try? ConfigLoader.toYAML(engine.currentConfig) {
                previousConfig = currentYaml
            }
            let newConfig = try ConfigLoader.load(from: path)
            try engine.reloadConfig(newConfig)
            return jsonReply("Reload", result: .ok)
        } catch {
            return jsonReply("Reload", result: .configReadError)
        }
    }

    private func handleSetConfig(yaml: String) -> String {
        do {
            let config = try ConfigLoader.parse(yaml: yaml)
            try engine?.reloadConfig(config)
            return jsonReply("SetConfig", result: .ok)
        } catch is ConfigError {
            return jsonReply("SetConfig", result: .configValidationError)
        } catch {
            return jsonReply("SetConfig", result: .configReadError)
        }
    }

    private func handleSetConfigJson(_ jsonString: String) -> String {
        do {
            guard let data = jsonString.data(using: .utf8) else {
                return jsonReply("SetConfigJson", result: .configReadError)
            }
            let config = try JSONDecoder().decode(CamillaDSPConfig.self, from: data)
            try ConfigLoader.validate(config)
            try engine?.reloadConfig(config)
            return jsonReply("SetConfigJson", result: .ok)
        } catch is ConfigError {
            return jsonReply("SetConfigJson", result: .configValidationError)
        } catch {
            return jsonReply("SetConfigJson", result: .configReadError)
        }
    }

    private func handleValidateConfig(yaml: String, commandName: String) -> String {
        do {
            let config = try ConfigLoader.parse(yaml: yaml)
            if let yamlOut = try? ConfigLoader.toYAML(config) {
                return jsonReply(commandName, result: .ok,
                                 value: "\"\(escapeJsonString(yamlOut))\"")
            }
            return jsonReply(commandName, result: .ok, value: "\"\"")
        } catch let error as ConfigError {
            return jsonReply(commandName, result: .configValidationError,
                             value: "\"\(escapeJsonString(error.description))\"")
        } catch {
            return jsonReply(commandName, result: .configReadError,
                             value: "\"\(escapeJsonString("\(error)"))\"")
        }
    }

    private func handleValidateConfigJson(_ jsonString: String) -> String {
        do {
            guard let data = jsonString.data(using: .utf8) else {
                return jsonReply("ValidateConfigJson", result: .configReadError,
                                 value: "\"Failed to read JSON\"")
            }
            let config = try JSONDecoder().decode(CamillaDSPConfig.self, from: data)
            try ConfigLoader.validate(config)
            if let jsonData = try? JSONEncoder().encode(config),
               let out = String(data: jsonData, encoding: .utf8) {
                return jsonReply("ValidateConfigJson", result: .ok,
                                 value: "\"\(escapeJsonString(out))\"")
            }
            return jsonReply("ValidateConfigJson", result: .ok, value: "\"\"")
        } catch let error as ConfigError {
            return jsonReply("ValidateConfigJson", result: .configValidationError,
                             value: "\"\(escapeJsonString(error.description))\"")
        } catch {
            return jsonReply("ValidateConfigJson", result: .configReadError,
                             value: "\"\(escapeJsonString("\(error)"))\"")
        }
    }

    /// Handle AdjustVolume for main fader (fader 0).
    /// Accepts a plain number or an array [change, min, max].
    private func handleAdjustVolume(_ value: Any, faderIndex: Int) -> String {
        var change: Double = 0
        var minVol: Double = -150.0
        var maxVol: Double = 50.0

        if let plain = value as? Double {
            change = plain
        } else if let arr = value as? [Double] {
            if arr.count >= 1 { change = arr[0] }
            if arr.count >= 3 { minVol = arr[1]; maxVol = arr[2] }
        } else {
            return jsonReply("AdjustVolume", result: .invalidValueError,
                             value: "\(processingParams.getTargetVolume(.main))")
        }

        if maxVol < minVol {
            return jsonReply("AdjustVolume", result: .invalidValueError,
                             value: "\(processingParams.getTargetVolume(.main))")
        }

        let newVol = processingParams.adjustVolumeClamped(.main, by: change, min: minVol, max: maxVol)
        unsavedStateChanges = true
        return jsonReply("AdjustVolume", result: .ok, value: "\(newVol)")
    }

    /// Handle AdjustFaderVolume for a specific fader.
    private func handleAdjustFaderVolume(fader: Fader, index: Int, volArg: Any?, extraArgs: [Any]) -> String {
        var change: Double = 0
        var minVol: Double = -150.0
        var maxVol: Double = 50.0

        if let plain = volArg as? Double {
            change = plain
            // Check for [idx, change, min, max] style
            if extraArgs.count >= 2, let mn = extraArgs[0] as? Double, let mx = extraArgs[1] as? Double {
                minVol = mn; maxVol = mx
            }
        } else if let arr = volArg as? [Double] {
            if arr.count >= 1 { change = arr[0] }
            if arr.count >= 3 { minVol = arr[1]; maxVol = arr[2] }
        }

        if maxVol < minVol {
            let curVol = processingParams.getTargetVolume(fader)
            return jsonReply("AdjustFaderVolume", result: .invalidValueError,
                             value: "[\(index),\(curVol)]")
        }

        let newVol = processingParams.adjustVolumeClamped(fader, by: change, min: minVol, max: maxVol)
        unsavedStateChanges = true
        return jsonReply("AdjustFaderVolume", result: .ok, value: "[\(index),\(newVol)]")
    }

    // MARK: - Config File & State Helpers

    private func handleSetConfigFilePath(_ path: String) -> String {
        // Validate by attempting to load the file
        do {
            _ = try ConfigLoader.load(from: path)
            configFilePath = path
            unsavedStateChanges = true
            return jsonReply("SetConfigFilePath", result: .ok)
        } catch {
            logger.debug("Error setting config file path: \(error)")
            return jsonReply("SetConfigFilePath", result: .invalidValueError,
                             value: "\"\(escapeJsonString("\(error)"))\"")
        }
    }

    /// Read a YAML config file from disk and return its content as YAML
    private func handleReadConfigFromDisk(_ path: String, commandName: String) -> String {
        do {
            let yaml = try String(contentsOfFile: path, encoding: .utf8)
            // Validate it parses as a config, then re-serialize
            let config = try ConfigLoader.parse(yaml: yaml)
            let normalized = try ConfigLoader.toYAML(config)
            return jsonReply(commandName, result: .ok,
                             value: "\"\(escapeJsonString(normalized))\"")
        } catch {
            logger.debug("Error reading config file '\(path)': \(error)")
            return jsonReply(commandName, result: .configReadError,
                             value: "\"\(escapeJsonString("\(error)"))\"")
        }
    }

    /// Read a YAML config file from disk and return it as JSON
    private func handleReadConfigJsonFromDisk(_ path: String) -> String {
        do {
            let yaml = try String(contentsOfFile: path, encoding: .utf8)
            let config = try ConfigLoader.parse(yaml: yaml)
            let jsonData = try JSONEncoder().encode(config)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            return jsonReply("ReadConfigJson", result: .ok,
                             value: "\"\(escapeJsonString(jsonString))\"")
        } catch {
            logger.debug("Error reading config file '\(path)': \(error)")
            return jsonReply("ReadConfigJson", result: .configReadError,
                             value: "\"\(escapeJsonString("\(error)"))\"")
        }
    }

    /// Get a value from the current config using a JSON pointer path (e.g. "/devices/samplerate")
    private func handleGetConfigValue(_ pointer: String) -> String {
        guard let config = engine?.currentConfig else {
            return jsonReply("GetConfigValue", result: .invalidRequestError,
                             value: "null")
        }
        do {
            let jsonData = try JSONEncoder().encode(config)
            let jsonObj = try JSONSerialization.jsonObject(with: jsonData)
            // Walk the JSON pointer path
            let components = pointer.split(separator: "/").map(String.init)
            var current: Any = jsonObj
            for component in components {
                if component.isEmpty { continue }
                if let dict = current as? [String: Any], let next = dict[component] {
                    current = next
                } else if let arr = current as? [Any], let idx = Int(component), idx < arr.count {
                    current = arr[idx]
                } else {
                    return jsonReply("GetConfigValue", result: .invalidRequestError,
                                     value: "null")
                }
            }
            // Serialize the found value back to JSON
            let valueData = try JSONSerialization.data(withJSONObject: current)
            let valueString = String(data: valueData, encoding: .utf8) ?? "null"
            return jsonReply("GetConfigValue", result: .ok, value: valueString)
        } catch {
            return jsonReply("GetConfigValue", result: .invalidRequestError,
                             value: "null")
        }
    }

    /// Return channel labels from the active config
    private func handleGetChannelLabels() -> String {
        let config = engine?.currentConfig
        let captureLabels = config?.devices.capture.labels
        let playbackLabels = config?.devices.playback.labels

        func labelsJson(_ labels: [String?]?) -> String {
            guard let labels = labels else { return "null" }
            let items = labels.map { item -> String in
                if let s = item { return "\"\(escapeJsonString(s))\"" }
                return "null"
            }
            return "[\(items.joined(separator: ","))]"
        }

        let value = "{\"playback\":\(labelsJson(playbackLabels)),\"capture\":\(labelsJson(captureLabels))}"
        return jsonReply("GetChannelLabels", result: .ok, value: value)
    }

    // MARK: - Utilities

    private func faderForIndex(_ idx: Int) -> Fader? {
        return Fader.allCases.first { $0.index == idx }
    }

    private func stopReasonString(_ reason: StopReason?) -> String {
        guard let reason = reason else { return "None" }
        switch reason {
        case .doneProcessing: return "Done"
        case .captureError(let msg): return "CaptureError: \(msg)"
        case .playbackError(let msg): return "PlaybackError: \(msg)"
        case .processingError(let msg): return "ProcessingError: \(msg)"
        case .captureFormatChanged: return "CaptureFormatChange"
        case .configChanged: return "ConfigChanged"
        case .userRequest: return "StoppedByUser"
        }
    }

    private func escapeJsonString(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - Mutable Config Helpers

    /// Serialize current config to a JSON dictionary
    private func jsonFromConfig(_ config: CamillaDSPConfig) throws -> [String: Any] {
        let data = try JSONEncoder().encode(config)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.validationError("Failed to serialize config to JSON")
        }
        return dict
    }

    /// Deep-merge patch into target (matching Rust's merge function for PatchConfig)
    private func mergeJSON(_ target: inout [String: Any], patch: [String: Any]) {
        for (key, value) in patch {
            if let patchDict = value as? [String: Any],
               var targetDict = target[key] as? [String: Any] {
                mergeJSON(&targetDict, patch: patchDict)
                target[key] = targetDict
            } else {
                target[key] = value
            }
        }
    }

    /// Set a value at a JSON pointer path (e.g. "/filters/eq1/parameters/gain")
    /// Returns true if the path was found and value set.
    private func setValueAtPointer(_ json: inout [String: Any], pointer: String, value: Any) -> Bool {
        let components = pointer.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard !components.isEmpty else { return false }

        if components.count == 1 {
            json[components[0]] = value
            return true
        }

        guard var nested = json[components[0]] as? [String: Any] else { return false }
        let subPointer = "/" + components.dropFirst().joined(separator: "/")
        if setValueAtPointer(&nested, pointer: subPointer, value: value) {
            json[components[0]] = nested
            return true
        }
        return false
    }
}
