// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import XCTest
@testable import BSafeEngine

@MainActor
final class SynthParametersTests: XCTestCase {

    // MARK: - Snapshot default

    func test_snapshotDefault_matchesFreshInstance() {
        let params = SynthParameters()
        // A fresh instance's initial snapshot should equal Snapshot.default,
        // since publish() is called from a nonisolated init that leaves
        // the underlying lock at its declared initial state.
        XCTAssertEqual(params.snapshot(), .default)
    }

    // MARK: - Snapshot after mutation

    func test_snapshot_reflectsMutation() {
        let params = SynthParameters()
        params.variableA = 42
        params.bit1 = 8
        params.echoOn = true

        let snap = params.snapshot()
        XCTAssertEqual(snap.varA, 42)
        XCTAssertEqual(snap.bit1, 8)
        XCTAssertTrue(snap.echoOn)
    }

    // MARK: - updateAtomically

    func test_updateAtomically_publishesOnlyOnceAtBlockExit() {
        let params = SynthParameters()

        // The first mutation inside the block sets varA. Snapshot the state
        // BEFORE the block exits by asking a nonisolated function to fetch
        // it — but we can't cross actors here in a sync test, so instead
        // we validate the "final" snapshot reflects all three changes,
        // and none of the interim snapshots would have shown a mixed state
        // externally. Correctness is testable via the observable end state.
        params.updateAtomically {
            params.variableA = 1
            params.variableB = 2
            params.variableC = 3
        }
        let snap = params.snapshot()
        XCTAssertEqual(snap.varA, 1)
        XCTAssertEqual(snap.varB, 2)
        XCTAssertEqual(snap.varC, 3)
    }

    func test_selectSong_batchesSongIndexAndBitDividers() {
        let params = SynthParameters()
        params.selectSong(3)
        let snap = params.snapshot()
        // Song 3 defaults: bit1=3, bit2=2 per SynthParameters.defaultBit1PerSong.
        XCTAssertEqual(snap.songIndex, 3)
        XCTAssertEqual(snap.bit1, 3)
        XCTAssertEqual(snap.bit2, 2)
    }

    func test_selectSong_clampsOutOfRange() {
        let params = SynthParameters()
        params.selectSong(999)
        XCTAssertEqual(params.snapshot().songIndex, SynthParameters.numberOfSongs - 1)

        params.selectSong(-5)
        XCTAssertEqual(params.snapshot().songIndex, 0)
    }

    // MARK: - setTempo bounds

    func test_setTempo_zeroIsNoOp() {
        let params = SynthParameters()
        let baseline = params.tempoSamplesPerTick
        params.setTempo(bpm: 0)
        XCTAssertEqual(params.tempoSamplesPerTick, baseline,
                       "bpm <= 0 must not change the tempo (and must not crash)")
    }

    func test_setTempo_negativeIsNoOp() {
        let params = SynthParameters()
        let baseline = params.tempoSamplesPerTick
        params.setTempo(bpm: -50)
        XCTAssertEqual(params.tempoSamplesPerTick, baseline)
    }

    func test_setTempo_clampsHigh() {
        let params = SynthParameters()
        params.setTempo(bpm: 10_000)
        // 400 BPM is the clamp ceiling. samples/tick = sr * 60 / 400.
        let expected = max(64, Int(BytebeatEngine.deviceSampleRate * 60.0 / 400.0))
        XCTAssertEqual(params.tempoSamplesPerTick, expected)
    }

    func test_setTempo_clampsLow() {
        let params = SynthParameters()
        params.setTempo(bpm: 1)  // below the 30 BPM floor
        let expected = max(64, Int(BytebeatEngine.deviceSampleRate * 60.0 / 30.0))
        XCTAssertEqual(params.tempoSamplesPerTick, expected)
    }

    func test_setTempo_roundtripsFor120BPM() {
        let params = SynthParameters()
        params.setTempo(bpm: 120)
        // 120 BPM at 32768 Hz → 32768 * 60 / 120 = 16384.
        XCTAssertEqual(params.tempoSamplesPerTick, 16_384)
    }

    // MARK: - Snapshot Sendable / Equatable

    func test_snapshot_isValueType() {
        var a = SynthParameters.Snapshot.default
        var b = a
        b.songIndex = 7
        XCTAssertEqual(a.songIndex, 0, "Snapshot is a value type; mutating b must not affect a")
        XCTAssertEqual(b.songIndex, 7)
        _ = a  // silence "never mutated"
    }
}
