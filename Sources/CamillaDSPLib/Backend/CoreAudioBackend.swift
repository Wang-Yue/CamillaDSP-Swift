// CamillaDSP-Swift: CoreAudio capture and playback backends for macOS

import Foundation
import AudioToolbox
import CoreAudio
import Logging

// MARK: - CoreAudio Capture

public final class CoreAudioCapture: CaptureBackend {
    private let logger = Logger(label: "camilladsp.coreaudio.capture")
    private let deviceName: String?
    let channels: Int
    private let sampleRate: Double
    private let chunkSize: Int

    var audioUnit: AudioUnit?
    private var buffer: [[PrcFmt]] = []
    let bufferLock = NSLock()
    private var bufferReadIndex = 0
    var bufferWriteIndex = 0
    var ringBuffer: [[PrcFmt]] = []
    let ringBufferSize: Int
    var callbackErrorCount = 0
    var isInterleaved = false
    private var retainedSelf: Unmanaged<CoreAudioCapture>?

    public var actualSampleRate: Double { sampleRate }

    public init(config: CaptureDeviceConfig, sampleRate: Int, chunkSize: Int) {
        self.deviceName = config.device
        self.channels = config.channels
        self.sampleRate = Double(sampleRate)
        self.chunkSize = chunkSize
        self.ringBufferSize = chunkSize * 4 // 4 chunks of ring buffer
        self.ringBuffer = Array(repeating: Array(repeating: 0.0, count: ringBufferSize), count: channels)
    }

    public func open() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioBackendError.deviceNotFound("No HAL output component found")
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            throw AudioBackendError.initializationFailed("Failed to create AudioUnit: \(status)")
        }
        self.audioUnit = audioUnit

        // Enable input (capture)
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1, // input bus
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioBackendError.initializationFailed("Failed to enable input: \(status)")
        }

        // Disable output
        var disableOutput: UInt32 = 0
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0, // output bus
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )

        // Set the specific device if named
        if let deviceName = deviceName {
            if let deviceID = try findDeviceID(name: deviceName, isInput: true) {
                var id = deviceID
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            }
        }

        // Query the device's native stream format on the input bus
        var deviceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1, // input bus
            &deviceFormat,
            &formatSize
        )
        logger.info("Device native format: \(deviceFormat.mSampleRate)Hz, \(deviceFormat.mChannelsPerFrame)ch, \(deviceFormat.mBitsPerChannel)bit, flags=\(deviceFormat.mFormatFlags)")

        // Set our desired output format on the input bus's output scope:
        // Non-interleaved Float32 so we can process channels independently
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,  // Match device rate
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1, // input bus output scope
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        if status != noErr {
            logger.warning("Failed to set non-interleaved format (\(status)), trying interleaved")
            // Fallback: interleaved float
            streamFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            streamFormat.mBytesPerPacket = UInt32(4 * channels)
            streamFormat.mBytesPerFrame = UInt32(4 * channels)
            status = AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &streamFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
            guard status == noErr else {
                throw AudioBackendError.initializationFailed("Failed to set capture format: \(status)")
            }
        }

        // Store whether we're using interleaved format for the callback
        isInterleaved = (streamFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        // Set input callback
        var callbackStruct = AURenderCallbackStruct(
            inputProc: captureCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw AudioBackendError.initializationFailed("Failed to set input callback: \(status)")
        }

        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            throw AudioBackendError.initializationFailed("Failed to initialize AudioUnit: \(status)")
        }

        status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            throw AudioBackendError.initializationFailed("Failed to start AudioUnit: \(status)")
        }

        logger.info("CoreAudio capture opened: \(channels)ch @ \(sampleRate)Hz")
    }

    public func read(frames: Int) throws -> AudioChunk? {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        let available = (bufferWriteIndex - bufferReadIndex + ringBufferSize) % ringBufferSize
        guard available >= frames else {
            // Wait for more data
            return nil
        }

        var waveforms = [[PrcFmt]](repeating: [PrcFmt](repeating: 0, count: frames), count: channels)
        for ch in 0..<channels {
            for i in 0..<frames {
                let idx = (bufferReadIndex + i) % ringBufferSize
                waveforms[ch][i] = ringBuffer[ch][idx]
            }
        }
        bufferReadIndex = (bufferReadIndex + frames) % ringBufferSize

        return AudioChunk(waveforms: waveforms)
    }

    public func close() {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
        logger.info("CoreAudio capture closed")
    }

    // MARK: - Device Enumeration

    private func findDeviceID(name: String, isInput: Bool) throws -> AudioDeviceID? {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize)

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize, &deviceIDs)

        for deviceID in deviceIDs {
            var nameSize: UInt32 = 0
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyDataSize(deviceID, &nameAddress, 0, nil, &nameSize)

            var cfNameRef: Unmanaged<CFString>?
            nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &cfNameRef)
            let deviceName = cfNameRef?.takeRetainedValue() as String? ?? ""

            if deviceName == name {
                return deviceID
            }
        }
        return nil
    }

    /// Query the nominal sample rate of a named capture device (or default input if nil)
    public static func deviceSampleRate(name: String?) -> Double? {
        let devices = listDevices()
        let targetID: AudioDeviceID
        if let name = name, let dev = devices.first(where: { $0.name == name }) {
            targetID = dev.id
        } else {
            // Default input device
            var defaultID: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultID)
            guard status == noErr else { return nil }
            targetID = defaultID
        }
        var rate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(targetID, &rateAddr, 0, nil, &rateSize, &rate)
        return status == noErr ? rate : nil
    }

    /// Query the available sample rates for a named capture device (or default input if nil)
    public static func deviceAvailableSampleRates(name: String?) -> [Int] {
        let devices = listDevices()
        let targetID: AudioDeviceID
        if let name = name, let dev = devices.first(where: { $0.name == name }) {
            targetID = dev.id
        } else {
            var defaultID: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultID) == noErr else {
                return []
            }
            targetID = defaultID
        }

        var rangeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(targetID, &rangeAddr, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(targetID, &rangeAddr, 0, nil, &dataSize, &ranges) == noErr else {
            return []
        }

        // Common rates to check against device ranges
        let commonRates: [Int] = [8000, 11025, 16000, 22050, 32000, 44100, 48000,
                                   88200, 96000, 176400, 192000, 352800, 384000]
        var supported: [Int] = []
        for rate in commonRates {
            let r = Float64(rate)
            for range in ranges {
                if r >= range.mMinimum && r <= range.mMaximum {
                    supported.append(rate)
                    break
                }
            }
        }
        return supported
    }

    /// List available capture devices
    public static func listDevices() -> [(id: AudioDeviceID, name: String)] {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize)

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize, &ids)

        var results: [(id: AudioDeviceID, name: String)] = []
        for id in ids {
            // Check if it has input channels
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize)

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            AudioObjectGetPropertyData(id, &streamAddress, 0, nil, &streamSize, bufferListPtr)

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            var inputChannels = 0
            for buf in bufferList {
                inputChannels += Int(buf.mNumberChannels)
            }

            if inputChannels > 0 {
                var nameAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioObjectPropertyName,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var cfNameRef: Unmanaged<CFString>?
                var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &cfNameRef)
                results.append((id: id, name: (cfNameRef?.takeRetainedValue() as String?) ?? ""))
            }
        }
        return results
    }
}

/// CoreAudio render callback for capture
private func captureCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<CoreAudioCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    let channels = capture.channels
    let frameCount = Int(inNumberFrames)
    let interleaved = capture.isInterleaved

    // Allocate AudioBufferList:
    // Non-interleaved: N buffers, 1 channel each
    // Interleaved: 1 buffer, N channels
    let numBuffers = interleaved ? 1 : channels
    let bufferListSize = AudioBufferList.sizeInBytes(maximumBuffers: numBuffers)
    let bufferListRaw = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferListSize)
    defer { bufferListRaw.deallocate() }
    let bufferListPtr = UnsafeMutableRawPointer(bufferListRaw).bindMemory(to: AudioBufferList.self, capacity: 1)

    // Allocate data buffers
    let bytesPerBuffer: Int
    if interleaved {
        bytesPerBuffer = frameCount * channels * MemoryLayout<Float>.size
    } else {
        bytesPerBuffer = frameCount * MemoryLayout<Float>.size
    }

    var dataPointers: [UnsafeMutableRawPointer] = []
    for _ in 0..<numBuffers {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bytesPerBuffer, alignment: 16)
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: bytesPerBuffer)
        dataPointers.append(buf)
    }
    defer {
        for buf in dataPointers { buf.deallocate() }
    }

    let abl = UnsafeMutableAudioBufferListPointer(bufferListPtr)
    abl.count = numBuffers
    for i in 0..<numBuffers {
        abl[i] = AudioBuffer(
            mNumberChannels: interleaved ? UInt32(channels) : 1,
            mDataByteSize: UInt32(bytesPerBuffer),
            mData: dataPointers[i]
        )
    }

    guard let audioUnit = capture.audioUnit else { return noErr }

    // Render from input bus (bus 1)
    let status = AudioUnitRender(audioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, bufferListPtr)

    if status == noErr {
        capture.bufferLock.lock()
        if interleaved {
            // Deinterleave: buffer contains [L0,R0,L1,R1,...] floats
            let floatPtr = dataPointers[0].assumingMemoryBound(to: Float.self)
            for i in 0..<frameCount {
                for ch in 0..<channels {
                    let idx = (capture.bufferWriteIndex + i) % capture.ringBufferSize
                    capture.ringBuffer[ch][idx] = PrcFmt(floatPtr[i * channels + ch])
                }
            }
        } else {
            // Non-interleaved: each buffer is one channel
            for ch in 0..<channels {
                let floatPtr = dataPointers[ch].assumingMemoryBound(to: Float.self)
                for i in 0..<frameCount {
                    let idx = (capture.bufferWriteIndex + i) % capture.ringBufferSize
                    capture.ringBuffer[ch][idx] = PrcFmt(floatPtr[i])
                }
            }
        }
        capture.bufferWriteIndex = (capture.bufferWriteIndex + frameCount) % capture.ringBufferSize
        capture.bufferLock.unlock()
    } else {
        if capture.callbackErrorCount < 3 {
            print("[CamillaDSP] AudioUnitRender error: \(status)")
            capture.callbackErrorCount += 1
        }
    }

    return noErr
}

// MARK: - CoreAudio Playback

public final class CoreAudioPlayback: PlaybackBackend {
    private let logger = Logger(label: "camilladsp.coreaudio.playback")
    private let deviceName: String?
    let channels: Int
    private let sampleRate: Double
    private let chunkSize: Int
    private let exclusive: Bool

    private var audioUnit: AudioUnit?
    var ringBuffer: [[PrcFmt]] = []
    let ringBufferSize: Int
    var readIndex = 0
    var writeIndex = 0
    let bufferLock = NSLock()

    public var bufferLevel: Int {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return (writeIndex - readIndex + ringBufferSize) % ringBufferSize
    }

    public init(config: PlaybackDeviceConfig, sampleRate: Int, chunkSize: Int) {
        self.deviceName = config.device
        self.channels = config.channels
        self.sampleRate = Double(sampleRate)
        self.chunkSize = chunkSize
        self.exclusive = config.exclusive ?? false
        self.ringBufferSize = chunkSize * 8
        self.ringBuffer = Array(repeating: Array(repeating: 0.0, count: ringBufferSize), count: channels)
    }

    public func open() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioBackendError.deviceNotFound("No default output component found")
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            throw AudioBackendError.initializationFailed("Failed to create output AudioUnit: \(status)")
        }
        self.audioUnit = audioUnit

        // Set specific device if named
        if let deviceName = deviceName {
            if let deviceID = try findPlaybackDeviceID(name: deviceName) {
                var id = deviceID
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )

                // Enable hog mode (exclusive) if requested
                if exclusive {
                    var hogPID = ProcessInfo.processInfo.processIdentifier
                    var hogAddress = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyHogMode,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    AudioObjectSetPropertyData(
                        id, &hogAddress, 0, nil,
                        UInt32(MemoryLayout<pid_t>.size), &hogPID
                    )
                }
            }
        }

        // Set stream format: non-interleaved Float32
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )

        // Set render callback
        var callbackStruct = AURenderCallbackStruct(
            inputProc: playbackCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            throw AudioBackendError.initializationFailed("Failed to initialize output: \(status)")
        }

        status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            throw AudioBackendError.initializationFailed("Failed to start output: \(status)")
        }

        logger.info("CoreAudio playback opened: \(channels)ch @ \(sampleRate)Hz")
    }

    public func write(chunk: AudioChunk) throws {
        bufferLock.lock()
        for ch in 0..<min(channels, chunk.channels) {
            for i in 0..<chunk.validFrames {
                let idx = (writeIndex + i) % ringBufferSize
                ringBuffer[ch][idx] = chunk.waveforms[ch][i]
            }
        }
        writeIndex = (writeIndex + chunk.validFrames) % ringBufferSize
        bufferLock.unlock()
    }

    public func close() {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
        logger.info("CoreAudio playback closed")
    }

    private func findPlaybackDeviceID(name: String) throws -> AudioDeviceID? {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize)

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize, &ids)

        for id in ids {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfNameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &cfNameRef)
            let deviceName = cfNameRef?.takeRetainedValue() as String? ?? ""

            if deviceName == name {
                return id
            }
        }
        return nil
    }

    /// Query the nominal sample rate of a named playback device (or default output if nil)
    public static func deviceSampleRate(name: String?) -> Double? {
        let devices = listDevices()
        let targetID: AudioDeviceID
        if let name = name, let dev = devices.first(where: { $0.name == name }) {
            targetID = dev.id
        } else {
            var defaultID: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultID) == noErr else { return nil }
            targetID = defaultID
        }
        var rate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(targetID, &rateAddr, 0, nil, &rateSize, &rate) == noErr ? rate : nil
    }

    /// Query the available sample rates for a named playback device (or default output if nil)
    public static func deviceAvailableSampleRates(name: String?) -> [Int] {
        let devices = listDevices()
        let targetID: AudioDeviceID
        if let name = name, let dev = devices.first(where: { $0.name == name }) {
            targetID = dev.id
        } else {
            var defaultID: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultID) == noErr else { return [] }
            targetID = defaultID
        }
        var rangeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(targetID, &rangeAddr, 0, nil, &dataSize) == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(targetID, &rangeAddr, 0, nil, &dataSize, &ranges) == noErr else { return [] }
        let commonRates: [Int] = [8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]
        var supported: [Int] = []
        for rate in commonRates {
            let r = Float64(rate)
            for range in ranges {
                if r >= range.mMinimum && r <= range.mMaximum { supported.append(rate); break }
            }
        }
        return supported
    }

    /// List available playback devices
    public static func listDevices() -> [(id: AudioDeviceID, name: String)] {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize)

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize, &ids)

        var results: [(id: AudioDeviceID, name: String)] = []
        for id in ids {
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize)

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            AudioObjectGetPropertyData(id, &streamAddress, 0, nil, &streamSize, bufferListPtr)

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            var outputChannels = 0
            for buf in bufferList {
                outputChannels += Int(buf.mNumberChannels)
            }

            if outputChannels > 0 {
                var nameAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioObjectPropertyName,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var cfNameRef: Unmanaged<CFString>?
                var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &cfNameRef)
                results.append((id: id, name: (cfNameRef?.takeRetainedValue() as String?) ?? ""))
            }
        }
        return results
    }

    // Internal access for the C callback
    fileprivate var _audioUnit: AudioUnit? { audioUnit }
}

/// CoreAudio render callback for playback
private func playbackCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let playback = Unmanaged<CoreAudioPlayback>.fromOpaque(inRefCon).takeUnretainedValue()

    guard let bufferList = ioData else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)

    playback.bufferLock.lock()
    let available = (playback.writeIndex - playback.readIndex + playback.ringBufferSize) % playback.ringBufferSize

    for (ch, buffer) in buffers.enumerated() {
        guard let data = buffer.mData else { continue }
        let floatPtr = data.assumingMemoryBound(to: Float.self)

        if ch < playback.channels && available >= Int(inNumberFrames) {
            for i in 0..<Int(inNumberFrames) {
                let idx = (playback.readIndex + i) % playback.ringBufferSize
                floatPtr[i] = Float(playback.ringBuffer[ch][idx])
            }
        } else {
            // Underrun: output silence
            for i in 0..<Int(inNumberFrames) {
                floatPtr[i] = 0
            }
        }
    }

    if available >= Int(inNumberFrames) {
        playback.readIndex = (playback.readIndex + Int(inNumberFrames)) % playback.ringBufferSize
    }
    playback.bufferLock.unlock()

    return noErr
}

// MARK: - Errors

public enum AudioBackendError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case initializationFailed(String)
    case readError(String)
    case writeError(String)

    public var description: String {
        switch self {
        case .deviceNotFound(let msg): return "Device not found: \(msg)"
        case .initializationFailed(let msg): return "Initialization failed: \(msg)"
        case .readError(let msg): return "Read error: \(msg)"
        case .writeError(let msg): return "Write error: \(msg)"
        }
    }
}

// Note: The C callbacks access CoreAudioCapture and CoreAudioPlayback properties
// directly since they are declared as internal/public.
