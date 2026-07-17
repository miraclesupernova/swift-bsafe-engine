// bytebeat_harness.cpp
//
// Host-runnable harness that reproduces the exact inner loop of
// main/dsp/Bytebeat.cpp::bytebeat_next_sample() with all ESP32 / I2S /
// hardware layers stubbed out. It replays the include file
// main/bytebeat_songs.inc with the same global variables (bytebeat_song,
// bytebeat_song_ptr, bit1/bit2, var_p[]) and dumps N seconds of stereo
// output for each of the 8 songs to a 16-bit PCM WAV.
//
// Purpose: golden reference. Swift unit tests compare their output to
// these WAVs sample-by-sample to catch translation bugs in the bytebeat
// formulas (integer overflow, shift widths, truncation).
//
// Build:  clang++ -std=c++17 -O2 bytebeat_harness.cpp -o bytebeat_harness
// Run:    ./bytebeat_harness ../reference_wavs
//
// Notes on faithfulness:
//   * I2S_AUDIOFREQ is 32768 on the real device (SAMPLING_RATE_32KHZ is
//     commented out in hw/init.h). BYTEBEAT_TEMPO_CORRECTION is therefore
//     inactive.
//   * BB_SHIFT_VOLUME defaults to 3 (BB_VOLUME_DEFAULT in hw/init.h).
//   * per-song default bit1/bit2 come from patch_bit1[]/patch_bit2[] in
//     dsp/Bytebeat.cpp; var_p[] defaults to {0,0,0,0}.
//   * The device treats final samples as int16 signed PCM after shifting
//     the uint16(mix) by BB_SHIFT_VOLUME. We reproduce that path exactly
//     so the WAVs are bit-identical to what an oscilloscope would see
//     on the DAC output.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

// ---- Globals referenced by bytebeat_songs.inc -------------------------------
// Types are chosen to match dsp/Bytebeat.cpp / dsp/Bytebeat.h exactly.

static int8_t        bytebeat_song = 0;
static int           bytebeat_song_ptr = 0;
static uint8_t       bit1 = 4;
static uint8_t       bit2 = 2;
static unsigned char var_p[4] = {0, 0, 0, 0};

// Per-song defaults from dsp/Bytebeat.cpp
static const uint8_t default_bit1[8] = {4, 4, 4, 3, 4, 2, 4, 4};
static const uint8_t default_bit2[8] = {2, 2, 2, 2, 2, 2, 2, 2};

// ---- Constants matching the device -----------------------------------------

static constexpr int      SAMPLE_RATE       = 32768;   // I2S_AUDIOFREQ (32kHz sampling disabled -> 32768)
static constexpr int      BB_SHIFT_VOLUME   = 3;       // BB_VOLUME_DEFAULT
static constexpr int      SECONDS_PER_SONG  = 5;
static constexpr int      SAMPLES_PER_SONG  = SAMPLE_RATE * SECONDS_PER_SONG;

// ---- WAV writer -------------------------------------------------------------

struct WavHeader {
    char     riff[4]     = {'R','I','F','F'};
    uint32_t chunkSize   = 0;
    char     wave[4]     = {'W','A','V','E'};
    char     fmt_[4]     = {'f','m','t',' '};
    uint32_t subchunk1   = 16;
    uint16_t audioFormat = 1;   // PCM
    uint16_t channels    = 2;   // stereo
    uint32_t sampleRate  = SAMPLE_RATE;
    uint32_t byteRate    = SAMPLE_RATE * 2 * 2;
    uint16_t blockAlign  = 4;
    uint16_t bitsPerSample = 16;
    char     data[4]     = {'d','a','t','a'};
    uint32_t dataSize    = 0;
};

static void write_wav(const std::string& path, const std::vector<int16_t>& interleaved)
{
    WavHeader h;
    h.dataSize = (uint32_t)(interleaved.size() * sizeof(int16_t));
    h.chunkSize = 36 + h.dataSize;

    FILE* f = fopen(path.c_str(), "wb");
    if (!f) {
        fprintf(stderr, "Failed to open %s for writing\n", path.c_str());
        exit(1);
    }
    fwrite(&h, sizeof(h), 1, f);
    fwrite(interleaved.data(), sizeof(int16_t), interleaved.size(), f);
    fclose(f);
}

// ---- Inner loop reproducer --------------------------------------------------
//
// This function is a stripped-down copy of bytebeat_next_sample() from
// dsp/Bytebeat.cpp with all hardware-touching code removed:
//   - no sensor / light-sensor modulation of song_start/length
//   - no arpeggiator / sequencer (they only rewrite `patch`, not the math)
//   - no sine-wave / flash-sample layers (layers_active = 0x01)
//   - no echo (bytebeat_echo_on = 0)
//   - no tempo correction (I2S_AUDIOFREQ = 32768 so it is inactive)
//
// The output path down to the int16 stereo sample is preserved bit-for-bit.

static void render_song(int song_index, std::vector<int16_t>& outStereo)
{
    bytebeat_song      = (int8_t)song_index;
    bytebeat_song_ptr  = 0;
    bit1               = default_bit1[song_index];
    bit2               = default_bit2[song_index];
    var_p[0] = var_p[1] = var_p[2] = var_p[3] = 0;

    outStereo.resize(SAMPLES_PER_SONG * 2);

    for (int i = 0; i < SAMPLES_PER_SONG; ++i) {
        bytebeat_song_ptr++;

        // Locals used by bytebeat_songs.inc
        int           tt[4] = {0, 0, 0, 0};
        unsigned char s[4]  = {0, 0, 0, 0};
        float         mix1 = 0.0f;
        float         mix2 = 0.0f;

        #include "../../../main/bytebeat_songs.inc"


        // ---- Output path (copy of the tail of bytebeat_next_sample) ---------
        uint16_t sample1 = 0;
        uint16_t sample2 = 0;
        // layers_active & 0x01 is true (bytebeat layer on)
        sample1 = (uint16_t)mix1;
        sample2 = (uint16_t)mix2;

        // The device packs into a uint32 for I2S; on the wire each half is
        // interpreted as int16 signed PCM by the DAC. We reproduce that:
        uint16_t left_u  = (uint16_t)((sample1 << BB_SHIFT_VOLUME) & 0x0000ffff);
        uint16_t right_u = (uint16_t)((sample2 << BB_SHIFT_VOLUME) & 0x0000ffff);

        outStereo[i * 2 + 0] = (int16_t)left_u;
        outStereo[i * 2 + 1] = (int16_t)right_u;
    }
}

// ---- main -------------------------------------------------------------------

int main(int argc, char** argv)
{
    std::string outDir = (argc > 1) ? argv[1] : "../reference_wavs";

    printf("bytebeat_harness: writing 8 reference WAVs to %s/\n", outDir.c_str());
    printf("  sample rate  : %d Hz (device I2S_AUDIOFREQ)\n", SAMPLE_RATE);
    printf("  duration     : %d seconds per song\n", SECONDS_PER_SONG);
    printf("  volume shift : %d (BB_VOLUME_DEFAULT)\n", BB_SHIFT_VOLUME);
    printf("  var_p[]      : {0, 0, 0, 0}\n");

    std::vector<int16_t> stereo;
    for (int song = 0; song < 8; ++song) {
        printf("  song %d: bit1=%d bit2=%d -> ", song, default_bit1[song], default_bit2[song]);
        render_song(song, stereo);

        char path[512];
        snprintf(path, sizeof(path), "%s/song%d.wav", outDir.c_str(), song);
        write_wav(path, stereo);
        printf("%s (%zu samples)\n", path, stereo.size() / 2);
    }

    printf("done.\n");
    return 0;
}
