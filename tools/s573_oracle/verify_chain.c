/* verify_chain.c - descramble a real ddrsbm song with the SHIPPING descrambler
 * and decode it with the SHIPPING decoder, offline.
 *
 * This is the test the decision-B spike could not do: it proved the C
 * descrambler matches the RTL bit-for-bit, but both were checked against each
 * other, not against the game. ("the existing tb_k573_mp3dec reference model is
 * a transliteration of the RTL's own functions, so 44/44 never tested fidelity
 * to MAME.") Here the input is genuine disc data from 894jaa02.chd and the
 * output is judged by whether minimp3 decodes continuous 44.1 kHz stereo
 * frames -- an oracle neither side can fake.
 *
 * Links against support/s573/s573_descramble.c and lib/minimp3/minimp3.h --
 * the same files the ARM binary is built from, deliberately.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "s573_descramble.h"
#define MINIMP3_IMPLEMENTATION
#define MINIMP3_ONLY_MP3
#define MINIMP3_NO_STDIO
#include "minimp3.h"

int main(int argc, char **argv)
{
    const char *path = argv[1];
    uint32_t key1 = (uint32_t)strtoul(argv[2], 0, 0);
    uint32_t start = (argc > 3) ? (uint32_t)strtoul(argv[3], 0, 0) : 0x40;
    FILE *f = fopen(path, "rb");
    uint8_t *disc;
    long sz;
    s573_desc_t st;
    mp3dec_t dec;
    static uint8_t in[8192];
    static int16_t pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];
    uint32_t in_len = 0, in_pos = 0, pulled = 0;
    uint32_t frames = 0, samples_total = 0, bad = 0;
    int hz = 0, ch = 0, kbps_min = 9999, kbps_max = 0;

    if (!f) { fprintf(stderr, "open failed\n"); return 2; }
    fseek(f, 0, SEEK_END); sz = ftell(f); fseek(f, 0, SEEK_SET);
    disc = (uint8_t *)malloc(sz);
    if (fread(disc, 1, sz, f) != (size_t)sz) return 2;
    fclose(f);

    /* the window as the game would program it: from `start` to end of file,
     * rounded down to a word boundary */
    s573_desc_init(&st, start, (uint32_t)(sz & ~1u), (uint16_t)key1, 0, 0, 1 /*ddrsbm*/);
    mp3dec_init(&dec);

    for (;;) {
        mp3dec_frame_info_t info;
        int n;
        if (in_len - in_pos < 1441) {
            uint32_t keep = in_len - in_pos, got;
            memmove(in, in + in_pos, keep);
            in_len = keep; in_pos = 0;
            got = (uint32_t)s573_desc_pull(&st, disc, in + in_len, sizeof(in) - in_len);
            in_len += got; pulled += got;
            if (!got && in_len - in_pos < 4) break;
        }
        n = mp3dec_decode_frame(&dec, in + in_pos, (int)(in_len - in_pos), pcm, &info);
        if (!info.frame_bytes) break;
        in_pos += (uint32_t)info.frame_bytes;
        if (!n) { bad++; continue; }
        frames++; samples_total += (uint32_t)n;
        hz = info.hz; ch = info.channels;
        if (info.bitrate_kbps < kbps_min) kbps_min = info.bitrate_kbps;
        if (info.bitrate_kbps > kbps_max) kbps_max = info.bitrate_kbps;
    }

    printf("%-14s key1=0x%04X start=0x%X\n", path, key1, start);
    printf("  descrambled %u bytes (window %u)\n", pulled,
           s573_desc_stream_len(start, (uint32_t)(sz & ~1u)));
    printf("  decoded %u frames, %u samples/ch, %.2f s @ %d Hz %d ch, %d-%d kbps, "
           "%u skipped\n",
           frames, samples_total, hz ? (double)samples_total / hz : 0.0,
           hz, ch, kbps_min, kbps_max, bad);
    /* The right test is not "is it long" -- these clips are ~19 s -- but
     * "does the decode ACCOUNT FOR the whole window": duration x bitrate must
     * come back to the byte count we descrambled, with almost no skipped
     * frames. A wrong key cannot satisfy that; it desynchronises within a
     * frame or two. */
    {
        double secs  = hz ? (double)samples_total / hz : 0.0;
        double acct  = (kbps_max > 0) ? secs * kbps_max * 1000.0 / 8.0 : 0.0;
        double ratio = pulled ? acct / pulled : 0.0;
        printf("  decode accounts for %.1f%% of the descrambled bytes\n", ratio * 100.0);
        if (frames > 100 && hz == 44100 && ch == 2 && bad * 100 < frames
            && ratio > 0.97 && ratio < 1.03 && kbps_min == kbps_max)
            { printf("  VERDICT: PASS -- the whole window is continuous real MP3\n"); return 0; }
    }
    printf("  VERDICT: FAIL\n");
    return 1;
}
