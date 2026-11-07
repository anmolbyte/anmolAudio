import Foundation
import Accelerate

/// One channel's worth of an N-section biquad cascade, driven by `vDSP_biquad`.
///
/// `vDSP_biquad` expects coefficients in groups of 5 per section: (b0, b1, b2, a1, a2)
/// with a0 implicitly 1.0 (the caller normalizes). State (delay line) is 2 floats per
/// section plus 2 trailing slots used internally by vDSP. One instance per channel so
/// L/R have independent state.
final class BiquadCascade {
    let sectionCount: Int
    private var setup: vDSP_biquad_Setup
    private var delayLine: UnsafeMutablePointer<Float>
    private let delayLineCount: Int
    /// Active coefficient set, length `5 * sectionCount`. Updated atomically (memcpy)
    /// from the audio thread when a new set is published.
    private(set) var coefficients: [Double]

    init(sectionCount: Int, initialCoefficients: [Double]) {
        precondition(initialCoefficients.count == 5 * sectionCount,
                     "expected 5 coefficients per section")
        self.sectionCount = sectionCount
        self.coefficients = initialCoefficients
        // vDSP_biquad_CreateSetup copies the coefficients; we can rebuild later.
        guard let setup = vDSP_biquad_CreateSetup(initialCoefficients, vDSP_Length(sectionCount)) else {
            fatalError("vDSP_biquad_CreateSetup failed")
        }
        self.setup = setup
        self.delayLineCount = 2 * sectionCount + 2
        self.delayLine = .allocate(capacity: delayLineCount)
        self.delayLine.initialize(repeating: 0, count: delayLineCount)
    }

    deinit {
        vDSP_biquad_DestroySetup(setup)
        delayLine.deinitialize(count: delayLineCount)
        delayLine.deallocate()
    }

    /// Replace coefficients on the existing setup. `vDSP_biquad_SetCoefficientsDouble`
    /// is a plain memcpy on the setup's internal coefficient table — no allocation, so
    /// safe to call on the audio thread between `process` invocations. Delay line is
    /// preserved (no pop).
    func setCoefficients(_ newCoefficients: [Double]) {
        precondition(newCoefficients.count == 5 * sectionCount)
        coefficients = newCoefficients
        newCoefficients.withUnsafeBufferPointer { buf in
            vDSP_biquad_SetCoefficientsDouble(setup, buf.baseAddress!, 0, vDSP_Length(sectionCount))
        }
    }

    /// Process `frames` samples in place. Safe on the audio thread (zero allocation, direct SIMD pointer).
    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        vDSP_biquad(setup, delayLine, buffer, 1, buffer, 1, vDSP_Length(frames))
    }

    /// Zero the IIR delay-line state. No allocation, audio-thread safe; the
    /// Cascade uses this when transitioning to bypass so residual
    /// state can't bleed into the next activation.
    func reset() {
        memset(delayLine, 0, delayLineCount * MemoryLayout<Float>.stride)
    }
}

// MARK: - RBJ Audio EQ Cookbook coefficients

enum BiquadCoefficients {
    /// Returns `(b0, b1, b2, a1, a2)` (a0-normalized) for the requested filter at the given
    /// sample rate. Frequencies above Nyquist are clamped so we never produce NaN coefficients.
    static func make(
        type: EQBand.FilterType,
        frequency: Float,
        gainDB: Float,
        q: Float,
        sampleRate: Double
    ) -> (Double, Double, Double, Double, Double) {
        guard sampleRate > 20.0, frequency.isFinite, gainDB.isFinite, q.isFinite else { return identity }
        let nyquist = sampleRate * 0.5
        let f = min(max(Double(frequency), 10.0), max(10.0, nyquist - 1.0))
        let clampedGain = min(max(Double(gainDB), -120.0), 30.0)
        let A = pow(10.0, clampedGain / 40.0)
        let w0 = 2.0 * .pi * f / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let qClamped = min(max(Double(q), 0.0001), 100.0)

        switch type {
        case .peak:
            let alpha = sinW0 / (2.0 * qClamped)
            let b0 = 1.0 + alpha * A
            let b1 = -2.0 * cosW0
            let b2 = 1.0 - alpha * A
            let a0 = 1.0 + alpha / A
            let a1 = -2.0 * cosW0
            let a2 = 1.0 - alpha / A
            return normalize(b0, b1, b2, a0, a1, a2)

        case .lowShelf:
            // RBJ low shelf with peaking-Q alpha — matches AutoEq's PEQ convention
            // (autoeq/peq.py uses sin(w0)/(2*Q) for shelves) and the on-screen curve
            // in EQCurveGeometry. Using the cookbook's S-form here instead made the
            // audio shelves broader than the preset author optimized for.
            let alpha = sinW0 / (2.0 * qClamped)
            let twoSqrtAalpha = 2.0 * sqrt(A) * alpha
            let b0 = A * ((A + 1.0) - (A - 1.0) * cosW0 + twoSqrtAalpha)
            let b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW0)
            let b2 = A * ((A + 1.0) - (A - 1.0) * cosW0 - twoSqrtAalpha)
            let a0 = (A + 1.0) + (A - 1.0) * cosW0 + twoSqrtAalpha
            let a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosW0)
            let a2 = (A + 1.0) + (A - 1.0) * cosW0 - twoSqrtAalpha
            return normalize(b0, b1, b2, a0, a1, a2)

        case .highShelf:
            let alpha = sinW0 / (2.0 * qClamped)
            let twoSqrtAalpha = 2.0 * sqrt(A) * alpha
            let b0 = A * ((A + 1.0) + (A - 1.0) * cosW0 + twoSqrtAalpha)
            let b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW0)
            let b2 = A * ((A + 1.0) + (A - 1.0) * cosW0 - twoSqrtAalpha)
            let a0 = (A + 1.0) - (A - 1.0) * cosW0 + twoSqrtAalpha
            let a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW0)
            let a2 = (A + 1.0) - (A - 1.0) * cosW0 - twoSqrtAalpha
            return normalize(b0, b1, b2, a0, a1, a2)
        }
    }

    /// Identity biquad (passthrough), used to fill a section when no band exists.
    static let identity: (Double, Double, Double, Double, Double) = (1.0, 0.0, 0.0, 0.0, 0.0)

    private static func normalize(
        _ b0: Double, _ b1: Double, _ b2: Double,
        _ a0: Double, _ a1: Double, _ a2: Double
    ) -> (Double, Double, Double, Double, Double) {
        guard abs(a0) > 1e-12, a0.isFinite, b0.isFinite, b1.isFinite, b2.isFinite, a1.isFinite, a2.isFinite else {
            return identity
        }
        let inv = 1.0 / a0
        let norm = (b0 * inv, b1 * inv, b2 * inv, a1 * inv, a2 * inv)
        guard norm.0.isFinite, norm.1.isFinite, norm.2.isFinite, norm.3.isFinite, norm.4.isFinite else {
            return identity
        }
        return norm
    }
}
