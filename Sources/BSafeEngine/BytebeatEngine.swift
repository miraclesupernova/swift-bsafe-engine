// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import Foundation

/// The bytebeat sample generator.
///
/// Owns the monotonic `songPtr` counter, consumes a
/// ``SynthParameters/Snapshot`` per render buffer, and emits one stereo sample
/// per call. This class ports the tail of the firmware's
/// `bytebeat_next_sample()` in `main/dsp/Bytebeat.cpp`.
///
/// ## Sample path
///
/// 1. Advance `songPtr`.
/// 2. Optionally wrap it inside `[songStart, songStart + songLength)`.
/// 3. Compute `(left8, right8)` via ``BytebeatSongs/render(song:songPtr:bit1:bit2:varP:)``.
/// 4. Pack: `left16 = (UInt16(left8) << outputShiftVolume) & 0xFFFF` (matches
///    the device's I2S int16 output framing).
/// 5. Apply the ``StereoMixer`` blend.
/// 6. Apply the ``EchoBuffer`` feedback delay when enabled.
/// 7. Normalize to `Float` in `[-1, 1]`.
///
/// > Thread safety: audio-thread-only. Not safe to touch from any other
/// > thread once ``renderNextSample()`` has started firing. UI mutations must
/// > flow through ``SynthParameters`` and are picked up at the top of each
/// > render buffer via ``applySnapshot(_:)``.
///
/// > Realtime: safe. Per-sample allocation-free and lock-free. The only
/// > memory writes are to `Int` / `UInt8` fields and the ``EchoBuffer``'s
/// > pre-sized ring.
public final class BytebeatEngine: @unchecked Sendable {

    // MARK: - Constants

    /// Sample rate the engine renders at. Fixed at 32,768 Hz to match the
    /// device's `I2S_AUDIOFREQ`. `AVAudioSourceNode` (or any host) is
    /// responsible for resampling to the hardware rate.
    public static let deviceSampleRate: Double = 32_768.0

    // MARK: - State

    /// Sample counter. `Int32` on purpose — matches the ESP32's `int` width
    /// so overflow-driven song behaviors line up with the firmware.
    private var songPtr: Int32 = 0
    private var params: SynthParameters.Snapshot = .default
    private var echo = EchoBuffer()
    private let stereoMixer = StereoMixer()

    // MARK: - Init

    /// Create a bytebeat engine seeded with the neutral snapshot defaults.
    public init() {}

    // MARK: - Lifecycle

    /// Update the engine's parameter view.
    ///
    /// Call this once at the top of every audio render buffer, before the
    /// per-sample loop, so the whole buffer is rendered from a single
    /// coherent parameter set.
    ///
    /// - Parameter snapshot: The parameter values to apply.
    ///
    /// > Realtime: safe. Copies a small struct; no allocation.
    public func applySnapshot(_ snapshot: SynthParameters.Snapshot) {
        self.params = snapshot
    }

    /// Reset the sample counter and clear the echo tail. Use when playback
    /// stops or when selecting a new song.
    ///
    /// > Realtime: safe *only* to the extent that ``EchoBuffer/clear()``
    /// > iterates the ring buffer. Call from the audio thread's control path
    /// > (e.g., at the top of a render buffer), not per-sample.
    public func reset() {
        songPtr = 0
        echo.clear()
    }

    // MARK: - Render

    /// Generate one stereo sample.
    ///
    /// - Returns: A `(left, right)` pair in `[-1, 1]`, ready for consumption
    ///   by an `AVAudioSourceNode` render block or equivalent host.
    ///
    /// > Realtime: safe. Allocation-free, lock-free, wait-free.
    public func renderNextSample() -> (left: Float, right: Float) {
        songPtr = songPtr &+ 1

        if params.songLength != SynthParameters.songLengthUnlimited {
            let start = Int32(clamping: params.songStart)
            let length = Int32(clamping: max(1, params.songLength))
            if songPtr >= start &+ length {
                songPtr = start
            }
        }

        let (left8, right8) = BytebeatSongs.render(
            song: params.songIndex,
            songPtr: songPtr,
            bit1: params.bit1,
            bit2: params.bit2,
            varP: (params.varA, params.varB, params.varC, params.varD)
        )

        // Match the device's I2S output framing: the raw uint8 sample is
        // widened to uint16, left-shifted by BB_SHIFT_VOLUME, then stored as
        // signed int16.
        let shift = Int(params.outputShiftVolume)
        let leftPCM = Int16(truncatingIfNeeded: (UInt16(left8) << shift) & 0xFFFF)
        let rightPCM = Int16(truncatingIfNeeded: (UInt16(right8) << shift) & 0xFFFF)

        var (l, r) = stereoMixer.mix(
            left: leftPCM,
            right: rightPCM,
            step: params.stereoMixStep
        )

        if params.echoOn {
            l = echo.process(l)
            r = echo.process(r)
        }

        // Normalize to [-1, 1]. Divide by 32768 rather than the observed
        // peak so downstream mixers have headroom to add gain without
        // clipping.
        return (Float(l) / 32_768.0, Float(r) / 32_768.0)
    }
}
