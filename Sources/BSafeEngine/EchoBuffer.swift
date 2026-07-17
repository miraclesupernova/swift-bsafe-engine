// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import Foundation

/// Fixed-length ring-buffer echo matching `bytebeat_echo()` in
/// `main/dsp/Bytebeat.cpp`.
///
/// The firmware echo is a simple feedback delay with a fixed mixing factor of
/// 0.5. Buffer length defaults to `ECHO_BUFFER_LENGTH - 977 * 4`; callers can
/// change the delay time on the fly via ``setLength(_:)``.
///
/// Per-sample processing (mirrors the C reference exactly):
/// ```
/// ptr0 = (ptr0 + 1) % length
/// ptr1 = (ptr0 + 1) % length
/// mix  = float(sample) + float(buffer[ptr1]) * 0.5
/// mix  = clamp(mix, -32768, 32767)
/// buffer[ptr0] = int16(mix)
/// return int16(mix)
/// ```
///
/// This is a `struct` (not a `class`) because it is single-owner within the
/// audio thread's ``BytebeatEngine``. `mutating` methods make sharing
/// mistakes visible to the compiler.
///
/// > Thread safety: single-owner. Not intended to be shared across threads.
///
/// > Realtime: safe. Allocation-free once initialized. ``clear()`` iterates
/// > the ring buffer — call from a control-path point (e.g. before starting
/// > playback), not inside the per-sample loop.
public struct EchoBuffer: Sendable {

    // MARK: - Constants

    /// Default buffer length in samples.
    ///
    /// From `main/dsp/Bytebeat.cpp`:
    /// `ECHO_BUFFER_LENGTH - 977*4` where
    /// `ECHO_BUFFER_LENGTH = I2S_AUDIOFREQ * 3 / 2 = 49_152` (32,768 × 3/2).
    /// Result: `45_244` samples ≈ 1.38 s at 32.768 kHz.
    public static let defaultLength: Int = 49_152 - 977 * 4

    /// Feedback mixing coefficient. Matches
    /// `BYTEBEAT_ECHO_MIXING_FACTOR = 0.5f`.
    public static let mixingFactor: Float = 0.5

    /// Upper clamp on the mixed sample. Matches
    /// `COMPUTED_SAMPLE_MIXING_LIMIT_UPPER`.
    public static let upperLimit: Float = 32_767

    /// Lower clamp on the mixed sample. Matches
    /// `COMPUTED_SAMPLE_MIXING_LIMIT_LOWER`.
    public static let lowerLimit: Float = -32_768

    // MARK: - State

    private var buffer: [Int16]
    private var ptr0: Int
    private var length: Int

    // MARK: - Init

    /// Create a fresh echo buffer.
    ///
    /// - Parameter length: Delay length in samples. Values `< 2` are clamped
    ///   to `2` to keep the ring buffer valid.
    public init(length: Int = EchoBuffer.defaultLength) {
        self.length = max(2, length)
        self.buffer = Array(repeating: 0, count: self.length)
        self.ptr0 = 0
    }

    // MARK: - Lifecycle

    /// Zero the ring buffer and reset the read pointer.
    public mutating func clear() {
        for i in 0..<buffer.count { buffer[i] = 0 }
        ptr0 = 0
    }

    /// Change the effective delay length.
    ///
    /// - Parameter newLength: Requested delay in samples. Clamped to
    ///   `2 … buffer.count` — the underlying storage is not reallocated, so
    ///   the new length cannot exceed the initial capacity.
    public mutating func setLength(_ newLength: Int) {
        length = max(2, min(buffer.count, newLength))
        ptr0 = 0
    }

    // MARK: - Render

    /// Process one sample through the delay line and return the mixed value.
    ///
    /// - Parameter sample: The input sample (int16 PCM).
    /// - Returns: The wet+dry mixed output, also int16 PCM.
    ///
    /// > Realtime: safe.
    public mutating func process(_ sample: Int16) -> Int16 {
        ptr0 &+= 1
        if ptr0 >= length { ptr0 = 0 }

        var ptr1 = ptr0 + 1
        if ptr1 >= length { ptr1 = 0 }

        var mix = Float(sample) + Float(buffer[ptr1]) * EchoBuffer.mixingFactor
        if mix > EchoBuffer.upperLimit { mix = EchoBuffer.upperLimit }
        if mix < EchoBuffer.lowerLimit { mix = EchoBuffer.lowerLimit }

        let out = Int16(mix)
        buffer[ptr0] = out
        return out
    }
}
