// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import Foundation

/// Constants and shared types for the 8-key mini-piano voice.
///
/// Matches the C globals `mini_piano_tuning[]` and `mini_piano_waves[]` from
/// `main/dsp/SineWaves.cpp` and the `MINI_PIANO_*` `#define`s from
/// `main/dsp/SineWaves.h`.
///
/// The BSAFE hardware has 8 capacitive keys. Each key holds a tuning value
/// (used as a divisor to compute the wavetable phase step) and a preferred
/// waveform. This enum is a namespace for those constants; the actual voice
/// state lives in ``SineWavesEngine``.
public enum MiniPiano {

    /// Number of keys. Matches `MINI_PIANO_KEYS` in the C source.
    public static let keyCount: Int = 8

    /// Base divisor for the `w_step` calculation. Matches
    /// `MINI_PIANO_TUNING_BASE = 20` in `SineWaves.h`.
    public static let tuningBase: UInt16 = 20

    /// Default tuning values, calibrated for the 32,768 Hz sample rate.
    ///
    /// From the C comment "corrected by ear". Keys are 1-indexed on the
    /// hardware; this array is 0-indexed.
    public static let defaultTuning: [UInt16] = [
        2159, 2424, 2593, 2882, 3249, 3465, 4110, 4297,
    ]

    /// Waveform selector for a single mini-piano key.
    ///
    /// Raw values line up with the `MINI_PIANO_WAVE_*` enums in
    /// `SineWaves.h` so numeric constants from firmware configs continue to
    /// map correctly. The firmware's `MINI_PIANO_WAVE_DEFAULT = 0` sentinel
    /// is intentionally omitted — this port uses ``sine`` explicitly instead
    /// of relying on a nullable default.
    public enum Waveform: Int, CaseIterable, Sendable {
        /// Pure sinusoid.
        case sine   = 1
        /// Rising sawtooth ramp.
        case saw    = 2
        /// 50% square wave.
        case square = 3
        /// Cosine plus four phase-shifted sawtooths, summed with intentional
        /// `UInt8` overflow (produces a scratchy detuned-chord tone).
        case multi  = 4
        /// Pre-baked "noise-plus-tone" table.
        case noise  = 5
        /// Per-sample random byte, low-pass filtered by tuning value. Not
        /// backed by a wavetable — see ``SineWavesEngine``.
        case rng    = 6
    }
}
