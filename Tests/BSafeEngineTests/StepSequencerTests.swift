// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import XCTest
@testable import BSafeEngine

final class StepSequencerTests: XCTestCase {

    // MARK: - Gated by isRunning + currentSequence

    func test_stoppedSequencer_alwaysReturnsNil() {
        let seq = StepSequencer()
        // Never called setRunning(true).
        XCTAssertFalse(seq.isRunning)
        for _ in 0..<8 {
            XCTAssertNil(seq.step())
        }
    }

    func test_slotZero_disablesTheSequencer() {
        let seq = StepSequencer()
        seq.setRunning(true)
        seq.currentSequence = 0
        for _ in 0..<8 {
            XCTAssertNil(seq.step())
        }
    }

    // MARK: - Basic advance

    func test_step_advancesThroughSlotPattern() {
        let seq = StepSequencer()
        seq.currentSequence = 1
        seq.patterns[0] = Array(repeating: 0, count: 64)
        seq.patterns[0][0] = 1
        seq.patterns[0][1] = 2
        seq.patterns[0][2] = 3
        seq.patterns[0][3] = 4
        seq.stepCounts[0] = 4
        seq.setRunning(true)

        let notes = (0..<4).map { _ in seq.step()?.note }
        XCTAssertEqual(notes, [1, 2, 3, 4])
    }

    func test_step_wrapsAtEndOfPattern() {
        let seq = StepSequencer()
        seq.currentSequence = 1
        seq.patterns[0] = Array(repeating: 0, count: 64)
        seq.patterns[0][0] = 1
        seq.patterns[0][1] = 2
        seq.stepCounts[0] = 2
        seq.setRunning(true)

        var notes: [Int?] = []
        for _ in 0..<5 { notes.append(seq.step()?.note) }
        XCTAssertEqual(notes, [1, 2, 1, 2, 1])
    }

    // MARK: - Markers

    func test_pauseMarker_yieldsEventWithNilNote() {
        let seq = StepSequencer()
        seq.currentSequence = 1
        seq.patterns[0] = Array(repeating: 0, count: 64)
        seq.patterns[0][0] = 1
        seq.patterns[0][1] = StepSequencer.pauseMarker
        seq.patterns[0][2] = 3
        seq.stepCounts[0] = 3
        seq.setRunning(true)

        let e0 = seq.step()
        let e1 = seq.step()
        let e2 = seq.step()
        XCTAssertEqual(e0?.note, 1)
        XCTAssertNotNil(e1)     // event fires…
        XCTAssertNil(e1?.note)  // …but with no note (silence).
        XCTAssertEqual(e2?.note, 3)
    }

    func test_continueMarker_returnsNilEventEntirely() {
        let seq = StepSequencer()
        seq.currentSequence = 1
        seq.patterns[0] = Array(repeating: 0, count: 64)
        seq.patterns[0][0] = 1
        seq.patterns[0][1] = StepSequencer.continueMarker
        seq.patterns[0][2] = 2
        seq.stepCounts[0] = 3
        seq.setRunning(true)

        let e0 = seq.step()
        let e1 = seq.step()
        let e2 = seq.step()
        XCTAssertEqual(e0?.note, 1)
        XCTAssertNil(e1)  // hold the previous note — no event at all
        XCTAssertEqual(e2?.note, 2)
    }

    // MARK: - Octave mode

    func test_octaveModeUp_incrementsOnWrap() {
        let seq = StepSequencer()
        seq.currentSequence = 1
        seq.patterns[0] = Array(repeating: 0, count: 64)
        seq.patterns[0][0] = 1
        seq.patterns[0][1] = 2
        seq.stepCounts[0] = 2
        seq.octaveMode = .up
        seq.octaveFrom = 0
        seq.octaveTo = 2
        seq.setRunning(true)

        // First pattern at octave 0, second at 1, third at 2, fourth wraps
        // back to 0. Verify after two full cycles.
        _ = seq.step(); _ = seq.step()  // octave 0
        _ = seq.step(); _ = seq.step()  // octave 1
        let first = seq.step()  // octave 2
        XCTAssertEqual(first?.octave, 2)
    }

    // MARK: - setRunning

    func test_setRunning_resetsPointerToStart() {
        let seq = StepSequencer()
        seq.currentSequence = 1
        seq.patterns[0] = Array(repeating: 0, count: 64)
        seq.patterns[0][0] = 5
        seq.patterns[0][1] = 6
        seq.stepCounts[0] = 2
        seq.setRunning(true)

        _ = seq.step()  // 5
        _ = seq.step()  // 6
        seq.setRunning(true)  // restart
        XCTAssertEqual(seq.step()?.note, 5)
    }
}
