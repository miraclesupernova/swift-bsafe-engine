// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import Foundation

/// Melodic step generator ported from `arp_step()` in
/// `main/dsp/Bytebeat.cpp`.
///
/// Cycles through an 8-slot note pattern in one of several modes, emitting
/// `(note, octave)` events on demand. Not sample-rate: ``SynthCore`` calls
/// ``step()`` once per tempo tick (`tempoSamplesPerTick` samples).
///
/// > Thread safety: audio-thread-only. Owned by ``SynthCore``; UI mutations
/// > flow through ``SynthParameters`` and are copied into the arpeggiator's
/// > public properties from the audio thread's `applySnapshot` call.
///
/// > Realtime: safe. ``step()`` performs no allocation; the random modes use
/// > `Int.random(in:)`, which today allocates a `SystemRandomNumberGenerator`
/// > on first use — an acceptable cost for tempo-tick frequency (≤ tens of
/// > calls per second) but not per-sample.
public final class Arpeggiator: @unchecked Sendable {

    // MARK: - Modes

    /// Direction / behavior of the arpeggiator.
    ///
    /// Raw values match the `ARP_*` constants in `main/dsp/Bytebeat.h`.
    public enum Mode: Int, CaseIterable, Sendable {
        /// Silent — the arp does not produce events.
        case off = 0
        /// Cycle the pattern forward, wrapping across octaves.
        case up = 1
        /// Cycle the pattern backward, wrapping across octaves.
        case down = 2
        /// Bounce between octave range edges, skipping endpoints on reversal.
        case upDown = 3
        /// Bounce between octave range edges, latching at endpoints
        /// (endpoint plays twice on reversal).
        case upDownLatch = 4
        /// Random direction (±1) each step.
        case step = 5
        /// Same as ``step`` but re-triggers on a null-direction pick.
        case stepLatch = 6
        /// Random note in a random octave within the range.
        case random = 7
        /// Same as ``random`` but suppresses immediate repeats.
        case randomLatch = 8
    }

    // MARK: - Event

    /// A single arp trigger.
    public struct Event: Sendable {
        /// 1-based note index. Matches `arp_pattern[]` values (`1…8`) in the
        /// C source.
        public let note: Int
        /// Effective octave (base + optional repeat offset). Consumers feed
        /// this to `wt_octave_shift`.
        public let octave: Int
    }

    // MARK: - Configuration

    /// Current mode. `.off` yields `nil` from ``step()``.
    public var mode: Mode = .off

    /// Pattern of 8 slots. Value `0` = skip, `1…8` = trigger that note.
    public var pattern: [Int] = [1, 2, 3, 4, 5, 6, 7, 8]

    /// Lower bound of the octave range.
    public var octaveFrom: Int = 0

    /// Upper bound of the octave range (inclusive).
    public var octaveTo: Int = 0

    /// Number of times to re-trigger the current step before advancing.
    ///
    /// - `0` — never repeat.
    /// - `1…7` — hold the step for that many extra ticks, adding a rising
    ///   octave offset per repeat.
    /// - `8` — special "random octave offset" mode from the C source (picks
    ///   from `{0, 1, 3, 7}` semitones each step).
    public var repeatCount: Int = 0

    // MARK: - State

    private var ptr: Int = -1
    private var direction: Int = 1
    private var octaveEffective: Int = 0
    private var repeatSoFar: Int = 0

    /// Octave offsets picked at random when `repeatCount == 8`. Hoisted out
    /// of ``step()`` so the array literal isn't reallocated on every tick.
    private static let randomOctaveOffsets: [Int] = [0, 1, 3, 7]

    // MARK: - Init

    public init() {}

    // MARK: - Lifecycle

    /// Reset the state machine. Call this when the user enables the arp
    /// after it has been idle, so the next ``step()`` starts from a clean
    /// pointer.
    public func reset() {
        ptr = -1
        direction = 1
        octaveEffective = octaveFrom
        repeatSoFar = 0
    }

    // MARK: - Step

    /// Advance one arp step.
    ///
    /// - Returns: The event to trigger this tick, or `nil` if the tick
    ///   should be silent (skipped slot, or the mode consumed the tick
    ///   without a new note — e.g. ``Mode/randomLatch`` picked the same
    ///   slot).
    public func step() -> Event? {
        guard mode != .off else { return nil }

        // Repeat logic — either advance the repeat counter (returning early
        // with an octave offset) OR reset it to zero and let the pattern
        // advance.
        //
        // `repeatCount == 8` is special: don't hold the step at all, just
        // pick a random octave offset (0/1/3/7) and let the pattern advance
        // normally.
        var octaveOffset = 0
        if repeatCount == 8 {
            octaveOffset = Self.randomOctaveOffsets.randomElement()!
        } else if repeatCount > 0 {
            if repeatSoFar < repeatCount {
                repeatSoFar += 1
                if ptr >= 0 && ptr < pattern.count && pattern[ptr] != 0 {
                    return Event(note: pattern[ptr],
                                 octave: octaveEffective + repeatSoFar)
                }
                return nil
            }
            repeatSoFar = 0
        }

        switch mode {
        case .off:
            return nil
        case .up:
            advance(direction: 1)
        case .down:
            advance(direction: -1)
        case .upDown, .upDownLatch:
            advanceUpDown()
        case .random, .randomLatch:
            let prevPtr = ptr
            advanceRandom()
            if mode == .randomLatch && ptr == prevPtr {
                return nil
            }
        case .step, .stepLatch:
            let prevPtr = ptr
            advanceStep()
            if mode == .stepLatch && ptr == prevPtr {
                return nil
            }
        }

        guard ptr >= 0 && ptr < pattern.count else { return nil }
        let n = pattern[ptr]
        return n == 0
            ? nil
            : Event(note: n, octave: octaveEffective + octaveOffset)
    }

    // MARK: - Internals

    private func advance(direction: Int) {
        // Skip over empty slots (pattern[i] == 0).
        var next = ptr
        var scanned = 0
        repeat {
            next += direction
            if next >= pattern.count {
                next = 0
                octaveEffective += 1
                if octaveEffective > octaveTo { octaveEffective = octaveFrom }
            } else if next < 0 {
                next = pattern.count - 1
                octaveEffective -= 1
                if octaveEffective < octaveFrom { octaveEffective = octaveTo }
            }
            scanned += 1
            if scanned > pattern.count { break }  // all slots empty; give up
        } while next >= 0 && next < pattern.count && pattern[next] == 0
        ptr = next
    }

    private func advanceUpDown() {
        var next = ptr + direction
        // Bounce off the ends of the octave range.
        if next >= pattern.count {
            if octaveEffective < octaveTo {
                octaveEffective += 1
                next = 0
            } else {
                direction = -1
                next = pattern.count - 1
                if mode == .upDown { next -= 1 }  // skip endpoint
            }
        } else if next < 0 {
            if octaveEffective > octaveFrom {
                octaveEffective -= 1
                next = pattern.count - 1
            } else {
                direction = 1
                next = 0
                if mode == .upDown { next += 1 }  // skip endpoint
            }
        }
        while next >= 0 && next < pattern.count && pattern[next] == 0 {
            next += direction
            if next < 0 || next >= pattern.count { break }
        }
        ptr = max(0, min(pattern.count - 1, next))
    }

    /// One step in a random direction (`-1`, `0`, or `+1`). Zero leaves the
    /// pattern pointer where it was; the caller uses that to detect a
    /// stalled step in ``Mode/stepLatch``.
    private func advanceStep() {
        direction = Int.random(in: -1...1)
        if direction != 0 { advance(direction: direction) }
    }

    private func advanceRandom() {
        if octaveFrom == octaveTo {
            octaveEffective = octaveFrom
        } else {
            octaveEffective = Int.random(in: octaveFrom...octaveTo)
        }
        let nonEmpty = pattern.enumerated().compactMap { $1 == 0 ? nil : $0 }
        if let picked = nonEmpty.randomElement() {
            ptr = picked
        }
    }
}
