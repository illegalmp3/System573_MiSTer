/* sim_loader.c - host reproduction of the ddr3mj "preview plays half a second
 * then dies" failure (2026-09-29), and the regression run for its fix.
 *
 * The REAL core + descrambler + minimp3, driven by a simulated 3rd Mix loader
 * (six sectors land at DRAM 0, the window is armed, then one 2 KB sector every
 * 1/24 s) and a simulated fabric drain (22050 beats/s once DRAIN_EN). The decode
 * loop is s573mp3.cpp's decode_some(), kept in step by hand. Needs minimp3.h
 * and a 44.1 kHz MP3 (ffmpeg -f lavfi -i sine=... -b:a 128k song.mp3):
 *
 *   make loader MINIMP3_PATH=/path/minimp3.h MP3=song.mp3
 *
 * Arguments: <mp3> [fresh_wp_at_rearm 0|1]; env START=<dram offset>,
 * JUNK=old (the previous preview's bytes instead of the BIOS fill), PRELOAD=1
 * (a ddrextrm-style title: whole window present, pointer parked at STALEWP).
 * Exit status is nonzero when fewer than 99% of the reference samples decode.
 * With the 2026-09-29 core (kept-tail rewind, held-byte watermark hole, torn
 * frames handed to minimp3) this decoded 4.2% and rewound 200 times a second. */
#include <stdint.h>
#include <stddef.h>
#define MINIMP3_IMPLEMENTATION
#include MINIMP3_PATH
#include "../s573mp3_core.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define S573_MAX_FRAME_BYTES 1441
#define S573_DECODE_MIN (S573_MAX_FRAME_BYTES + 4)
#define SECTOR 2048u

static s573_core_t core;
static mp3dec_t mp3d;
static uint8_t *dio_map;              /* the DRAM image */
static uint32_t dio_size = 0x800000;  /* 1 MiB is plenty */
static int opt_frames = 12;
static uint64_t sim_us = 0;
static uint64_t now_us(void) { return sim_us; }

/* --- scrambler: exact inverse of s573_desc_step (ddrsbm = 0) --------------- */
static uint16_t derive_key(uint16_t s) {
    uint16_t r = (uint16_t)(s & 0x9E79u);
    r |= (uint16_t)((s & 0x2000u) << 1); r |= (uint16_t)((s & 0x4000u) >> 1);
    r |= (uint16_t)((s & 0x0080u) << 1); r |= (uint16_t)((s & 0x0100u) >> 1);
    r |= (uint16_t)((s & 0x0002u) << 1); r |= (uint16_t)((s & 0x0004u) >> 1);
    return r;
}
static uint16_t key3_spread(uint16_t k) {
    uint16_t r = 0;
    r |= (uint16_t)(((k >> 7) & 1u) << 15) | (uint16_t)(((k >> 7) & 1u) <<  0);
    r |= (uint16_t)(((k >> 0) & 1u) << 14) | (uint16_t)(((k >> 0) & 1u) <<  1);
    r |= (uint16_t)(((k >> 6) & 1u) << 13) | (uint16_t)(((k >> 6) & 1u) <<  2);
    r |= (uint16_t)(((k >> 1) & 1u) << 12) | (uint16_t)(((k >> 1) & 1u) <<  3);
    r |= (uint16_t)(((k >> 5) & 1u) << 11) | (uint16_t)(((k >> 5) & 1u) <<  4);
    r |= (uint16_t)(((k >> 2) & 1u) << 10) | (uint16_t)(((k >> 2) & 1u) <<  5);
    r |= (uint16_t)(((k >> 4) & 1u) <<  9) | (uint16_t)(((k >> 4) & 1u) <<  6);
    r |= (uint16_t)(((k >> 3) & 1u) <<  8) | (uint16_t)(((k >> 3) & 1u) <<  7);
    return r;
}
static uint16_t enc_common(uint16_t v, uint16_t key) {   /* inverse of dec_common */
    uint16_t d = (uint16_t)(v ^ (key & 0x5555u));
    const uint16_t swapped = (uint16_t)(((d & 0x5555u) << 1) | ((d >> 1) & 0x5555u));
    const uint16_t odd = (uint16_t)(key & 0xAAAAu);
    const uint16_t pair = (uint16_t)(odd | (odd >> 1));
    return (uint16_t)((swapped & pair) | (d & (uint16_t)~pair));
}
/* scramble `plain` (len bytes) into dst as the game lays it out: word-wise, high
 * byte first in the stream; the LAST stream byte rides in the high byte of the
 * final word (the 2N-1 rule), so the window is 2*words with end = start+len. */
static uint32_t scramble(const uint8_t *plain, uint32_t len, uint8_t *dst,
                         uint16_t k1, uint16_t k2, uint16_t k3)
{
    uint32_t i, words = (len + 1u) / 2u;
    for (i = 0; i < words; i++) {
        uint16_t v = (uint16_t)((uint16_t)plain[2*i] << 8);
        if (2*i + 1 < len) v |= plain[2*i + 1];
        uint16_t dk = derive_key((uint16_t)(k1 ^ k2));
        uint16_t src = enc_common((uint16_t)(v ^ key3_spread(k3)), dk);
        dst[2*i] = (uint8_t)(src & 0xff); dst[2*i + 1] = (uint8_t)(src >> 8);
        if (((k1 >> 14) ^ (k1 >> 15)) & 1u) k2 = (uint16_t)((k2 << 1) | (k2 >> 15));
        k1 = (uint16_t)((k1 & 0x8000u) | ((k1 & 0x3FFFu) << 1) | ((k1 >> 14) & 1u));
        k3 = (uint16_t)(k3 + 1u);
    }
    return words * 2u;
}

/* --- the service pieces, copied from s573mp3.cpp ------------------------- */
static uint32_t stalls_reported = 0;
static void report_decode_stall(const char *why)
{
    static uint16_t reported_epoch = 0xFFFF;
    stalls_reported++;
    if (reported_epoch == core.cfg_epoch) return;
    reported_epoch = core.cfg_epoch;
    printf("  [%7.3f s] decode STALL (%s) at cur=%08x (%u of %u) played=%u pulled=%u\n",
           sim_us / 1e6, why, core.desc.cur, core.desc.cur - core.desc.mp3_start,
           core.desc.mp3_end - core.desc.mp3_start, core.cons_bytes, core.pulled_bytes);
}
static void pcm_write(const int16_t *src, uint32_t beats) { (void)src; s573_core_wrote_pcm(&core, beats); }
static void push_frame(const int16_t *pcm, int samples, int channels, uint32_t in_bytes)
{
    uint32_t beats = (uint32_t)samples / S573_BEAT_SAMPLES;
    (void)channels;
    if (!beats) { s573_core_carry_bytes(&core, in_bytes); return; }
    pcm_write(pcm, beats);
    s573_core_queue_frame(&core, beats, in_bytes);
    core.frames++;
}
static uint32_t total_samples = 0;
static void decode_some(void)
{
    int budget = opt_frames;
    static int16_t pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];
    while (budget-- > 0 && s573_core_may_decode(&core)) {
        mp3dec_frame_info_t info;
        int samples;
        uint32_t avail;
        avail = core.in_len - core.in_pos;
        if (avail < S573_DECODE_MIN) {
            s573_core_refill(&core, (const uint8_t *)dio_map);
            avail = core.in_len - core.in_pos;
            if (avail < S573_DECODE_MIN && !s573_core_window_exhausted(&core)) {
                if (!avail) report_decode_stall("input starved, waiting");
                break;
            }
            if (!avail) { core.frame_idle_cnt++; break; }
        }
        info.frame_offset = -1;
        { static mp3dec_t saved; saved = mp3d;
        samples = mp3dec_decode_frame(&mp3d, core.in_buf + core.in_pos, (int)avail, pcm, &info);
        if (info.frame_offset < 0) mp3d = saved; }
        if (info.frame_offset < 0) {
            if (s573_core_no_frame(&core, (const uint8_t *)dio_map)) {
                report_decode_stall("truncated tail at the window end");
                core.frame_idle_cnt++;
            } else {
                report_decode_stall("bytes not loaded yet -- rewinding the pull");
            }
            break;
        }
        { uint32_t off = core.pulled_bytes - (core.in_len - core.in_pos);
          if (getenv("TRACE")) printf("    t=%llu frame at stream %u (+%d junk) bytes=%d samples=%d\n", (unsigned long long)sim_us, off, info.frame_offset, info.frame_bytes, samples); }
        core.in_pos += (uint32_t)info.frame_bytes;
        if (!samples) { s573_core_carry_bytes(&core, (uint32_t)info.frame_bytes); continue; }
        total_samples += (uint32_t)samples;
        push_frame(pcm, samples, info.channels, (uint32_t)info.frame_bytes);
    }
}

/* --- the simulation --------------------------------------------------------- */
int main(int argc, char **argv)
{
    const char *mp3path = argc > 1 ? argv[1] : "song.mp3";
    int fresh_wp_at_rearm = argc > 2 ? atoi(argv[2]) : 0;   /* the candidate fix */
    uint32_t prefill = 6u * SECTOR;
    uint16_t k1 = 0xe81f, k2 = 0xbdd7, k3 = 0x001c;
    uint32_t start = getenv("START") ? (uint32_t)strtoul(getenv("START"), 0, 0) : 0;
    int junk_old = getenv("JUNK") && !strcmp(getenv("JUNK"), "old");
    int preload  = getenv("PRELOAD") != 0;
    uint32_t stale_env = getenv("STALEWP") ? (uint32_t)strtoul(getenv("STALEWP"), 0, 0) : 0x7044cc;
    FILE *f = fopen(mp3path, "rb");
    if (!f) { perror(mp3path); return 2; }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *plain = malloc(len); fread(plain, 1, len, f); fclose(f);
    uint8_t *scr = calloc(1, len + 2);
    uint32_t scr_len = scramble(plain, (uint32_t)len, scr, k1, k2, k3);
    dio_map = malloc(dio_size);
    /* the DRAM before the game touches it: the BIOS fill (incrementing words),
     * or the PREVIOUS preview's scrambled data (other keys) */
    for (uint32_t i = 0; i < dio_size; i += 2) { dio_map[i] = (uint8_t)(i >> 1); dio_map[i+1] = (uint8_t)(i >> 9); }
    if (junk_old) { uint8_t *o = calloc(1, len + 2); scramble(plain, (uint32_t)len, o, 0x1e99, 0x38cb, 0x00d9); memcpy(dio_map + start, o, scr_len); free(o); }

    /* self-check: descramble the whole thing back */
    { s573_desc_t d; s573_desc_init(&d, 0, (uint32_t)len, k1, k2, k3, 0);
      uint8_t *back = malloc(len + 16); size_t n = s573_desc_pull(&d, scr, back, len + 16);
      if (n != (size_t)len || memcmp(back, plain, len)) { printf("scrambler round trip FAILED (n=%zu)\n", n); return 3; }
      free(back); }

    s573_core_init(&core);
    mp3dec_init(&mp3d);
    core.ptrs_thawed = 1;

    /* the reference: how many samples the plain stream decodes to */
    uint32_t ref_samples = 0;
    { mp3dec_t d; mp3dec_init(&d); mp3dec_frame_info_t info; static int16_t pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];
      long pos = 0; while (pos < len) { int s = mp3dec_decode_frame(&d, plain + pos, (int)(len - pos), pcm, &info);
        if (!info.frame_bytes) break; pos += info.frame_bytes; ref_samples += s; } }

    /* --- the game: 6 sectors land at DRAM 0, then the window is armed --- */
    uint32_t loaded = preload ? scr_len : prefill;
    memcpy(dio_map + start, scr, loaded);
    uint32_t hw_wp = preload ? stale_env : start + loaded;   /* a preload title: the pointer rests wherever it parked */
    uint32_t stale_wp = stale_env;         /* what the service still holds from the attract load */

    /* service state before the CFG: the pointer as last refreshed (up to 20 ms ago) */
    s573_core_set_write_ptr(&core, stale_wp, 1, (uint32_t)now_us());

    s573_cfg_t cfg; memset(&cfg, 0, sizeof cfg);
    cfg.mp3_start = start; cfg.mp3_end = start + (uint32_t)len; cfg.key1 = k1; cfg.key2 = k2; cfg.key3 = k3;
    cfg.flags = S573_CFG_CTRL13 | S573_CFG_CTRL14 | S573_CFG_CTRL15;
    int act = s573_core_apply_cfg(&core, &cfg, 35, 0);
    if (act & S573_ACT_FLUSH) { s573_core_ring_collapse(&core, 1); mp3dec_init(&mp3d); }
    if (fresh_wp_at_rearm) s573_core_set_write_ptr(&core, hw_wp, 1, (uint32_t)now_us());

    /* --- the loop: 5 ms polls, 20 ms pointer refresh, loader at 24 sectors/s,
     *     drain at 22050 beats/s once DRAIN_EN --- */
    uint16_t fab_rd = core.pcm_rd;
    double drain_acc = 0;
    uint64_t next_sector = 1000000ull / 24ull, next_wp = 20000, end_us = 20000000ull;
    uint32_t last_rewinds = 0, last_frames = 0;
    for (sim_us = 5000; sim_us < end_us; sim_us += 5000) {
        while (sim_us >= next_sector && loaded < scr_len) {
            uint32_t n = scr_len - loaded < SECTOR ? scr_len - loaded : SECTOR;
            memcpy(dio_map + start + loaded, scr + loaded, n); loaded += n; hw_wp = start + loaded; next_sector += 1000000ull / 24ull;
        }
        /* fabric drain for 5 ms */
        if (core.ctrl_flags & S573_CTRL_DRAIN_EN) {
            drain_acc += 22050.0 * 0.005;
            uint32_t want = (uint32_t)drain_acc; drain_acc -= want;
            uint32_t used = (uint32_t)((uint16_t)(core.pcm_wr - fab_rd) & S573_PCM_PTR_MASK);
            if (want > used) want = used;                 /* underrun: the reader waits */
            fab_rd = (uint16_t)((fab_rd + want) & S573_PCM_PTR_MASK);
        }
        core.pcm_rd = fab_rd;
        s573_core_advance_played(&core, fab_rd);
        if (sim_us >= next_wp) { next_wp += 20000; s573_core_set_write_ptr(&core, hw_wp, 1, (uint32_t)now_us()); }
        if (core.have_cfg && (core.ctrl_flags & S573_CTRL_DRAIN_EN)) decode_some();
        if (s573_core_should_stop(&core)) { core.ctrl_flags &= ~S573_CTRL_DRAIN_EN; s573_core_song_end(&core);
            printf("  [%7.3f s] song end, cur=%08x\n", sim_us / 1e6, core.desc.cur); break; }
        if (sim_us % 1000000ull == 0) {
            printf("  [%7.3f s] wp=%06x lim=%06x cur=%06x in=%u/%u cons=%u pulled=%u lead=%d ring=%u q=%u rewinds=+%u frames=+%u holds=%u lifted=%u\n",
                   sim_us / 1e6, core.wp, s573_core_loaded_limit(&core), core.desc.cur, core.in_pos, core.in_len,
                   core.cons_bytes, core.pulled_bytes, (int)(core.pulled_bytes - core.cons_bytes),
                   s573_core_pcm_used(&core), (unsigned)((uint8_t)(core.pq_tail - core.pq_head) % S573_PQ_LEN),
                   core.rewinds - last_rewinds, core.frames - last_frames, core.wp_holds, core.wp_lifted);
            last_rewinds = core.rewinds; last_frames = core.frames;
        }
    }
    printf("RESULT: samples decoded %u of %u (%.1f%%), frames=%u rewinds=%u stalls=%u\n",
           total_samples, ref_samples, 100.0 * total_samples / ref_samples, core.frames, core.rewinds, stalls_reported);
    return total_samples * 100 < ref_samples * 99;
}
