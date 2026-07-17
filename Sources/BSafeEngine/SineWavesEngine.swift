// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import Foundation

/// Monophonic wavetable oscillator with a decay envelope.
///
/// Direct port of `sine_waves_next_sample()` in
/// `main/dsp/SineWaves.cpp`. One instance = one voice; retrigger via
/// ``trigger(note:octaveShift:)``. Emits a single mono `Float` sample per
/// ``renderNextSample()`` call. The caller duplicates it to L/R for stereo —
/// the firmware does the same.
///
/// The engine keeps a per-key waveform assignment. UI code updates it via
/// ``setKeyWaveform(_:forKey:)`` so hardware/UI can change key→waveform
/// bindings without touching this engine.
///
/// > Thread safety: audio-thread-only. Owned by ``SynthCore``. All mutating
/// > methods must be called from the audio thread; the UI mutates
/// > ``SynthParameters`` and the audio thread applies the resulting snapshot
/// > at the top of each render buffer.
///
/// > Realtime: safe on every waveform. The ``MiniPiano/Waveform/rng``
/// > waveform uses an on-thread xorshift32 PRNG (see ``nextNoiseByte(_:)``)
/// > so the render path never touches `SystemRandomNumberGenerator` or the
/// > allocator.
public final class SineWavesEngine: @unchecked Sendable {

    // MARK: - Constants

    /// Sample interval between envelope ticks.
    ///
    /// The firmware fires an envelope tick every ~2 ms
    /// (`TIMING_EVERY_2_MS == 13`). At 32,768 Hz that's `32768 / 500 ≈ 65`
    /// samples, giving roughly one second of decay before silence.
    private static let envelopeTickSamples: Int = 65

    // MARK: - State (mirrors `sine_waves.*` globals)

    private var wPtr: Double = 0
    private var wStep: Double = 0
    private var envelopeIndex: Int = -1   // -1 == silent
    private var envelopeAmp: Float = 0
    private var envelopeDivider: Int = 1  // e_div: for the RNG waveform
    private var wType: MiniPiano.Waveform = .sine
    private var cycleAlignment: Bool = false   // wt_ca — smooth wrap for tonal waves
    private var sampleCounterForEnvelope: Int = 0

    // RNG waveform's low-pass-filter state.
    private var rndLpfAlpha: Float = 0
    private var rndFiltered: Float = 0

    /// State register for the on-thread xorshift32 PRNG used by the RNG
    /// waveform. Any non-zero value seeds a valid sequence with a period of
    /// 2³² − 1; the constant here is arbitrary. The seed is perturbed on
    /// every ``trigger(note:octaveShift:)`` so different keys produce
    /// different noise textures.
    private var noiseState: UInt32 = 0xACE1_ACE1

    private var tuning: [UInt16] = MiniPiano.defaultTuning
    private var keyWaveforms: [MiniPiano.Waveform] = Array(
        repeating: .sine, count: MiniPiano.keyCount
    )

    // MARK: - Init

    public init() {}

    // MARK: - Configuration

    /// Set the preferred waveform for a mini-piano key.
    ///
    /// - Parameters:
    ///   - waveform: The waveform to associate with the key.
    ///   - key: Zero-based key index, clamped to `0 … MiniPiano.keyCount - 1`.
    public func setKeyWaveform(_ waveform: MiniPiano.Waveform, forKey key: Int) {
        let idx = max(0, min(MiniPiano.keyCount - 1, key))
        keyWaveforms[idx] = waveform
    }

    // MARK: - Note triggering

    /// Retrigger the voice with a note and octave offset.
    ///
    /// Resets the oscillator phase and envelope; the previous note (if any)
    /// is cut immediately.
    ///
    /// - Parameters:
    ///   - note: 1-based note index, `1 … MiniPiano.keyCount`. Matches the
    ///     C convention (`note_triggered - 1` throughout `SineWaves.cpp`).
    ///     Values outside the range are ignored.
    ///   - octaveShift: Octave offset. `0` = base pitch, positive =
    ///     multiply `w_step` by `(shift + 1)`, `-1` = divide by 2,
    ///     `≤ -2` = divide by 4. Mirrors `wt_octave_shift`.
    ///
    /// > Realtime: safe.
    public func trigger(note: Int, octaveShift: Int = 0) {
        guard (1...MiniPiano.keyCount).contains(note) else { return }

        // 1. Compute w_step from the tuning table + octave shift.
        var step = Double(tuning[note - 1]) / Double(MiniPiano.tuningBase)
        if octaveShift != 0 {
            let divider: Int
            if octaveShift >= 1     { divider = octaveShift + 1 }
            else if octaveShift == -1 { divider = -2 }
            else                    { divider = -4 }
            if divider > 0 { step *= Double(divider) }
            else           { step /= Double(-divider) }
        }
        self.wStep = step

        // 2. Adopt the key's chosen waveform. UI code stores an explicit
        //    ``MiniPiano/Waveform`` per key; there is no "unset" sentinel.
        let resolved = keyWaveforms[note - 1]
        self.wType = resolved

        // 3. Reset oscillator + envelope state.
        wPtr = 0
        envelopeIndex = 0
        envelopeAmp = 1.0
        sampleCounterForEnvelope = 0

        // 4. Cycle alignment: for tonal waveforms (sine/saw/square) wrap the
        //    phase pointer past the table end so the loop is seamless. For
        //    noise/RNG, snap back to zero (produces a subtle click that
        //    reads as texture, not error).
        cycleAlignment = [.sine, .saw, .square].contains(resolved)

        // 5. For RNG, set up the LP-filter alpha proportional to the tuning
        //    value. Direct port of the C formula.
        if resolved == .rng {
            let t = Int(tuning[note - 1])
            let minT = 5       // MINI_PIANO_TUNING_MIN
            let maxT = 65_000  // MINI_PIANO_TUNING_MAX
            rndLpfAlpha = Float((t - minT) >> 8) / Float(maxT >> 8)
            rndFiltered = 0

            // Perturb the PRNG seed with the tuning value so different
            // keys produce visibly different noise textures. The multiplier
            // is the golden-ratio constant used in Knuth's multiplicative
            // hash — spreads adjacent tuning values across the 32-bit
            // seed space. Non-zero state is a xorshift32 invariant.
            noiseState ^= UInt32(truncatingIfNeeded: t) &* 0x9E37_79B9
            if noiseState == 0 { noiseState = 0xACE1_ACE1 }
        }

        envelopeDivider = 1
    }

    /// Cut the current note immediately (envelope jumps to silence).
    public func stop() {
        envelopeIndex = -1
        envelopeAmp = 0
    }

    /// Reset all voice state.
    public func reset() {
        stop()
        wPtr = 0
        wStep = 0
        sampleCounterForEnvelope = 0
    }

    // MARK: - Render

    /// Generate one mono sample.
    ///
    /// - Returns: A `Float` in `[-1, 1]`, DC-centered.
    ///
    /// > Realtime: safe. Allocation-free, lock-free, syscall-free — including
    /// > the ``MiniPiano/Waveform/rng`` waveform, which uses an on-thread
    /// > xorshift32 PRNG.
    public func renderNextSample() -> Float {
        guard envelopeIndex >= 0 else { return 0 }

        // 1. Sample the wavetable. All paths produce `sample = value * env_amp`,
        //    with an average DC bias near `128 * env_amp` (uint8 wavetable
        //    values sit in [0, 255]).
        let idx = Int(wPtr.rounded()) % Wavetables.size
        let sample: Float
        switch wType {
        case .sine:           sample = Float(Wavetables.sine[idx])   * envelopeAmp
        case .saw:            sample = Float(Wavetables.saw[idx])    * envelopeAmp
        case .square:         sample = Float(Wavetables.square[idx]) * envelopeAmp
        case .multi:          sample = Float(Wavetables.multi[idx])  * envelopeAmp
        case .noise:          sample = Float(Wavetables.noise[idx])  * envelopeAmp
        case .rng:
            // Low-pass-filter a fresh random byte pre-scaled by env_amp — that
            // matches the C source and keeps `sample` on the same scale as
            // the other waveforms (mean ~= 128 * env_amp), so a single
            // normalization step at the end works for every path.
            let scaledNoise = Float(Self.nextNoiseByte(&noiseState)) * envelopeAmp
            rndFiltered += rndLpfAlpha * (scaledNoise - rndFiltered)
            sample = rndFiltered
        }

        // 2. Advance the wavetable pointer.
        wPtr += wStep
        if wPtr > Double(Wavetables.size) {
            wPtr = cycleAlignment
                ? wPtr - Double(Wavetables.size)   // seamless wrap
                : 0                                 // hard reset
        }

        // 3. Advance the envelope (every envelopeTickSamples samples).
        sampleCounterForEnvelope += 1
        if sampleCounterForEnvelope >= Self.envelopeTickSamples {
            sampleCounterForEnvelope = 0
            envelopeIndex += (wType == .rng ? envelopeDivider : 1)
            if envelopeIndex >= Wavetables.envelopeSize - 1 {
                envelopeIndex = -1
                envelopeAmp = Wavetables.envelopeOffset
            } else {
                envelopeAmp = Wavetables.envelope[envelopeIndex]
            }
        }

        // 4. Normalize to [-1, 1]. Raw wavetable values sit in [0, 255] with
        //    DC bias around 128. Remove the bias and divide by 128 so
        //    consumers get a zero-centered signal.
        return (sample - 128.0 * envelopeAmp) / 128.0
    }

    // MARK: - PRNG

    /// Advance a xorshift32 register in-place and return its low byte.
    ///
    /// Marsaglia's xorshift with the `(13, 17, 5)` triple; period 2³² − 1,
    /// invalid on zero. Roughly the cheapest non-trivial PRNG that still
    /// passes basic randomness sanity checks — three XORs and three shifts
    /// per byte, no division, no multiplication, no allocation.
    @inline(__always)
    private static func nextNoiseByte(_ state: inout UInt32) -> UInt8 {
        var s = state
        s ^= s &<< 13
        s ^= s &>> 17
        s ^= s &<< 5
        state = s
        return UInt8(truncatingIfNeeded: s)
    }
}
