// CamillaDSP-Swift: State file persistence (mirrors Rust statefile.rs)

import Foundation
import Yams
import Logging

/// Persisted state: tracks config path, volumes, and mute states across restarts.
/// YAML format matches Rust CamillaDSP exactly:
/// ```yaml
/// config_path: /path/to/config.yml
/// mute:
/// - false
/// - false
/// - false
/// - false
/// - false
/// volume:
/// - 0.0
/// - 0.0
/// - 0.0
/// - 0.0
/// - 0.0
/// ```
public struct PersistentState: Codable, Equatable {
    public var configPath: String?
    public var mute: [Bool]
    public var volume: [PrcFmt]

    enum CodingKeys: String, CodingKey {
        case configPath = "config_path"
        case mute
        case volume
    }

    public init(configPath: String? = nil, mute: [Bool]? = nil, volume: [PrcFmt]? = nil) {
        self.configPath = configPath
        self.mute = mute ?? Array(repeating: false, count: ProcessingParameters.numFaders)
        self.volume = volume ?? Array(repeating: 0.0, count: ProcessingParameters.numFaders)
    }
}

private let stateLogger = Logger(label: "camilladsp.statefile")

/// Load persisted state from a YAML file. Returns nil on any error.
public func loadState(filename: String) -> PersistentState? {
    let contents: String
    do {
        contents = try String(contentsOfFile: filename, encoding: .utf8)
    } catch {
        stateLogger.warning("Could not read statefile '\(filename)'. Error: \(error)")
        return nil
    }

    let decoder = YAMLDecoder()
    do {
        let state = try decoder.decode(PersistentState.self, from: contents)
        return state
    } catch {
        stateLogger.warning("Invalid statefile, ignoring! Error: \(error)")
        return nil
    }
}

/// Save current state (config path, volumes, mutes) to a YAML file.
/// Sets `unsavedStateChanges` to false on success.
public func saveState(
    filename: String,
    configPath: String?,
    params: ProcessingParameters,
    unsavedStateChanges: UnsafeMutablePointer<Bool>? = nil
) {
    let state = PersistentState(
        configPath: configPath,
        mute: params.allMutes(),
        volume: params.allVolumes()
    )
    if saveStateToFile(filename: filename, state: state) {
        unsavedStateChanges?.pointee = false
    }
}

/// Write a State struct to a YAML file. Returns true on success.
@discardableResult
public func saveStateToFile(filename: String, state: PersistentState) -> Bool {
    stateLogger.debug("Saving state to \(filename)")
    let encoder = YAMLEncoder()
    do {
        let yamlString = try encoder.encode(state)
        try yamlString.write(toFile: filename, atomically: true, encoding: .utf8)
        return true
    } catch {
        stateLogger.error("Unable to write statefile '\(filename)', error: \(error)")
        return false
    }
}
