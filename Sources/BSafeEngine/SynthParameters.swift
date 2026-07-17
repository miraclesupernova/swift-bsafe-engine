// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import Foundation
import os.lock

/// User-facing parameter store for the BSAFE synth. SwiftUI observes it on
/// the main actor; the audio thread reads a lock-guarded value snapshot
/// through ``snapshot()`` once per render buffer.
///
/// The property names mirror the C firmware globals (`var_p[]`, `bit1`,
/// `bit2`, `bytebeat_song`) so the port stays greppable against
/// `main/dsp/Bytebeat.cpp`. UI-friendly aliases (``variableA``…``variableD``,
/// ``songIndex``) are provided so views don't leak hardware names.
///
/// ## Threading model
///
/// - **Main actor:** every mutable property is main-actor isolated. SwiftUI
///   binds them safely; other UI code should mutate on the main queue.
/// - **Audio thread:** calls the non-isolated ``snapshot()`` accessor, which
///   returns a value-type ``Snapshot`` under an
///   `OSAllocatedUnfairLock`. Locking is O(1) and only contended when the UI
///   is actively dragging a knob. The per-sample loop then reads from the
///   local snapshot — no locks on the hot path.
///
/// ## Tearing model
///
/// The snapshot is atomic (whole struct swapped under the unfair lock), so
/// the audio thread never sees a half-updated parameter set. Callers that
/// need atomic multi-property updates should use ``updateAtomically(_:)``,
/// which coalesces the intermediate `didSet` publishes into a single
/// snapshot write at the end of the closure.
///
/// > Note: the bytebeat DSP has one piece of monotonic state (the sample
/// > counter in ``BytebeatEngine``). All other parameters read from the
/// > snapshot are essentially read-only per buffer, so slight update-order
/// > differences across parameters are inaudible.
@MainActor
public final class SynthParameters: ObservableObject {

    // MARK: - Bytebeat song selection

    /// Currently active bytebeat song, `0…7`. Mirrors `bytebeat_song` in the
    /// firmware.
    @Published public var songIndex: Int = 0 { didSet { publish() } }

    // MARK: - Modulation variables (`var_p[0…3]`)

    /// First continuous modulation input, `0…255`. Mirrors `var_p[0]`.
    @Published public var variableA: UInt8 = 0 { didSet { publish() } }

    /// Second continuous modulation input, `0…255`. Mirrors `var_p[1]`.
    @Published public var variableB: UInt8 = 0 { didSet { publish() } }

    /// Third continuous modulation input, `0…255`. Mirrors `var_p[2]`.
    @Published public var variableC: UInt8 = 0 { didSet { publish() } }

    /// Fourth continuous modulation input, `0…255`. Mirrors `var_p[3]`.
    @Published public var variableD: UInt8 = 0 { didSet { publish() } }

    // MARK: - Bit-rate dividers

    /// Primary bit-rate divider. Larger values slow the base counter and
    /// drop the perceived pitch. Mirrors `bit1`; per-song defaults live in
    /// ``defaultBit1PerSong``.
    ///
    /// > Precondition: values `< 1` are clamped upward at the render site.
    @Published public var bit1: UInt8 = 4 { didSet { publish() } }

    /// Secondary bit-rate divider, applied to the right channel of many
    /// songs to introduce stereo movement. Mirrors `bit2`.
    ///
    /// > Precondition: values `< 1` are clamped upward at the render site.
    @Published public var bit2: UInt8 = 2 { didSet { publish() } }

    // MARK: - Loop boundaries

    /// Lower bound of the bytebeat counter's playback window. Mirrors
    /// `bytebeat_song_start`.
    @Published public var songStart: Int = 0 { didSet { publish() } }

    /// Length of the playback window in samples, or ``songLengthUnlimited``
    /// to disable looping. Mirrors `bytebeat_song_length`.
    @Published public var songLength: Int = SynthParameters.songLengthUnlimited { didSet { publish() } }

    // MARK: - Effects

    /// Whether the ring-buffer echo (see ``EchoBuffer``) is applied to the
    /// bytebeat output. Mirrors `bytebeat_echo`.
    @Published public var echoOn: Bool = false { didSet { publish() } }

    /// Selects one of the stereo blend presets in ``StereoMixer/blendRatios``.
    /// `0` = mono-ish 50/50, `3` = full split. Mirrors `stereo_mixing_step`.
    @Published public var stereoMixStep: Int = 1 { didSet { publish() } }

    /// Output gain, applied as a left shift on the packed int16 sample.
    /// Mirrors `BB_SHIFT_VOLUME` (firmware default: 3).
    @Published public var outputShiftVolume: UInt8 = 3 { didSet { publish() } }

    // MARK: - Optional sine-waves layer

    /// Enables the ``SineWavesEngine`` overlay. When on, the arpeggiator and
    /// step sequencer drive the sine layer; the bytebeat layer is unaffected.
    @Published public var sineWavesEnabled: Bool = false { didSet { publish() } }

    // MARK: - Arpeggiator / sequencer

    /// Arpeggiator mode. `0` = off; other values map to ``Arpeggiator/Mode``.
    @Published public var arpMode: Int = 0 { didSet { publish() } }

    /// Active step-sequencer pattern slot, `0…8`. `0` disables the sequencer.
    @Published public var sequencerSlot: Int = 0 { didSet { publish() } }

    /// Whether the step sequencer is currently running.
    @Published public var sequencerRunning: Bool = false { didSet { publish() } }

    /// Tempo, expressed as samples between arp/seq ticks. Mirrors
    /// `SEQUENCER_TIMING`. Convert to BPM via
    /// `deviceSampleRate * 60 / tempoSamplesPerTick`.
    @Published public var tempoSamplesPerTick: Int = SynthParameters.defaultTempoSamplesPerTick { didSet { publish() } }

    /// Set the tempo in beats per minute.
    ///
    /// - Parameter bpm: Desired tempo. Values outside `30…400` are clamped
    ///   into that range; non-positive values are ignored (avoids a divide
    ///   by zero).
    public func setTempo(bpm: Double) {
        guard bpm > 0 else { return }
        let clamped = max(30.0, min(400.0, bpm))
        let sr = BytebeatEngine.deviceSampleRate
        tempoSamplesPerTick = max(64, Int(sr * 60.0 / clamped))
    }

    // MARK: - Constants

    /// Sentinel value for ``songLength`` disabling the playback window.
    public nonisolated static let songLengthUnlimited: Int = -1

    /// Total number of built-in bytebeat songs.
    public nonisolated static let numberOfSongs: Int = 8

    /// Default tempo: 120 BPM at 32,768 Hz. Matches `tempo_table[4]` in the
    /// firmware (`I2S_AUDIOFREQ / 2`).
    public nonisolated static let defaultTempoSamplesPerTick: Int = 32_768 / 2

    /// Per-song default `bit1` values. From `patch_bit1[]` in
    /// `main/dsp/Bytebeat.cpp`.
    public nonisolated static let defaultBit1PerSong: [UInt8] = [4, 4, 4, 3, 4, 2, 4, 4]

    /// Per-song default `bit2` values. From `patch_bit2[]` in
    /// `main/dsp/Bytebeat.cpp`.
    public nonisolated static let defaultBit2PerSong: [UInt8] = [2, 2, 2, 2, 2, 2, 2, 2]

    // MARK: - Init

    /// Create a parameter store pre-populated with song 0's defaults.
    ///
    /// The initializer is `nonisolated` so it can be used as a default
    /// argument in call sites outside the main actor (e.g. as
    /// `init(parameters: SynthParameters = SynthParameters())`). It only
    /// writes to instance storage and touches no main-actor state until the
    /// caller starts mutating properties.
    public nonisolated init() {
        // Directly initialize the underlying storage rather than going
        // through `@Published` didSet handlers (which are main-actor
        // isolated). The final `publish()` call is unnecessary here because
        // the lock's initialState already matches these values.
    }

    // MARK: - Convenience

    /// Switch to the given song and load its per-song ``defaultBit1PerSong`` /
    /// ``defaultBit2PerSong`` values in a single atomic update.
    ///
    /// - Parameter index: Song number, `0…7`. Values outside the range are
    ///   clamped.
    public func selectSong(_ index: Int) {
        let clamped = max(0, min(Self.numberOfSongs - 1, index))
        updateAtomically {
            songIndex = clamped
            bit1 = Self.defaultBit1PerSong[clamped]
            bit2 = Self.defaultBit2PerSong[clamped]
        }
    }

    /// Apply a group of parameter mutations as a single atomic snapshot.
    /// The audio thread will not observe any intermediate state — it sees
    /// either the values before the block or the values after, never a mix.
    ///
    /// SwiftUI still receives one `objectWillChange` publish per mutated
    /// property (unavoidable without dropping `@Published`), but the snapshot
    /// slot read by the audio thread only updates once, at block exit.
    ///
    /// - Parameter body: The mutations to apply. Must be synchronous.
    public func updateAtomically(_ body: () -> Void) {
        suppressSnapshotPublish = true
        body()
        suppressSnapshotPublish = false
        publish()
    }

    // MARK: - Thread-safe snapshot

    /// Immutable, value-type copy of everything the audio thread needs.
    ///
    /// `Sendable` and cheap to copy (roughly 96 bytes). Any change to the
    /// stored parameters produces a fresh `Snapshot` via ``publish()``.
    public struct Snapshot: Sendable, Equatable {
        public var songIndex: Int
        public var varA: UInt8
        public var varB: UInt8
        public var varC: UInt8
        public var varD: UInt8
        public var bit1: UInt8
        public var bit2: UInt8
        public var songStart: Int
        public var songLength: Int
        public var echoOn: Bool
        public var stereoMixStep: Int
        public var outputShiftVolume: UInt8
        public var sineWavesEnabled: Bool
        public var arpMode: Int
        public var sequencerSlot: Int
        public var sequencerRunning: Bool
        public var tempoSamplesPerTick: Int

        /// Neutral defaults matching the firmware's power-on state (song 0,
        /// no modulation, echo off, volume shift 3, tempo 120 BPM).
        public nonisolated static let `default` = Snapshot(
            songIndex: 0,
            varA: 0, varB: 0, varC: 0, varD: 0,
            bit1: 4, bit2: 2,
            songStart: 0,
            songLength: SynthParameters.songLengthUnlimited,
            echoOn: false,
            stereoMixStep: 1,
            outputShiftVolume: 3,
            sineWavesEnabled: false,
            arpMode: 0,
            sequencerSlot: 0,
            sequencerRunning: false,
            tempoSamplesPerTick: SynthParameters.defaultTempoSamplesPerTick
        )
    }

    private let lock = OSAllocatedUnfairLock<Snapshot>(initialState: .default)

    /// Return the most recent parameter snapshot. Safe to call from the
    /// audio thread — the underlying storage is guarded by an unfair lock
    /// with a wait-free read.
    ///
    /// > Realtime: safe. Contended only when the UI is actively mutating
    /// > parameters; contention is bounded by a single struct copy.
    public nonisolated func snapshot() -> Snapshot {
        lock.withLock { $0 }
    }

    // MARK: - Publishing internals

    private var suppressSnapshotPublish = false

    private func publish() {
        guard !suppressSnapshotPublish else { return }
        let s = Snapshot(
            songIndex: songIndex,
            varA: variableA, varB: variableB, varC: variableC, varD: variableD,
            bit1: bit1, bit2: bit2,
            songStart: songStart, songLength: songLength,
            echoOn: echoOn,
            stereoMixStep: stereoMixStep,
            outputShiftVolume: outputShiftVolume,
            sineWavesEnabled: sineWavesEnabled,
            arpMode: arpMode,
            sequencerSlot: sequencerSlot,
            sequencerRunning: sequencerRunning,
            tempoSamplesPerTick: tempoSamplesPerTick
        )
        lock.withLock { $0 = s }
    }
}
