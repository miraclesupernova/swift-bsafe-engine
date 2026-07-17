// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import XCTest
@testable import BSafeEngine

final class WavetablesTests: XCTestCase {

    // MARK: - Sizes

    func test_allTables_haveDeclaredSize() {
        XCTAssertEqual(Wavetables.sine.count, Wavetables.size)
        XCTAssertEqual(Wavetables.saw.count, Wavetables.size)
        XCTAssertEqual(Wavetables.square.count, Wavetables.size)
        XCTAssertEqual(Wavetables.multi.count, Wavetables.size)
        XCTAssertEqual(Wavetables.noise.count, Wavetables.size)
    }

    func test_envelope_hasDeclaredSize() {
        XCTAssertEqual(Wavetables.envelope.count, Wavetables.envelopeSize)
    }

    func test_size_isTheFirmwarePrime() {
        // WAVETABLE_SIZE in main/dsp/SineWaves.h — a prime deliberately
        // chosen so wavetable loop period doesn't align with any other
        // DSP loop.
        XCTAssertEqual(Wavetables.size, 7_919)
    }

    // MARK: - Shape sanity

    func test_sineTable_isDCBiasedAround128() {
        // Uint8 values in [0, 255] with DC bias 128. The mean of a full
        // period should sit close to 128.
        let sum = Wavetables.sine.reduce(0) { $0 + Int($1) }
        let mean = Double(sum) / Double(Wavetables.sine.count)
        XCTAssertEqual(mean, 128.0, accuracy: 1.0,
                       "Sine table mean should be ~128 (DC bias)")
    }

    func test_squareTable_isHalfLowHalfHigh() {
        // First half sits at squareDCOffset (64), second half at 64+128 = 192.
        let firstHalf = Wavetables.square.prefix(Wavetables.size / 2)
        let secondHalf = Wavetables.square.suffix(Wavetables.size - Wavetables.size / 2)
        XCTAssertTrue(firstHalf.allSatisfy { $0 == 64 })
        XCTAssertTrue(secondHalf.allSatisfy { $0 == 192 })
    }

    func test_sawTable_isMonotonicallyNonDecreasing() {
        let s = Wavetables.saw
        for i in 1..<s.count {
            XCTAssertGreaterThanOrEqual(s[i], s[i - 1],
                "Saw wavetable must be non-decreasing (index \(i))")
        }
    }

    // MARK: - Envelope

    func test_envelope_startsNearOne() {
        // envelope[0] = pow(0.5, 1 + 0/40) * 2 + 0 = 1.0 exactly.
        XCTAssertEqual(Wavetables.envelope[0], 1.0, accuracy: 1e-6)
    }

    func test_envelope_isMonotonicallyDecreasing() {
        let e = Wavetables.envelope
        for i in 1..<e.count {
            XCTAssertLessThanOrEqual(e[i], e[i - 1],
                "Envelope must be non-increasing (index \(i))")
        }
    }

    func test_envelope_decaysToNearZero() {
        // pow(0.5, 1 + 499/40) * 2 ≈ 2 * 0.5^13.475 ≈ 1.8e-4
        XCTAssertLessThan(Wavetables.envelope.last!, 1e-3)
    }

    // MARK: - Warmup

    func test_warmup_completesWithoutCrashing() {
        // Force init of every table; asserts nothing beyond "doesn't
        // trap on a bad clamp or divide."
        Wavetables.warmup()
        Wavetables.warmup()  // idempotent
    }

    // MARK: - table(for:)

    func test_tableFor_returnsCorrectTablePerWaveform() {
        XCTAssertTrue(Wavetables.table(for: .sine)   == Wavetables.sine)
        XCTAssertTrue(Wavetables.table(for: .saw)    == Wavetables.saw)
        XCTAssertTrue(Wavetables.table(for: .square) == Wavetables.square)
        XCTAssertTrue(Wavetables.table(for: .multi)  == Wavetables.multi)
        XCTAssertTrue(Wavetables.table(for: .noise)  == Wavetables.noise)
        // .rng has no backing table; the accessor returns sine as fallback.
        XCTAssertTrue(Wavetables.table(for: .rng)    == Wavetables.sine)
    }
}
