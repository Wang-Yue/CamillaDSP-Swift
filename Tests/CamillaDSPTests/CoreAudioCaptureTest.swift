// Quick integration test for CoreAudio capture with real hardware
// Run with: swift test --filter testCaptureFromBlackHole

import XCTest
@testable import CamillaDSPLib

final class CoreAudioCaptureTest: XCTestCase {

    func testListCaptureDevices() {
        let devices = CoreAudioCapture.listDevices()
        print("=== Capture Devices ===")
        for d in devices {
            print("  [\(d.id)] \(d.name)")
        }
        XCTAssertFalse(devices.isEmpty, "Should find at least one capture device")
    }

    func testListPlaybackDevices() {
        let devices = CoreAudioPlayback.listDevices()
        print("=== Playback Devices ===")
        for d in devices {
            print("  [\(d.id)] \(d.name)")
        }
        XCTAssertFalse(devices.isEmpty, "Should find at least one playback device")
    }

    /// This test requires BlackHole 2ch to be installed and audio playing through it.
    /// Run manually: swift test --filter testCaptureFromBlackHole
    func testCaptureFromBlackHole() throws {
        let devices = CoreAudioCapture.listDevices()
        guard devices.contains(where: { $0.name == "BlackHole 2ch" }) else {
            print("BlackHole 2ch not found, skipping test")
            return
        }

        let config = CaptureDeviceConfig(type: .coreAudio, channels: 2, device: "BlackHole 2ch")
        let capture = CoreAudioCapture(config: config, sampleRate: 48000, chunkSize: 512)

        try capture.open()
        print("Capture opened, waiting for data...")

        // Wait for the ring buffer to fill
        Thread.sleep(forTimeInterval: 0.5)

        var gotData = false
        for attempt in 0..<20 {
            if let chunk = try capture.read(frames: 512) {
                let peaks = chunk.peakDB()
                print("Chunk \(attempt): frames=\(chunk.frames), ch=\(chunk.channels), peak=\(peaks)")
                gotData = true

                // If BlackHole has audio, peaks should be above silence (-100 dB)
                if peaks[0] > -80 || peaks[1] > -80 {
                    print("Audio detected! L=\(peaks[0]) dB, R=\(peaks[1]) dB")
                }
                break
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        capture.close()
        XCTAssertTrue(gotData, "Should have received at least one chunk of audio data")
    }
}
