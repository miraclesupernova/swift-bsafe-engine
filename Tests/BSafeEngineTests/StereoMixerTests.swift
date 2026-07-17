// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import XCTest
@testable import BSafeEngine

final class StereoMixerTests: XCTestCase {

    func test_passThrough_isTheDefaultBehavior() {
        // Matches the shipping firmware: applyBlend is off, samples pass
        // through unchanged.
        let m = StereoMixer()
        let (l, r) = m.mix(left: 12_345, right: -6_789, step: 0)
        XCTAssertEqual(l, 12_345)
        XCTAssertEqual(r, -6_789)
    }

    func test_step3_isFullSplit_withApplyBlendOn() {
        var m = StereoMixer()
        m.applyBlend = true
        // step 3 = ratio 0.0 → no cross-channel bleed.
        let (l, r) = m.mix(left: 100, right: 200, step: 3)
        XCTAssertEqual(l, 100)
        XCTAssertEqual(r, 200)
    }

    func test_step0_is50_50Mix() {
        var m = StereoMixer()
        m.applyBlend = true
        // step 0 = ratio 0.5 → symmetric average.
        let (l, r) = m.mix(left: 100, right: 200, step: 0)
        XCTAssertEqual(l, 150)
        XCTAssertEqual(r, 150)
    }

    func test_step1_is60_40Mix() {
        var m = StereoMixer()
        m.applyBlend = true
        // step 1 = ratio 0.4 → l = 100*0.6 + 200*0.4 = 60 + 80 = 140.
        let (l, r) = m.mix(left: 100, right: 200, step: 1)
        XCTAssertEqual(l, 140)
        XCTAssertEqual(r, 160)
    }

    func test_outOfRangeStep_clampsIntoRange() {
        var m = StereoMixer()
        m.applyBlend = true
        // Negative → clamp to 0 (50/50). Above 3 → clamp to 3 (0.0 split).
        let low  = m.mix(left: 100, right: 200, step: -5)
        let high = m.mix(left: 100, right: 200, step: 99)
        XCTAssertEqual(low.0, 150)
        XCTAssertEqual(high.0, 100)
    }

    func test_symmetricInput_producesSymmetricOutput() {
        var m = StereoMixer()
        m.applyBlend = true
        for step in 0..<StereoMixer.blendRatios.count {
            let (l, r) = m.mix(left: 100, right: -100, step: step)
            XCTAssertEqual(l, -r,
                "Symmetric input at step \(step) should yield symmetric output")
        }
    }
}
