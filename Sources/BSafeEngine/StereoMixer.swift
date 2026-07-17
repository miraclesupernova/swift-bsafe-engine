// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import Foundation

/// Stereo channel blender. Pass-through by default; opt in to blending via
/// ``applyBlend``.
///
/// The firmware cycles through four stereo mixing ratios (see the commented
/// `stereo_mixing[]` table in `main/dsp/Bytebeat.cpp`): `{0.5, 0.4, 0.2, 0.0}`
/// for 50%, 60%, 80% and 100% split ratios. The shipping firmware does not
/// actually apply the blend — it packs `sample1` and `sample2` straight into
/// the two channels. This port preserves that behavior by default (so
/// existing songs sound identical to the hardware) but keeps the blend
/// implementation wired so the UI can enable it later.
///
/// > Thread safety: value type; safe to copy freely between threads.
///
/// > Realtime: safe.
public struct StereoMixer: Sendable {

    // MARK: - Constants

    /// Blend ratios matching the commented-out table in the C source.
    /// - Index `0` — symmetric 50/50 mix (mono-ish).
    /// - Index `3` — full split (no cross-channel bleed).
    public static let blendRatios: [Float] = [0.5, 0.4, 0.2, 0.0]

    // MARK: - Configuration

    /// If `true`, apply the ``blendRatios`` blend. Off by default so the
    /// output matches the shipping firmware.
    public var applyBlend: Bool = false

    // MARK: - Init

    public init() {}

    // MARK: - Render

    /// Blend two channels according to the chosen mixing step.
    ///
    /// When ``applyBlend`` is `false`, returns the input untouched — matching
    /// the shipping firmware's pass-through behavior.
    ///
    /// - Parameters:
    ///   - left: Left-channel input sample (int16 PCM).
    ///   - right: Right-channel input sample (int16 PCM).
    ///   - step: Index into ``blendRatios``. Clamped to the array bounds.
    /// - Returns: A `(left, right)` pair post-blend.
    ///
    /// > Realtime: safe.
    public func mix(left: Int16, right: Int16, step: Int) -> (Int16, Int16) {
        guard applyBlend else { return (left, right) }
        let s = max(0, min(StereoMixer.blendRatios.count - 1, step))
        let a = StereoMixer.blendRatios[s]
        let b = 1.0 - a
        let l = Float(left) * b + Float(right) * a
        let r = Float(right) * b + Float(left) * a
        return (Int16(clamping: Int(l)), Int16(clamping: Int(r)))
    }
}
