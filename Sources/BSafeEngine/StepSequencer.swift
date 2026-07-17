// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import Foundation

/// Pattern-based note sequencer ported from `seq_step()` in
/// `main/dsp/Bytebeat.cpp`.
///
/// Holds 8 pattern slots, each up to 64 steps. Every step is either a note
/// number (`1…8`), the ``pauseMarker`` (silence for one step), or the
/// ``continueMarker`` (hold the previous note).
///
/// The sequencer is monophonic — only one slot is active at a time. Switch
/// slots with ``selectSequence(_:)``.
///
/// > Thread safety: audio-thread-only. Owned by ``SynthCore``.
///
/// > Realtime: safe. ``step()`` performs no allocation.
public final class StepSequencer: @unchecked Sendable {

    // MARK: - Modes

    /// Octave-advance behavior applied every time the pattern wraps.
    public enum OctaveMode: Int, CaseIterable, Sendable {
        /// Increment the octave each wrap, looping back to ``octaveFrom``.
        case up = 0
        /// Decrement the octave each wrap, looping back to ``octaveTo``.
        case down = 1
        /// Bounce between ``octaveFrom`` and ``octaveTo``.
        case upDown = 2
        /// Pick a random octave in the range on every step.
        case random = 3
    }

    // MARK: - Markers

    /// Special pattern value meaning "silence for one step". Matches
    /// `SEQ_PATTERN_PAUSE` in the C source.
    public static let pauseMarker: Int = 127

    /// Special pattern value meaning "hold the previous note". Matches
    /// `SEQ_PATTERN_CONTINUE` in the C source.
    public static let continueMarker: Int = 126

    // MARK: - Event

    /// A single sequencer trigger.
    public struct Event: Sendable {
        /// The note to trigger. `nil` for a pause marker (silence).
        public let note: Int?
        /// The effective octave for this step.
        public let octave: Int
    }

    // MARK: - Configuration

    /// Active pattern slot, `0…8`. `0` disables the sequencer entirely.
    public var currentSequence: Int = 0

    /// Number of steps in each slot, `1…64`.
    public var stepCounts: [Int] = Array(repeating: 8, count: 8)

    /// Pattern data — `[slot][step]`. Values are note numbers `1…8`, the
    /// ``pauseMarker``, or the ``continueMarker``.
    public var patterns: [[Int]] = Array(
        repeating: Array(repeating: 0, count: 64), count: 8
    )

    /// How the octave advances between pattern wraps.
    public var octaveMode: OctaveMode = .up

    /// Lower bound of the octave range.
    public var octaveFrom: Int = 0

    /// Upper bound of the octave range (inclusive).
    public var octaveTo: Int = 0

    // MARK: - State

    /// Whether the sequencer is currently running.
    public private(set) var isRunning: Bool = false

    private var stepPtr: Int = -1
    private var octaveEffective: Int = 0
    private var direction: Int = 1  // for .upDown

    // MARK: - Init

    public init() {}

    // MARK: - Lifecycle

    /// Enable or disable playback for the currently selected sequence.
    ///
    /// - Parameter running: `true` to start the sequencer, `false` to stop.
    ///   Setting either value also resets the step pointer.
    public func setRunning(_ running: Bool) {
        isRunning = running
        stepPtr = -1
        direction = 1
        octaveEffective = octaveFrom
    }

    /// Change the active pattern slot.
    ///
    /// - Parameter slot: Pattern slot to activate. `0` disables the
    ///   sequencer; `1…8` selects one of the pattern arrays.
    public func selectSequence(_ slot: Int) {
        currentSequence = max(0, min(8, slot))
        stepPtr = -1
    }

    // MARK: - Step

    /// Advance one step.
    ///
    /// - Returns: The event to trigger this tick, or `nil` for a
    ///   ``continueMarker`` (hold the previous note) or when the sequencer
    ///   is disabled/empty.
    public func step() -> Event? {
        guard isRunning, currentSequence > 0 else { return nil }
        let slot = currentSequence - 1
        guard slot < patterns.count else { return nil }
        let steps = max(1, min(patterns[slot].count, stepCounts[slot]))

        stepPtr += 1
        if stepPtr >= steps {
            stepPtr = 0
            advanceOctave()
        }

        let value = patterns[slot][stepPtr]

        if value == Self.continueMarker {
            return nil
        }

        if octaveMode == .random {
            octaveEffective = octaveFrom == octaveTo
                ? octaveFrom
                : Int.random(in: octaveFrom...octaveTo)
        }

        if value == Self.pauseMarker {
            return Event(note: nil, octave: octaveEffective)
        }

        guard value >= 1 && value <= 8 else { return nil }
        return Event(note: value, octave: octaveEffective)
    }

    // MARK: - Internals

    private func advanceOctave() {
        switch octaveMode {
        case .up:
            octaveEffective += 1
            if octaveEffective > octaveTo { octaveEffective = octaveFrom }
        case .down:
            octaveEffective -= 1
            if octaveEffective < octaveFrom { octaveEffective = octaveTo }
        case .upDown:
            if direction == 1 {
                if octaveEffective < octaveTo {
                    octaveEffective += 1
                } else if octaveFrom != octaveTo {
                    direction = -1
                    octaveEffective -= 1
                }
            } else {
                if octaveEffective > octaveFrom {
                    octaveEffective -= 1
                } else if octaveFrom != octaveTo {
                    direction = 1
                    octaveEffective += 1
                }
            }
        case .random:
            break  // handled per-step in step()
        }
    }
}
