// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import Foundation

/// Top-level orchestrator for the BSAFE synth.
///
/// Owns the four sub-engines (``BytebeatEngine``, ``SineWavesEngine``,
/// ``Arpeggiator``, ``StepSequencer``), routes tempo ticks between them, and
/// mixes their outputs into one stereo sample. This is the entry point most
/// audio-host integrations will use.
///
/// One instance is owned by the audio thread. UI mutations flow through
/// ``SynthParameters`` — the core snapshots them once per render buffer.
///
/// > Thread safety: audio-thread-only. Lifecycle operations (``init()``,
/// > ``reset()``, ``setKeyWaveform(_:forKey:)``) may run on any thread
/// > *before* the audio thread starts driving ``renderNextSample()``.
///
/// > Realtime: safe on the render path.
public final class SynthCore: @unchecked Sendable {

    // MARK: - Sub-engines

    private let bytebeat = BytebeatEngine()
    private let sineWaves = SineWavesEngine()
    private let arpeggiator = Arpeggiator()
    private let sequencer = StepSequencer()

    // MARK: - State

    /// Sample counter used to schedule arp/seq ticks. Wraps at `Int.max`
    /// via `&+`; at 32,768 Hz that's over 800,000 years — plenty.
    private var sampleCounter: Int = 0

    private var params: SynthParameters.Snapshot = .default

    // MARK: - Init

    /// Create the core and pre-warm the wavetables so the first note
    /// doesn't stall the audio thread.
    public init() {
        Wavetables.warmup()
    }

    // MARK: - Lifecycle

    /// Update the parameter snapshot for the upcoming render buffer.
    ///
    /// - Parameter snapshot: The parameter values to apply.
    ///
    /// > Realtime: safe.
    public func applySnapshot(_ snapshot: SynthParameters.Snapshot) {
        self.params = snapshot
        bytebeat.applySnapshot(snapshot)

        arpeggiator.mode = Arpeggiator.Mode(rawValue: snapshot.arpMode) ?? .off
        sequencer.currentSequence = snapshot.sequencerSlot
        if sequencer.isRunning != snapshot.sequencerRunning {
            sequencer.setRunning(snapshot.sequencerRunning)
        }
    }

    /// Reset all sub-engines and the tempo counter.
    public func reset() {
        bytebeat.reset()
        sineWaves.reset()
        arpeggiator.reset()
        sequencer.setRunning(false)
        sampleCounter = 0
    }

    // MARK: - Render

    /// Produce one stereo sample.
    ///
    /// - Returns: A `(left, right)` pair in `[-1, 1]`.
    ///
    /// > Realtime: safe for tonal waveforms. See
    /// > ``SineWavesEngine/renderNextSample()`` for the RNG-waveform caveat.
    public func renderNextSample() -> (left: Float, right: Float) {
        // 1. Bytebeat layer.
        let (bLeft, bRight) = bytebeat.renderNextSample()

        // 2. SineWaves layer.
        var sLeft: Float = 0
        var sRight: Float = 0
        if params.sineWavesEnabled {
            let mono = sineWaves.renderNextSample()
            sLeft = mono
            sRight = mono
        }

        // 3. Advance the tempo counter; fire arp/seq ticks.
        //
        // Tempo tick jitter is up to one sample (30 μs at 32.768 kHz) —
        // inaudible.
        sampleCounter &+= 1
        if sampleCounter >= params.tempoSamplesPerTick {
            sampleCounter = 0
            tickTempoBasedEngines()
        }

        // 4. Mix. Bytebeat and sine layers are both normalized to [-1, 1].
        //    Half-gain the sine layer to leave headroom and soft-clip the
        //    sum so parameter jumps don't ping the DAC.
        let left = softClip(bLeft + sLeft * 0.5)
        let right = softClip(bRight + sRight * 0.5)
        return (left, right)
    }

    // MARK: - Manual note triggering

    /// Trigger a mini-piano note on the sine-waves layer.
    ///
    /// - Parameters:
    ///   - note: 1-based note index.
    ///   - octaveShift: Octave offset (see
    ///     ``SineWavesEngine/trigger(note:octaveShift:)``).
    public func triggerNote(_ note: Int, octaveShift: Int = 0) {
        sineWaves.trigger(note: note, octaveShift: octaveShift)
    }

    /// Set the preferred waveform for a mini-piano key.
    ///
    /// - Parameters:
    ///   - waveform: Waveform to bind.
    ///   - key: Zero-based key index.
    public func setKeyWaveform(_ waveform: MiniPiano.Waveform, forKey key: Int) {
        sineWaves.setKeyWaveform(waveform, forKey: key)
    }

    // MARK: - Internals

    /// Called on a tempo tick to advance the arpeggiator and step sequencer.
    private func tickTempoBasedEngines() {
        if let event = arpeggiator.step() {
            sineWaves.trigger(note: event.note, octaveShift: event.octave)
        }
        if let event = sequencer.step() {
            if let note = event.note {
                sineWaves.trigger(note: note, octaveShift: event.octave)
            } else {
                sineWaves.stop()  // pause marker
            }
        }
    }

    /// `x / (1 + |x|)` — maps `R` to `(-1, 1)`, roughly linear near zero,
    /// smoothly limits at the edges. Cheap and free of hard-clip harshness.
    @inline(__always)
    private func softClip(_ x: Float) -> Float {
        x / (1 + abs(x))
    }
}
