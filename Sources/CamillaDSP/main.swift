// CamillaDSP-Swift: Command-line entry point

import Foundation
import CamillaDSPLib
import ArgumentParser
import Logging

struct CamillaDSPApp: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "camilladsp",
        abstract: "CamillaDSP-Swift: A cross-platform audio DSP engine",
        version: "1.0.0"
    )

    @Argument(help: "Path to the YAML configuration file")
    var configFile: String?

    @Option(name: .shortAndLong, help: "WebSocket server port (enables control API)")
    var port: UInt16?

    @Option(name: .shortAndLong, help: "WebSocket server address")
    var address: String = "127.0.0.1"

    @Flag(name: .shortAndLong, help: "Check configuration and exit")
    var check: Bool = false

    @Flag(name: .shortAndLong, help: "Verbose logging")
    var verbose: Bool = false

    @Flag(name: .long, help: "List available audio devices and exit")
    var listDevices: Bool = false

    mutating func run() throws {
        // Configure logging
        let logLevel: Logger.Level = verbose ? .debug : .info
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = logLevel
            return handler
        }
        let logger = Logger(label: "camilladsp")

        // List devices mode
        if listDevices {
            print("=== Capture Devices ===")
            for device in CoreAudioCapture.listDevices() {
                print("  [\(device.id)] \(device.name)")
            }
            print("\n=== Playback Devices ===")
            for device in CoreAudioPlayback.listDevices() {
                print("  [\(device.id)] \(device.name)")
            }
            return
        }

        // Load configuration
        guard let configFile = configFile else {
            throw ValidationError("Missing config file. Usage: camilladsp <config-file>")
        }
        logger.info("Loading configuration: \(configFile)")
        let config = try ConfigLoader.load(from: configFile)

        // Check mode: validate and exit
        if check {
            logger.info("Configuration is valid")
            print("Configuration OK")
            return
        }

        let infoMsg = "Config: \(config.devices.samplerate)Hz, chunk=\(config.devices.chunksize), capture=\(config.devices.capture.channels)ch, playback=\(config.devices.playback.channels)ch"
        logger.info("\(infoMsg)")

        // Create engine
        let engine = DSPEngine(config: config)

        // Start WebSocket server if port specified
        var wsServer: WebSocketServer?
        if let port = port {
            wsServer = WebSocketServer(port: port, host: address,
                                       processingParams: engine.processingParams)
            wsServer?.setEngine(engine)
            try wsServer?.start()
            logger.info("WebSocket server started on \(address):\(port)")
        }

        // Handle signals for graceful shutdown
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler {
            logger.info("Received SIGINT, shutting down...")
            engine.stop()
            wsServer?.stop()
            Foundation.exit(0)
        }
        signalSource.resume()

        let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)
        sigTermSource.setEventHandler {
            logger.info("Received SIGTERM, shutting down...")
            engine.stop()
            wsServer?.stop()
            Foundation.exit(0)
        }
        sigTermSource.resume()

        // Start the engine
        try engine.start()

        // Run the main loop
        logger.info("CamillaDSP-Swift running. Press Ctrl+C to stop.")
        RunLoop.main.run()
    }
}

CamillaDSPApp.main()
