// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import XCTest
@testable import BSafeEngine

/// Compares Swift bytebeat output to the C harness reference WAVs, sample-by-
/// sample. If any song formula translates wrong (missed overflow, wrong
/// operator precedence, sign extension bug) this test fails loud with the
/// exact index of the first mismatched sample.
///
/// The reference WAVs live in `Tests/BSafeEngineTests/ReferenceWavs/`, copied
/// there by the tool at `ios/tools/harness/` from the C source in
/// `main/bytebeat_songs.inc`. To regenerate:
///     cd ios/tools/harness && make run
///     cp ../reference_wavs/*.wav ../../Packages/BSafeEngine/Tests/BSafeEngineTests/ReferenceWavs/
@MainActor
final class BytebeatSongsTests: XCTestCase {

    /// Number of samples to verify per song. We check the FULL 5-second dump
    /// on the assumption that if any single formula is wrong, it'll diverge
    /// well within the first few hundred samples anyway — but full-length
    /// catches slow-onset bugs (e.g., off-by-one in a divisor at large `t`).
    let samplesPerSong = 32768 * 5

    func test_allSongs_matchReferenceWAVs_sampleForSample() throws {
        for song in 0..<8 {
            try assertSongMatchesReference(song: song)
        }
    }

    // MARK: -

    private func assertSongMatchesReference(song: Int) throws {
        // Load reference PCM
        let url = try referenceURL(for: song)
        let referencePCM = try loadInt16StereoPCM(from: url)
        XCTAssertEqual(referencePCM.count, samplesPerSong * 2,
                       "song \(song): reference WAV has wrong sample count")

        // Render Swift engine with matching defaults.
        let params = SynthParameters()
        params.selectSong(song)  // sets songIndex + default bit1/bit2

        let engine = BytebeatEngine()
        engine.applySnapshot(params.snapshot())
        engine.reset()

        // The C harness computes `(uint16_t)mix << 3` and stores as int16.
        // Our BytebeatEngine does the same in `renderNextSample`. But the
        // engine also normalizes to Float in [-1, 1]. We want to compare the
        // *int16 wire values*, so we recompute that step here.
        //
        // Simpler: bypass the float conversion by computing the same path
        // directly. We compare against the pre-float int16 values.
        for i in 0..<samplesPerSong {
            let (leftPCM, rightPCM) = renderInt16Sample(engine: engine)
            let refL = referencePCM[i * 2 + 0]
            let refR = referencePCM[i * 2 + 1]

            if leftPCM != refL || rightPCM != refR {
                XCTFail("""
                    song \(song): mismatch at sample \(i):
                      Swift : L=\(leftPCM) R=\(rightPCM)
                      C ref : L=\(refL)   R=\(refR)
                    """)
                return  // one failure per song is enough
            }
        }
    }

    /// Render one sample from the engine and return it in the same int16 form
    /// the C harness wrote to disk. Bypasses `renderNextSample()`'s float
    /// conversion so we compare the underlying bytebeat math directly.
    private func renderInt16Sample(engine: BytebeatEngine) -> (Int16, Int16) {
        // Drive the engine one step. renderNextSample() returns floats in
        // [-1, 1] normalized by /32768. Multiply back to recover the int16
        // value that was packed onto the wire.
        let (l, r) = engine.renderNextSample()
        let lPCM = Int16(clamping: Int((l * 32768.0).rounded()))
        let rPCM = Int16(clamping: Int((r * 32768.0).rounded()))
        return (lPCM, rPCM)
    }

    // MARK: - WAV loading

    private func referenceURL(for song: Int) throws -> URL {
        // Swift Package Manager copies test resources into
        // `Bundle.module/ReferenceWavs/songN.wav`.
        guard let url = Bundle.module.url(
            forResource: "song\(song)",
            withExtension: "wav",
            subdirectory: "ReferenceWavs"
        ) else {
            throw NSError(
                domain: "BytebeatSongsTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Reference WAV song\(song).wav not found in test bundle. " +
                    "Regenerate with: cd ios/tools/harness && make run"]
            )
        }
        return url
    }

    /// Minimal WAV loader — expects 16-bit PCM stereo little-endian, which is
    /// what the C harness writes. Returns interleaved [L0, R0, L1, R1, ...].
    ///
    /// Uses `subdata(in:)` to make a fresh 0-based Data, avoiding a subtle
    /// bug with `Data.copyBytes(to:)` on slices where the slice's original
    /// index range is preserved and the copy target ends up reading from the
    /// wrong offset.
    private func loadInt16StereoPCM(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)

        // WAV header is 44 bytes for canonical PCM: RIFF (12) + fmt (24) + data (8).
        guard data.count >= 44 else {
            throw NSError(domain: "WAV", code: 2, userInfo: [NSLocalizedDescriptionKey: "file too small"])
        }

        // Sanity check the RIFF/WAVE tags.
        let riff = String(bytes: data[0..<4], encoding: .ascii)
        let wave = String(bytes: data[8..<12], encoding: .ascii)
        guard riff == "RIFF", wave == "WAVE" else {
            throw NSError(domain: "WAV", code: 3, userInfo: [NSLocalizedDescriptionKey: "not a RIFF/WAVE file"])
        }

        // subdata(in:) returns a *fresh* Data whose indices start at 0, so
        // withUnsafeBytes and copyBytes behave predictably.
        let payload = data.subdata(in: 44..<data.count)
        let count = payload.count / MemoryLayout<Int16>.size

        var samples = [Int16](repeating: 0, count: count)
        samples.withUnsafeMutableBytes { dst in
            payload.withUnsafeBytes { src in
                dst.baseAddress?.copyMemory(from: src.baseAddress!, byteCount: payload.count)
            }
        }
        return samples
    }
}
