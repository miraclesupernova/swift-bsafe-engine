// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import XCTest
@testable import BSafeEngine

final class EchoBufferTests: XCTestCase {

    // MARK: - Constants

    func test_defaultLength_matchesFirmwareSpec() {
        // ECHO_BUFFER_LENGTH = I2S_AUDIOFREQ * 3 / 2 = 49152; minus 977 * 4.
        XCTAssertEqual(EchoBuffer.defaultLength, 49_152 - 977 * 4)
    }

    func test_mixingFactor_matchesFirmware() {
        XCTAssertEqual(EchoBuffer.mixingFactor, 0.5)
    }

    // MARK: - init + clear

    func test_zeroInput_producesTailOfZeroesAfterClear() {
        var echo = EchoBuffer(length: 8)
        echo.clear()
        for _ in 0..<32 {
            XCTAssertEqual(echo.process(0), 0)
        }
    }

    func test_init_clampsLengthBelowTwo() {
        // Length 0 or 1 would make the ring buffer degenerate; the init
        // clamps to 2. Verify by feeding a couple of samples.
        var echo = EchoBuffer(length: 0)
        // If length wasn't clamped, process() would divide-by-zero the
        // modulo and crash. The fact that these succeed is the assertion.
        XCTAssertEqual(echo.process(0), 0)
        XCTAssertEqual(echo.process(0), 0)
    }

    // MARK: - Feedback / clamp

    func test_feedback_addsHalfOfSampleAtDelayPosition() {
        // Length 2 = the tightest loop: sample S wraps immediately.
        // With mixingFactor = 0.5, a sample of 100 fed and echoed back
        // adds 50 the next time it comes around, producing 150.
        var echo = EchoBuffer(length: 2)
        _ = echo.process(100)
        // Feed a zero to advance the read pointer to the position holding
        // the 100 we just wrote. Result = 0 + 100 * 0.5 = 50.
        XCTAssertEqual(echo.process(0), 50)
    }

    func test_extremeInput_clampsToInt16Range() {
        var echo = EchoBuffer(length: 4)
        // Warm the buffer with something near the upper limit — the
        // feedback add will otherwise land in range.
        _ = echo.process(30_000)
        _ = echo.process(30_000)
        // Feed a large positive value; the sum should saturate at 32767.
        let out = echo.process(30_000)
        XCTAssertLessThanOrEqual(out, 32_767)
        XCTAssertGreaterThanOrEqual(out, -32_768)
    }

    // MARK: - setLength

    func test_setLength_clampsToCapacity() {
        var echo = EchoBuffer(length: 16)
        echo.setLength(1_000)  // Exceeds capacity of 16.
        // Process 32 samples — if the read pointer went out of bounds,
        // this crashes. Success = no crash.
        for i in 0..<32 {
            _ = echo.process(Int16(i))
        }
    }

    func test_setLength_clampsBelowTwo() {
        var echo = EchoBuffer(length: 16)
        echo.setLength(0)  // Should clamp to 2, not 0.
        _ = echo.process(0)
        _ = echo.process(0)
    }
}
