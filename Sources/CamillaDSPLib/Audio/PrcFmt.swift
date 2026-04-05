// CamillaDSP-Swift: Internal processing precision type
// Default is Double (f64). Change to Float for 32-bit processing.

import Accelerate

/// Internal processing precision type. All audio math uses this type.
public typealias PrcFmt = Double

/// vDSP length type matching PrcFmt
public typealias PrcFmtLength = vDSP_Length

extension PrcFmt {
    /// Convert dB to linear gain
    @inlinable
    public static func fromDB(_ db: PrcFmt) -> PrcFmt {
        pow(10.0, db / 20.0)
    }

    /// Convert linear gain to dB. Returns -1000.0 for zero/negative input (matches Rust sentinel).
    @inlinable
    public static func toDB(_ linear: PrcFmt) -> PrcFmt {
        if linear <= 0 { return -1000.0 }
        return 20.0 * log10(linear)
    }
}

/// Vectorized DSP operations using Accelerate framework
public enum DSPOps {
    /// Multiply vector by scalar in-place
    @inlinable
    public static func scalarMultiply(_ buffer: inout [PrcFmt], by scalar: PrcFmt) {
        var s = scalar
        vDSP_vsmulD(buffer, 1, &s, &buffer, 1, vDSP_Length(buffer.count))
    }

    /// Add two vectors: result = a + b
    @inlinable
    public static func add(_ a: [PrcFmt], _ b: inout [PrcFmt], count: Int) {
        vDSP_vaddD(a, 1, b, 1, &b, 1, vDSP_Length(count))
    }

    /// Multiply two vectors element-wise: result[i] = a[i] * b[i]
    @inlinable
    public static func multiply(_ a: [PrcFmt], _ b: [PrcFmt], result: inout [PrcFmt], count: Int) {
        vDSP_vmulD(a, 1, b, 1, &result, 1, vDSP_Length(count))
    }

    /// Multiply-accumulate: result += a * b
    @inlinable
    public static func multiplyAdd(_ a: [PrcFmt], _ b: PrcFmt, accumulator: inout [PrcFmt], count: Int) {
        var s = b
        vDSP_vsmaD(a, 1, &s, accumulator, 1, &accumulator, 1, vDSP_Length(count))
    }

    /// Find peak absolute value
    @inlinable
    public static func peakAbsolute(_ buffer: [PrcFmt]) -> PrcFmt {
        var result: PrcFmt = 0
        vDSP_maxmgvD(buffer, 1, &result, vDSP_Length(buffer.count))
        return result
    }

    /// Compute RMS
    @inlinable
    public static func rms(_ buffer: [PrcFmt]) -> PrcFmt {
        var result: PrcFmt = 0
        vDSP_rmsqvD(buffer, 1, &result, vDSP_Length(buffer.count))
        return result
    }
}
