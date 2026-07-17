// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import Foundation

/// Generator for the five wavetables and the decay envelope used by
/// ``SineWavesEngine``.
///
/// Port of the initialization loop in `sine_waves_init()` from
/// `main/dsp/SineWaves.cpp`. All tables are byte-valued (`UInt8`) except the
/// envelope table, which is `Float`. Constants match `main/dsp/SineWaves.h`.
///
/// Tables are `static let` — computed once at first access, then immutable.
/// Total footprint is about 40 KB of RAM and roughly 5 ms of one-time init
/// cost. Call ``warmup()`` from a non-audio thread before the first note to
/// avoid stalling the audio thread.
///
/// > Thread safety: read-only after first access. `static let` initializers
/// > are guaranteed to run at most once by the Swift runtime.
///
/// > Realtime: table lookups are safe; use ``warmup()`` off-thread to
/// > amortize the one-time initialization cost.
public enum Wavetables {

    // MARK: - Sizes

    /// Wavetable length. `WAVETABLE_SIZE` in the C source — deliberately a
    /// prime so the wavetable loop period doesn't align with any other DSP
    /// loop, avoiding audible buzzing at fixed intervals.
    public static let size: Int = 7_919

    /// Length of the envelope decay table. Longer = slower decay.
    public static let envelopeSize: Int = 500

    // MARK: - Amplitudes (from `SineWaves.h`)

    /// `SINE_AMP` — peak amplitude of the sine wavetable.
    public static let sineAmplitude: Int = 128

    /// `SINE_OFFSET` — DC offset of the sine wavetable (biased to
    /// `[0, 255]`).
    public static let sineOffset: Int = 128

    /// `SAW_AMP` — peak amplitude of the sawtooth wavetable.
    public static let sawAmplitude: Int = 128

    /// `SAW_DC` — DC offset of the sawtooth wavetable.
    public static let sawDCOffset: Int = 64

    /// `SQR_AMP` — peak amplitude of the square wavetable.
    public static let squareAmplitude: Int = 128

    /// `SQR_DC` — DC offset of the square wavetable.
    public static let squareDCOffset: Int = 64

    /// `ENVTABLE_AMP` — scale factor applied to each envelope entry.
    public static let envelopeAmplitude: Float = 2.0

    /// `ENVTABLE_OFFSET` — DC offset added to each envelope entry.
    public static let envelopeOffset: Float = 0.0

    /// `ENV_DECAY_FACTOR` — base of the exponential decay curve.
    public static let envelopeDecayFactor: Double = 0.5

    /// `ENV_DECAY_STEP_DIV` — divisor on the envelope index in the decay
    /// exponent (larger = slower decay).
    public static let envelopeDecayStepDiv: Double = 40.0

    // MARK: - Tables (lazily computed, then immutable)

    /// One period of `sin(2π·i/size)`, DC-biased into `[0, 255]`.
    public static let sine: [UInt8] = {
        (0..<size).map { i in
            let v = sin(2.0 * .pi * Double(i) / Double(size))
            return UInt8(clamping: Int(v * Double(sineAmplitude)) + sineOffset)
        }
    }()

    /// Rising sawtooth ramp, DC-biased.
    public static let saw: [UInt8] = {
        (0..<size).map { i in
            let v = Double(i) / Double(size)
            return UInt8(clamping: sawDCOffset + Int(Double(sawAmplitude) * v))
        }
    }()

    /// 50% duty-cycle square wave, DC-biased.
    public static let square: [UInt8] = {
        (0..<size).map { i in
            let value = squareDCOffset + (i < size / 2 ? 0 : squareAmplitude)
            return UInt8(clamping: value)
        }
    }()

    /// "Multi": cosine + four phase-shifted sawtooths, summed and truncated
    /// to `UInt8`. The intentional overflow in the C code (implicit narrow
    /// of a large `int` to `uint8_t`) is what gives this waveform its
    /// scratchy detuned-chord character.
    public static let multi: [UInt8] = {
        (0..<size).map { i in
            let v = cos(2.0 * .pi * Double(i) / Double(size))
            var total = Int(v * Double(sineAmplitude))
            let sa = Double(sawAmplitude)
            let sz = Double(size)
            total &+= Int(sa * Double(i) / sz)
            total &+= Int(sa * Double(i + size / 13) / sz)
            total &+= Int(sa * Double(i + size / 3) / sz)
            total &+= Int(sa * Double(i + size / 7) / sz)
            return UInt8(truncatingIfNeeded: total)
        }
    }()

    /// Noise-plus-tone: cosine baseline with a random byte overwriting every
    /// 4th sample. The C code uses the ESP32 hardware RNG; we use Swift's
    /// `SystemRandomNumberGenerator` here — determinism doesn't matter for
    /// this waveform because it is meant to sound noisy.
    public static let noise: [UInt8] = {
        var out = [UInt8](repeating: 0, count: size)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<size {
            let v = cos(2.0 * .pi * Double(i) / Double(size))
            let base = Int(v * Double(sineAmplitude))
            if i % 4 == 0 {
                out[i] = UInt8.random(in: 0...255, using: &rng)
            } else {
                out[i] = UInt8(truncatingIfNeeded: base)
            }
        }
        return out
    }()

    /// Exponential-decay envelope. `envelope[0] ≈ 1.0`, monotonically
    /// decreasing.
    ///
    /// Formula: `pow(1 - decayFactor, 1 + i/decayStepDiv) * amp + offset`.
    public static let envelope: [Float] = {
        let base = 1.0 - envelopeDecayFactor
        return (0..<envelopeSize).map { i in
            let exponent = 1.0 + Double(i) / envelopeDecayStepDiv
            return Float(pow(base, exponent) * Double(envelopeAmplitude)) + envelopeOffset
        }
    }()

    // MARK: - Accessors

    /// Return the wavetable for a given waveform. `.rng` has no backing
    /// table (the render path generates samples on the fly) — this returns
    /// ``sine`` as a harmless fallback.
    ///
    /// - Parameter waveform: The waveform to look up.
    /// - Returns: The corresponding wavetable.
    public static func table(for waveform: MiniPiano.Waveform) -> [UInt8] {
        switch waveform {
        case .sine:   return sine
        case .saw:    return saw
        case .square: return square
        case .multi:  return multi
        case .noise:  return noise
        case .rng:    return sine
        }
    }

    /// Force initialization of all tables.
    ///
    /// Call this from a background or main queue at app launch, before the
    /// audio thread starts touching ``SineWavesEngine``, so the ~5 ms
    /// generation cost is paid up-front rather than stalling the first
    /// note. Safe to call multiple times.
    public static func warmup() {
        _ = sine.count
        _ = saw.count
        _ = square.count
        _ = multi.count
        _ = noise.count
        _ = envelope.count
    }
}
