// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import XCTest
@testable import BSafeEngine

final class ArpeggiatorTests: XCTestCase {

    // MARK: - .off

    func test_offMode_alwaysReturnsNil() {
        let arp = Arpeggiator()
        arp.mode = .off
        for _ in 0..<64 {
            XCTAssertNil(arp.step())
        }
    }

    // MARK: - .up cycles

    func test_upMode_cyclesForwardThroughPattern() {
        let arp = Arpeggiator()
        arp.mode = .up
        arp.pattern = [1, 2, 3, 4, 5, 6, 7, 8]
        arp.octaveFrom = 0
        arp.octaveTo = 0

        let notes = (0..<8).map { _ in arp.step()?.note }
        XCTAssertEqual(notes, [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func test_upMode_wrapsAtEndOfPattern() {
        let arp = Arpeggiator()
        arp.mode = .up
        arp.pattern = [1, 2, 3, 0, 0, 0, 0, 0]
        arp.octaveFrom = 0
        arp.octaveTo = 0

        var seen: [Int?] = []
        for _ in 0..<9 {
            seen.append(arp.step()?.note)
        }
        // Only three non-zero slots; the sequence must cycle:
        // 1, 2, 3, 1, 2, 3, 1, 2, 3.
        XCTAssertEqual(seen, [1, 2, 3, 1, 2, 3, 1, 2, 3])
    }

    // MARK: - .down cycles

    func test_downMode_cyclesBackwardThroughPattern() {
        let arp = Arpeggiator()
        arp.mode = .down
        arp.pattern = [1, 2, 3, 4, 5, 6, 7, 8]
        arp.octaveFrom = 0
        arp.octaveTo = 0

        // First step advances from ptr=-1 to ptr=-2, wraps to end.
        // Result: 8, 7, 6, 5, 4, 3, 2, 1.
        let notes = (0..<8).map { _ in arp.step()?.note }
        XCTAssertEqual(notes, [8, 7, 6, 5, 4, 3, 2, 1])
    }

    // MARK: - Skip empty slots

    func test_up_skipsZeroSlots() {
        let arp = Arpeggiator()
        arp.mode = .up
        arp.pattern = [0, 2, 0, 4, 0, 6, 0, 8]
        arp.octaveFrom = 0
        arp.octaveTo = 0

        let notes = (0..<4).map { _ in arp.step()?.note }
        XCTAssertEqual(notes, [2, 4, 6, 8])
    }

    func test_allZeroPattern_producesNilForever() {
        let arp = Arpeggiator()
        arp.mode = .up
        arp.pattern = Array(repeating: 0, count: 8)
        arp.octaveFrom = 0
        arp.octaveTo = 0

        for _ in 0..<16 {
            XCTAssertNil(arp.step())
        }
    }

    // MARK: - Octave range

    func test_up_incrementsOctaveOnWrap() {
        let arp = Arpeggiator()
        arp.mode = .up
        arp.pattern = [1, 2]
        arp.octaveFrom = 0
        arp.octaveTo = 2

        // 3-slot pattern isn't used here; only two non-zero elements to keep
        // the pattern short and the wrap predictable.
        var octaves: [Int] = []
        for _ in 0..<6 {
            if let e = arp.step() { octaves.append(e.octave) }
        }
        // First pass: octave 0, 0. Wrap → octave 1, 1. Wrap → octave 2, 2.
        XCTAssertEqual(octaves, [0, 0, 1, 1, 2, 2])
    }

    // MARK: - Reset

    func test_reset_returnsPointerToInitial() {
        let arp = Arpeggiator()
        arp.mode = .up
        arp.pattern = [1, 2, 3, 4, 5, 6, 7, 8]

        _ = arp.step()   // ptr moves to 0
        _ = arp.step()   // ptr moves to 1
        arp.reset()
        // After reset the next .up step lands on pattern index 0 again.
        XCTAssertEqual(arp.step()?.note, 1)
    }

    // MARK: - Repeat count 8 (random octave offset)

    func test_repeatCount8_addsRandomOctaveOffset() {
        let arp = Arpeggiator()
        arp.mode = .up
        arp.pattern = [1, 2, 3, 4, 5, 6, 7, 8]
        arp.octaveFrom = 0
        arp.octaveTo = 0
        arp.repeatCount = 8

        // Collect a handful of octave offsets; all must belong to {0,1,3,7}.
        for _ in 0..<32 {
            guard let e = arp.step() else { continue }
            XCTAssertTrue([0, 1, 3, 7].contains(e.octave),
                          "octave offset \(e.octave) not in {0,1,3,7}")
        }
    }
}
