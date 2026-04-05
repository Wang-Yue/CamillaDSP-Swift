// CamillaDSP-Swift: Sample format definitions and conversions

import Foundation

/// Supported sample formats for I/O.
/// Accepts both Swift-style names (S16, FLOAT32) and Rust CamillaDSP names (S16_LE, F32_LE).
public enum SampleFormat: String, Sendable {
    case s16 = "S16"
    case s24_3 = "S24_3"       // 24-bit in 3 bytes (packed)
    case s24_4 = "S24_4"       // 24-bit in 4 bytes, right-justified (24 bits in lower 3 bytes, MSB zero/sign-extended)
    case s24_4_lj = "S24_4_LJ" // 24-bit in 4 bytes, left-justified (24 bits in upper 3 bytes, LSB zero)
    case s32 = "S32"
    case float32 = "FLOAT32"
    case float64 = "FLOAT64"

    /// Mapping from Rust CamillaDSP format names to Swift enum cases
    private static let aliases: [String: SampleFormat] = [
        // Rust binary format names (_LE suffix)
        "S16_LE": .s16,
        "S24_3_LE": .s24_3,
        "S24_4_RJ_LE": .s24_4,
        "S24_4_LJ_LE": .s24_4_lj,
        "S32_LE": .s32,
        "F32_LE": .float32,
        "F64_LE": .float64,
        // CoreAudio short names (used in Rust CoreAudio/Wasapi backends)
        "S16": .s16,
        "S24": .s24_4,
        "S32": .s32,
        "F32": .float32,
    ]

    /// Bytes per sample
    public var bytesPerSample: Int {
        switch self {
        case .s16: return 2
        case .s24_3: return 3
        case .s24_4, .s24_4_lj, .s32, .float32: return 4
        case .float64: return 8
        }
    }

    /// Maximum integer value for this format (for normalization)
    public var maxValue: PrcFmt {
        switch self {
        case .s16: return PrcFmt(Int16.max)
        case .s24_3, .s24_4, .s24_4_lj: return PrcFmt((1 << 23) - 1)
        case .s32: return PrcFmt(Int32.max)
        case .float32, .float64: return 1.0
        }
    }
}

extension SampleFormat: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawString = try container.decode(String.self)
        // Try the canonical rawValue first, then check aliases
        if let value = SampleFormat(rawValue: rawString) {
            self = value
        } else if let value = SampleFormat.aliases[rawString] {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown sample format '\(rawString)'. Expected one of: \(SampleFormat.allCases.map(\.rawValue).joined(separator: ", ")) or Rust equivalents (S16_LE, F32_LE, etc.)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension SampleFormat: CaseIterable {
    public static var allCases: [SampleFormat] {
        [.s16, .s24_3, .s24_4, .s24_4_lj, .s32, .float32, .float64]
    }
}

/// Convert interleaved bytes to non-interleaved PrcFmt waveforms
public func bytesToWaveforms(
    _ data: UnsafeRawBufferPointer,
    format: SampleFormat,
    channels: Int,
    frames: Int
) -> [[PrcFmt]] {
    var waveforms = Array(repeating: [PrcFmt](repeating: 0, count: frames), count: channels)
    let scale = 1.0 / format.maxValue

    for frame in 0..<frames {
        for ch in 0..<channels {
            let sampleIndex = frame * channels + ch
            let byteOffset = sampleIndex * format.bytesPerSample
            let value: PrcFmt

            switch format {
            case .s16:
                let raw = data.load(fromByteOffset: byteOffset, as: Int16.self)
                value = PrcFmt(raw) * scale
            case .s24_3:
                let b0 = Int32(data[byteOffset])
                let b1 = Int32(data[byteOffset + 1])
                let b2 = Int32(data[byteOffset + 2])
                var raw = b0 | (b1 << 8) | (b2 << 16)
                if raw & 0x800000 != 0 { raw |= -0x800000 } // sign extend
                value = PrcFmt(raw) * scale
            case .s24_4:
                // Right-justified: 24-bit value sits in the lower 3 bytes of the 32-bit word.
                // The MSB (byte 3) is 0x00 for positive and 0xFF for negative values.
                // Sign-extend from bit 23 to produce a proper Int32.
                let raw = data.load(fromByteOffset: byteOffset, as: Int32.self)
                let signExtended = (raw << 8) >> 8 // shift left then arithmetic right to sign-extend from bit 23
                value = PrcFmt(signExtended) * scale
            case .s24_4_lj:
                // Left-justified: 24-bit value sits in the upper 3 bytes (bits 31-8), LSB is zero.
                let raw = data.load(fromByteOffset: byteOffset, as: Int32.self)
                let shifted = raw >> 8 // arithmetic right shift exposes the 24-bit value with correct sign
                value = PrcFmt(shifted) * scale
            case .s32:
                let raw = data.load(fromByteOffset: byteOffset, as: Int32.self)
                value = PrcFmt(raw) * scale
            case .float32:
                value = PrcFmt(data.load(fromByteOffset: byteOffset, as: Float.self))
            case .float64:
                value = PrcFmt(data.load(fromByteOffset: byteOffset, as: Double.self))
            }

            waveforms[ch][frame] = value
        }
    }
    return waveforms
}

/// Convert non-interleaved PrcFmt waveforms to interleaved bytes
public func waveformsToBytes(
    _ waveforms: [[PrcFmt]],
    format: SampleFormat,
    frames: Int
) -> Data {
    let channels = waveforms.count
    let totalBytes = frames * channels * format.bytesPerSample
    var data = Data(count: totalBytes)

    data.withUnsafeMutableBytes { buffer in
        for frame in 0..<frames {
            for ch in 0..<channels {
                let sampleIndex = frame * channels + ch
                let byteOffset = sampleIndex * format.bytesPerSample
                let sample = waveforms[ch][frame]

                switch format {
                case .s16:
                    let clamped = max(-1.0, min(1.0, sample))
                    var raw = Int16(clamped * PrcFmt(Int16.max))
                    withUnsafeBytes(of: &raw) { src in
                        buffer.baseAddress!.advanced(by: byteOffset)
                            .copyMemory(from: src.baseAddress!, byteCount: 2)
                    }
                case .s24_3:
                    let clamped = max(-1.0, min(1.0, sample))
                    let raw = Int32(clamped * PrcFmt((1 << 23) - 1))
                    buffer[byteOffset] = UInt8(truncatingIfNeeded: raw)
                    buffer[byteOffset + 1] = UInt8(truncatingIfNeeded: raw >> 8)
                    buffer[byteOffset + 2] = UInt8(truncatingIfNeeded: raw >> 16)
                case .s24_4:
                    // Right-justified: store the 24-bit value in the lower 3 bytes with no shift.
                    // The upper byte will be 0x00 (positive) or 0xFF (negative) from sign extension.
                    let clamped = max(-1.0, min(1.0, sample))
                    var raw = Int32(clamped * PrcFmt((1 << 23) - 1))
                    withUnsafeBytes(of: &raw) { src in
                        buffer.baseAddress!.advanced(by: byteOffset)
                            .copyMemory(from: src.baseAddress!, byteCount: 4)
                    }
                case .s24_4_lj:
                    // Left-justified: shift the 24-bit value into the upper 3 bytes (bits 31-8).
                    let clamped = max(-1.0, min(1.0, sample))
                    var raw = Int32(clamped * PrcFmt((1 << 23) - 1)) << 8
                    withUnsafeBytes(of: &raw) { src in
                        buffer.baseAddress!.advanced(by: byteOffset)
                            .copyMemory(from: src.baseAddress!, byteCount: 4)
                    }
                case .s32:
                    let clamped = max(-1.0, min(1.0, sample))
                    var raw = Int32(clamped * PrcFmt(Int32.max))
                    withUnsafeBytes(of: &raw) { src in
                        buffer.baseAddress!.advanced(by: byteOffset)
                            .copyMemory(from: src.baseAddress!, byteCount: 4)
                    }
                case .float32:
                    var raw = Float(sample)
                    withUnsafeBytes(of: &raw) { src in
                        buffer.baseAddress!.advanced(by: byteOffset)
                            .copyMemory(from: src.baseAddress!, byteCount: 4)
                    }
                case .float64:
                    var raw = Double(sample)
                    withUnsafeBytes(of: &raw) { src in
                        buffer.baseAddress!.advanced(by: byteOffset)
                            .copyMemory(from: src.baseAddress!, byteCount: 8)
                    }
                }
            }
        }
    }
    return data
}
