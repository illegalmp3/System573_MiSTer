/* -----------------------------------------------------------------------------
 * test_s573mp3_core.c - host tests for the 573 HPS MP3 service core.
 *
 * Runs on any host (no /dev/mem, no SPI, no minimp3). Every group that guards a
 * known defect has a matching mutation define that restores the bug; the suite
 * MUST go RED under each one, or it is not testing anything:
 *
 *   make mutate        # runs all three and reports PASS only if all go RED
 *
 * Released under the GNU GPL v2.
 * ---------------------------------------------------------------------------- */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "../s573mp3_core.h"

static int fails = 0, groups = 0;
#define GROUP(n) do { groups++; printf("-- T%-2d %s\n", groups, n); } while (0)
#define CHECK(cond, msg) do { if (!(cond)) { \
        printf("   FAIL: %s  (%s:%d)\n", msg, __FILE__, __LINE__); fails++; } } while (0)
#define CHECKEQ(got, want, msg) do { unsigned long g=(unsigned long)(got), \
        w=(unsigned long)(want); if (g != w) { \
        printf("   FAIL: %s  got %lu (0x%lx) want %lu (0x%lx)  (%s:%d)\n", \
        msg, g, g, w, w, __FILE__, __LINE__); fails++; } } while (0)

static void mkcfg(s573_cfg_t *f, uint32_t start, uint32_t end,
                  uint16_t k1, uint16_t k2, uint16_t k3, uint16_t flags,
                  uint16_t epoch)
{
    memset(f, 0, sizeof(*f));
    f->epoch8 = (uint16_t)(epoch & 0xFF);
    f->mp3_start = start; f->mp3_end = end;
    f->key1 = k1; f->key2 = k2; f->key3 = k3;
    f->flags = flags;
    f->gain_ll = 0x8000; f->gain_rr = 0x8000; f->gain_seen = 1;
}

#define FLAGS_PLAY  (S573_CFG_DDRSBM | S573_CFG_CTRL13 | S573_CFG_CTRL14 | S573_CFG_CTRL15)
#define FLAGS_STOP  (S573_CFG_DDRSBM | S573_CFG_CTRL13 | S573_CFG_CTRL15)  /* 000b */
#define FLAGS_IDLE  (S573_CFG_DDRSBM)                                       /* 0001 */

int main(void)
{
    s573_core_t c;
    s573_cfg_t  f;
    int act;

    /* ------------------------------------------------------------------ */
    GROUP("init leaves the writer parked and no config adopted");
    s573_core_init(&c);
    CHECKEQ(c.pcm_wr, 0, "pcm_wr");
    CHECKEQ(c.have_cfg, 0, "have_cfg");
    CHECKEQ(c.ctrl_flags, 0, "ctrl_flags");
    CHECK(!s573_core_may_decode(&c) == 0, "an empty ring may decode");

    /* ------------------------------------------------------------------ */
    GROUP("core-reset epoch: first sighting acks and demands a flush");
    s573_core_init(&c);
    c.pcm_wr = 0x9ABC; c.have_cfg = 1; c.cons_bytes = 12345;
    CHECKEQ(s573_core_on_core_reset(&c, 1), 1, "first reset returns flush");
    CHECKEQ(c.rst_ack, 1, "rst_ack adopted");
    CHECKEQ(c.pcm_wr, 0, "writer rebaselined to 0");
    CHECKEQ(c.cons_bytes, 0, "credit rebaselined");
    CHECKEQ(c.have_cfg, 0, "config forgotten");
    CHECKEQ(s573_core_on_core_reset(&c, 1), 0, "same epoch is idempotent");
    CHECKEQ(s573_core_on_core_reset(&c, 2), 1, "a new epoch re-fires");

    /* ------------------------------------------------------------------ */
    GROUP("CTRL baselines are adopted so the first delta is zero");
    s573_core_init(&c);
    s573_core_adopt_ctrl_baseline(&c, 0x7A35);
    CHECKEQ(c.frame_sync_cnt, 0x7A, "sync baseline");
    CHECKEQ(c.frame_idle_cnt, 0x35, "idle baseline");
    CHECKEQ(s573_core_ctrl_word1(&c), 0x7A35, "echo == baseline -> delta 0");
    CHECKEQ(c.ctrl_primed, 1, "primed");

    /* ------------------------------------------------------------------ */
    GROUP("cfg_epoch is adopted as 16 bits (bug 2 regression)");
    s573_core_init(&c);
    mkcfg(&f, 0x1000, 0x2000, 1, 2, 3, FLAGS_PLAY, 300);
    (void)s573_core_apply_cfg(&c, &f, 300, 0);
    CHECKEQ(c.cfg_epoch, 300, "16-bit epoch adopted, not the 8-bit echo");
    CHECKEQ(c.torn_cfg, 0, "low byte agrees -> not torn");
    /* the shape of the bug: had we adopted f.epoch8 (=44) the comparison
     * r.cfg_epoch(300) != c->cfg_epoch(44) would re-fire on every poll forever */
    CHECK(c.cfg_epoch != (uint16_t)f.epoch8, "adopted value must not be the echo");
    /* re-reading the same epoch must be a no-op decision for the caller */
    CHECKEQ(c.cfg_epoch == 300, 1, "stable across polls");

    /* ------------------------------------------------------------------ */
    GROUP("a genuinely torn MP3CFG read is counted, not swallowed");
    s573_core_init(&c);
    mkcfg(&f, 0x1000, 0x2000, 1, 2, 3, FLAGS_PLAY, 300);
    f.epoch8 = 0x2B;                     /* != 300 & 0xFF (0x2C) */
    (void)s573_core_apply_cfg(&c, &f, 300, 0);
    CHECKEQ(c.torn_cfg, 1, "torn read flagged");

    /* ------------------------------------------------------------------ */
    GROUP("ring pointers compare FULL WIDTH: one lap ahead is FULL, not empty");
    s573_core_init(&c);
    c.pcm_rd = 0x0000; c.pcm_wr = (uint16_t)S573_PCM_BEATS;   /* exactly one lap */
    CHECKEQ(s573_core_pcm_used(&c), S573_PCM_BEATS, "used == whole ring");
    CHECKEQ(s573_core_pcm_free(&c), 0, "free == 0 (FULL)");
    CHECK(!s573_core_pcm_empty(&c), "must NOT read empty");
    CHECK(!s573_core_may_decode(&c), "must not decode into a full ring");
    /* and the ordinary cases still work */
    c.pcm_rd = 0x7FF0; c.pcm_wr = 0x8010;
    CHECKEQ(s573_core_pcm_used(&c), 0x20, "used across the wrap boundary");
    c.pcm_rd = 0xFFF0; c.pcm_wr = 0x0010;   /* pointer wrap at 2^16 */
    CHECKEQ(s573_core_pcm_used(&c), 0x20, "used across the 16-bit wrap");

    /* ------------------------------------------------------------------ */
    GROUP("wrote_pcm keeps the wrap MSB across a lap (bug 3 regression)");
    s573_core_init(&c);
    c.pcm_wr = (uint16_t)(S573_PCM_BEATS - 4);
    s573_core_wrote_pcm(&c, 8);
    CHECKEQ(c.pcm_wr, S573_PCM_BEATS + 4, "crossing the lap sets bit 15");
    CHECK(c.pcm_wr > S573_PCM_IDX_MASK, "pointer must exceed 15 bits");
    /* a full lap of writes returns to the same index with the MSB toggled */
    s573_core_init(&c);
    s573_core_wrote_pcm(&c, S573_PCM_BEATS);
    CHECKEQ(c.pcm_wr, S573_PCM_BEATS, "one lap == 0x8000, not 0");

    /* ------------------------------------------------------------------ */
    GROUP("byte_off is the only place the MSB is masked; no underflow");
    {
        uint32_t p, off, worst = 0;
        for (p = 0; p <= S573_PCM_PTR_MASK; p += 997) {
            off = s573_core_pcm_byte_off((uint16_t)p);
            CHECK(off < S573_PCM_BYTES, "offset inside the mapping");
            if (S573_PCM_BYTES - off > worst) worst = S573_PCM_BYTES - off;
        }
        CHECKEQ(s573_core_pcm_byte_off((uint16_t)(S573_PCM_BEATS + 3)), 24,
                "lapped pointer maps to the same offset as its index");
        CHECKEQ(worst, S573_PCM_BYTES, "BYTES - off never underflows");
    }

    /* ------------------------------------------------------------------ */
    GROUP("ring collapse parks one beat ahead and survives a mid-read advance");
    s573_core_init(&c);
    c.pcm_rd = 0x1234; c.pcm_wr = (uint16_t)(0x1234 + 30000);
    {
        uint32_t dropped = s573_core_ring_collapse(&c, 1);
        CHECKEQ(dropped, 30000, "dropped == what was queued");
        CHECKEQ(c.pcm_wr, 0x1235, "parked one beat ahead of the fabric");
        CHECKEQ(c.flushes, 1, "flush counted");
        /* the reason for +1: if the reader completes the beat it had already
         * committed to, it advances once more -- and we must land on EMPTY, not
         * on 0xFFFF beats of replay */
        c.pcm_rd = 0x1235;
        CHECKEQ(s573_core_pcm_used(&c), 0, "empty after the reader's last beat");
        CHECK(s573_core_pcm_empty(&c), "reads empty");
    }

    /* ------------------------------------------------------------------ */
    GROUP("flush fires on a re-arm, defers while draining, ignores enable-only");
    s573_core_init(&c);
    mkcfg(&f, 0x1000, 0x2000, 1, 2, 3, FLAGS_PLAY, 1);
    act = s573_core_apply_cfg(&c, &f, 1, 0);
    CHECK(act & S573_ACT_FLUSH, "first adoption flushes (drain was off)");
    CHECK(act & S573_ACT_DRAIN_ON, "drain armed from the enables");
    /* same window, same keys, only the enables move -> NOT a re-arm */
    mkcfg(&f, 0x1000, 0x2000, 1, 2, 3, FLAGS_STOP, 2);
    act = s573_core_apply_cfg(&c, &f, 2, 1);
    CHECK(!(act & (S573_ACT_FLUSH | S573_ACT_FLUSH_DEFER)),
          "a bare stop must NOT drop buffered PCM");
    CHECK(act & S573_ACT_DRAIN_OFF, "drain disarmed by the enables");
    /* new window while the drain was OFF -> flush now */
    mkcfg(&f, 0x3000, 0x4000, 1, 2, 3, FLAGS_PLAY, 3);
    act = s573_core_apply_cfg(&c, &f, 3, 0);
    CHECK(act & S573_ACT_FLUSH, "new window with the drain off -> flush");
    /* new window while the drain was ON -> defer, loudly */
    mkcfg(&f, 0x5000, 0x6000, 9, 9, 9, FLAGS_PLAY, 4);
    act = s573_core_apply_cfg(&c, &f, 4, 1);
    CHECK(act & S573_ACT_FLUSH_DEFER, "new window mid-drain -> flagged live");
    CHECK(act & S573_ACT_FLUSH, "and STILL flushed -- deferring left the old tail playing");

    /* ------------------------------------------------------------------ */
    GROUP("a re-arm rebaselines the input window and the credit");
    s573_core_init(&c);
    mkcfg(&f, 0x1000, 0x2000, 1, 2, 3, FLAGS_PLAY, 1);
    (void)s573_core_apply_cfg(&c, &f, 1, 0);
    c.in_len = 900; c.in_pos = 400; c.cons_bytes = 77777;
    {
        uint16_t last_sent = s573_core_cons_word(&c);
        mkcfg(&f, 0x9000, 0xA000, 4, 5, 6, FLAGS_PLAY, 2);
        (void)s573_core_apply_cfg(&c, &f, 2, 0);
        CHECKEQ(c.in_len, 0, "input window dropped");
        CHECKEQ(c.in_pos, 0, "input cursor reset");
        CHECKEQ(c.cons_bytes, 0, "credit restarted (fabric rebaselines in step)");
        CHECKEQ(s573_core_cons_word(&c), (uint16_t)(last_sent + 1), "first report = last sent + 1, so the fabric adopts it");
    }
    {   /* the case that broke previews 2 and 3: re-arm again with nothing played */
        uint16_t before = s573_core_cons_word(&c);
        mkcfg(&f, 0x9000, 0xA000, 4, 5, 6, FLAGS_PLAY, 9);
        (void)s573_core_apply_cfg(&c, &f, 9, 0);
        CHECK(s573_core_cons_word(&c) != before, "a re-arm with a zero count still changes the word");
        CHECKEQ((uint16_t)(s573_core_cons_word(&c) - before), 1, "by exactly one");
        c.cons_bytes = 418;
        CHECKEQ((uint16_t)(s573_core_cons_word(&c) - before), 419, "and real bytes ride on top of it");
    }
    CHECKEQ(c.desc.cur, 0x9000, "descrambler re-armed to the new window");

    /* ------------------------------------------------------------------ */
    GROUP("may_decode is a free-space test and nothing else");
    s573_core_init(&c);
    c.pcm_rd = 0; c.pcm_wr = (uint16_t)(S573_PCM_BEATS - S573_FRAME_BEATS);
    CHECK(s573_core_may_decode(&c), "exactly one frame of room -> yes");
    c.pcm_wr = (uint16_t)(S573_PCM_BEATS - S573_FRAME_BEATS + 1);
    CHECK(!s573_core_may_decode(&c), "one beat short -> no");

    /* ------------------------------------------------------------------ */
    GROUP("refill descrambles, compacts, and accumulates the credit");
    {
        uint8_t *dio = (uint8_t *)malloc(0x20000);
        uint32_t got, i;
        CHECK(dio != NULL, "alloc");
        for (i = 0; i < 0x20000; i++) dio[i] = (uint8_t)(i * 7 + (i >> 8));
        s573_core_init(&c);
        mkcfg(&f, 0x1000, 0x4000, 0x1234, 0x5678, 0x9abc, FLAGS_PLAY, 1);
        (void)s573_core_apply_cfg(&c, &f, 1, 0);
        got = s573_core_refill(&c, dio);
        CHECKEQ(got, S573_IN_BUF, "filled the input buffer");
        CHECKEQ(c.in_len, S573_IN_BUF, "in_len");
        CHECKEQ(c.cons_bytes, 0, "pulling does NOT credit -- the drain does");
        /* consume some, refill, and confirm the unconsumed tail is preserved */
        {
            uint8_t tail[64];
            c.in_pos = S573_IN_BUF - 64;
            memcpy(tail, c.in_buf + c.in_pos, 64);
            got = s573_core_refill(&c, dio);
            CHECKEQ(memcmp(c.in_buf, tail, 64), 0, "unconsumed tail compacted forward");
            CHECKEQ(c.in_pos, 0, "cursor rebased");
            CHECKEQ(c.in_len, 64 + got, "length accounts for both halves");
            CHECKEQ(c.cons_bytes, 0, "still no credit without a drain");
        }
        /* an out-of-range cursor must clamp, not wrap into a 4 GiB memmove */
        c.in_pos = c.in_len + 1000;
        (void)s573_core_refill(&c, dio);
        CHECK(c.in_pos <= c.in_len, "cursor clamped");
        /* the same window pulled in one shot must equal the chunked pull --
         * the spike's resumability property, re-checked in place */
        {
            s573_desc_t a, b;
            uint8_t *ba = (uint8_t *)malloc(4096), *bb = (uint8_t *)malloc(4096);
            size_t na = 0, nb = 0, n;
            s573_desc_init(&a, 0x1000, 0x1800, 0x1234, 0x5678, 0x9abc, 1);
            s573_desc_init(&b, 0x1000, 0x1800, 0x1234, 0x5678, 0x9abc, 1);
            na = s573_desc_pull(&a, dio, ba, 4096);
            while (nb < na) { n = s573_desc_pull(&b, dio, bb + nb, 7); if (!n) break; nb += n; }
            CHECKEQ(nb, na, "chunked pull yields the same length");
            CHECKEQ(memcmp(ba, bb, na), 0, "chunked pull yields the same bytes");
            CHECKEQ(na, s573_desc_stream_len(0x1000, 0x1800), "2N-1 stream length");
            free(ba); free(bb);
        }
        free(dio);
    }

    /* ------------------------------------------------------------------ */
    GROUP("should_stop needs exhaustion AND a drained tail");
    s573_core_init(&c);
    mkcfg(&f, 0x1000, 0x1100, 1, 2, 3, FLAGS_PLAY, 1);
    (void)s573_core_apply_cfg(&c, &f, 1, 0);
    CHECK(!s573_core_should_stop(&c), "fresh window does not stop");
    c.desc.cur = 0x1100;                       /* window spent */
    c.in_len = 10; c.in_pos = 0;               /* undecoded residue */
    CHECK(!s573_core_should_stop(&c), "residue in the input buffer holds the stop");
    c.in_pos = 10;
    c.pcm_wr = 5; c.pcm_rd = 0;                /* PCM still queued */
    CHECK(!s573_core_should_stop(&c), "queued PCM holds the stop (tail plays out)");
    c.pcm_rd = 5;
    CHECK(s573_core_should_stop(&c), "exhausted + drained -> stop");
    c.ctrl_flags = 0;
    CHECK(!s573_core_should_stop(&c), "already stopped -> no repeat");

    /* ------------------------------------------------------------------ */
    GROUP("pulling a whole window really does reach exhaustion");
    {
        /* The end-of-song signal depends entirely on this: if cur never lands on
         * mp3_end, s573_core_should_stop() can never fire and the music never
         * stops. Drive it for real rather than poking desc.cur by hand. */
        uint8_t *dio = (uint8_t *)malloc(0x8000);
        uint32_t total = 0, got, guard = 0;
        uint32_t i;
        for (i = 0; i < 0x8000; i++) dio[i] = (uint8_t)(i ^ (i >> 5));
        s573_core_init(&c);
        mkcfg(&f, 0x0800, 0x1000, 0xdead, 0xbeef, 0xcafe, FLAGS_PLAY, 1);
        (void)s573_core_apply_cfg(&c, &f, 1, 0);
        CHECK(!s573_core_window_exhausted(&c), "not exhausted at the start");
        while (guard++ < 1000) {
            c.in_pos = c.in_len;                /* pretend the decoder ate it all */
            got = s573_core_refill(&c, dio);
            total += got;
            if (!got) break;
        }
        CHECK(guard < 1000, "terminated");
        CHECKEQ(total, s573_desc_stream_len(0x0800, 0x1000), "2N-1 bytes emitted");
        CHECK(s573_core_window_exhausted(&c), "window reads exhausted");
        CHECKEQ(c.desc.cur, 0x1000, "cur lands EXACTLY on mp3_end");
        CHECKEQ(c.cons_bytes, 0, "no credit: none of it has played");
        CHECK(s573_core_should_stop(&c), "and the song can now end");
        free(dio);
    }

    /* ------------------------------------------------------------------ */
    GROUP("the truncated final frame must not hold the song open");
    {
        /* THE 2026-09-14 dsfdr BUG. A window ends where the game says it ends,
         * not on an MP3 frame boundary, so when `cur` lands on mp3_end the
         * input buffer still holds a PARTIAL final frame. No more bytes can
         * ever be pulled to complete it, so minimp3 refuses it forever and
         * in_pos stays < in_len forever. The old gate required in_pos ==
         * in_len, which made s573_core_should_stop() structurally unreachable:
         * 32,811 lines of hardware log, 40+ stops, zero EXHAUSTION events, and
         * attract music that ran on until the game happened to clear bit14.
         *
         * Drive it the honest way: pull the window dry for real, leave a
         * residue the decoder cannot use, and require the song to end. The
         * tests above pretend "in_pos = in_len" -- that fiction is exactly
         * what hid this. */
        uint8_t *dio = (uint8_t *)malloc(0x8000);
        uint32_t guard = 0;
        uint32_t i;
        for (i = 0; i < 0x8000; i++) dio[i] = (uint8_t)(i * 7 + (i >> 3));
        s573_core_init(&c);
        mkcfg(&f, 0x0800, 0x1000, 0xdead, 0xbeef, 0xcafe, FLAGS_PLAY, 1);
        (void)s573_core_apply_cfg(&c, &f, 1, 0);

        /* pull until the window is dry, consuming all but a partial frame */
        while (guard++ < 1000) {
            if (c.in_len > 40) c.in_pos = c.in_len - 40;   /* 40 B tail left */
            else               c.in_pos = 0;
            if (!s573_core_refill(&c, dio)) break;
        }
        CHECK(guard < 1000, "terminated");
        CHECK(s573_core_window_exhausted(&c), "window is exhausted");
        CHECK(c.in_pos < c.in_len, "a truncated tail really is left over");

        c.pcm_wr = c.pcm_rd;                       /* ring has played out */
        CHECK(!s573_core_should_stop(&c),
              "before the decoder has refused it, the tail still holds the stop");

        /* the decoder is offered the tail and cannot make a frame of it */
        s573_core_mark_tail_spent(&c);
        CHECK(s573_core_should_stop(&c),
              "refused tail + drained ring -> the song ENDS");

        /* ...but PCM still queued must still hold it: the tail plays out */
        c.pcm_wr = (uint16_t)(c.pcm_rd + 7);
        CHECK(!s573_core_should_stop(&c), "queued PCM still holds the stop");
        free(dio);
    }

    /* ------------------------------------------------------------------ */
    GROUP("a mid-song sync loss must NEVER end the song");
    {
        /* The guard that keeps the fix from becoming a worse bug. The same
         * "no MPEG sync found" break fires mid-song when the game's loader has
         * not written the bytes yet (hardware 2026-09-12: the BIOS POST fill
         * read 48 KB in). Marking the tail spent there would cut the song off
         * at the first loader hiccup. */
        s573_core_init(&c);
        mkcfg(&f, 0x1000, 0x2000, 1, 2, 3, FLAGS_PLAY, 1);
        (void)s573_core_apply_cfg(&c, &f, 1, 0);
        c.desc.cur = 0x1400;                       /* a quarter in -- mid-song */
        c.in_len = 900; c.in_pos = 0;
        c.pcm_wr = c.pcm_rd;
        s573_core_mark_tail_spent(&c);
        CHECKEQ(c.tail_spent, 0, "mid-song mark is a NO-OP");
        CHECK(!s573_core_should_stop(&c), "and the song keeps playing");

        /* and a re-arm must clear a verdict left from the previous window */
        c.desc.cur = 0x2000;
        s573_core_mark_tail_spent(&c);
        CHECKEQ(c.tail_spent, 1, "at the end it does take");
        mkcfg(&f, 0x3000, 0x4000, 4, 5, 6, FLAGS_PLAY, 2);
        (void)s573_core_apply_cfg(&c, &f, 2, 1);
        CHECKEQ(c.tail_spent, 0, "a new window starts with a fresh verdict");
    }

    /* ------------------------------------------------------------------ */
    GROUP("playback accounting follows the DRAIN, not the decoder");
    {
        /* The regression this exists for: crediting at decode time put the
         * game's clock a full ring ahead of the speakers -- 1.486 s -- and on
         * hardware that desynced the chart and hung a stage at READY with 0
         * steps. Frames and bytes may only be credited as beats actually
         * drain. */
        uint32_t n;
        s573_core_init(&c);
        s573_core_adopt_ctrl_baseline(&c, 0x0000);

        /* decode three frames: 576 beats each, 417 input bytes each */
        s573_core_queue_frame(&c, S573_FRAME_BEATS, 417);
        s573_core_queue_frame(&c, S573_FRAME_BEATS, 417);
        s573_core_queue_frame(&c, S573_FRAME_BEATS, 417);
        CHECKEQ(c.frame_sync_cnt, 0, "decoding alone credits no frame");
        CHECKEQ(c.cons_bytes, 0, "decoding alone credits no bytes");

        n = s573_core_advance_played(&c, 0);      /* primes the baseline */
        CHECKEQ(n, 0, "first call only primes");

        /* the reader took a whole frame -- but it is still IN the elastic
         * buffer, not at the speaker: no credit yet */
        n = s573_core_advance_played(&c, (uint16_t)(S573_FRAME_BEATS));
        CHECKEQ(n, 0, "a frame inside the elastic buffer has not played");
        CHECKEQ(c.frame_sync_cnt, 0, "no pulse yet");

        /* the reader is two frames + the buffer depth along: two have played */
        n = s573_core_advance_played(&c, (uint16_t)(S573_FRAME_BEATS * 2 + S573_ELASTIC_BEATS));
        CHECKEQ(n, 2, "two frames finished");
        CHECKEQ(c.frame_sync_cnt, 2, "two pulses");
        CHECKEQ(c.cons_bytes, 834, "bytes credited == the two frames' input");

        /* a skipped frame's bytes ride forward onto the next real frame */
        s573_core_carry_bytes(&c, 100);
        s573_core_queue_frame(&c, S573_FRAME_BEATS, 417);
        n = s573_core_advance_played(&c, (uint16_t)(S573_FRAME_BEATS * 4 + S573_ELASTIC_BEATS));
        CHECKEQ(n, 2, "third and fourth frames played");
        CHECKEQ(c.cons_bytes, 834 + 417 + 517, "carried bytes are not lost");

        /* the pointer wraps at 2^16 and the diff must still be right */
        s573_core_init(&c);
        s573_core_queue_frame(&c, 10, 7);
        (void)s573_core_advance_played(&c, 0xFFF0);
        n = s573_core_advance_played(&c, (uint16_t)(0x0002 + S573_ELASTIC_BEATS)); /* wrapped: 18 beats */
        CHECKEQ(n, 1, "frame played across the 16-bit pointer wrap");

        /* a re-arm drops queued audio that never played */
        s573_core_init(&c);
        s573_core_queue_frame(&c, S573_FRAME_BEATS, 417);
        s573_core_pq_reset(&c);
        (void)s573_core_advance_played(&c, 0);
        n = s573_core_advance_played(&c, (uint16_t)(S573_FRAME_BEATS * 4 + S573_ELASTIC_BEATS));
        CHECKEQ(n, 0, "discarded audio never credits the next song");
        CHECKEQ(c.cons_bytes, 0, "and never credits its bytes");
    }

    /* ------------------------------------------------------------------ */
    GROUP("the pull never runs further ahead of the speakers than the ring");
    {
        /* The hardware regression: with no bound, a stretch the decoder could
         * not sync to consumed a 1,517,482-byte window in ~2 s while 16 KB of
         * audio played, and the game was left at READY with the stream already
         * exhausted. */
        uint8_t *dio = (uint8_t *)malloc(0x200000);
        uint32_t i, pulled = 0, got;
        for (i = 0; i < 0x200000; i++) dio[i] = (uint8_t)(i * 31 + (i >> 7));
        s573_core_init(&c);
        mkcfg(&f, 0x40, 0x180000, 0x451b, 0, 0, FLAGS_PLAY, 1);
        (void)s573_core_apply_cfg(&c, &f, 1, 0);
        /* nothing has played, so the pull must stop at the lead bound */
        for (i = 0; i < 500; i++) {
            c.in_pos = c.in_len;                  /* decoder ate it, made no audio */
            got = s573_core_refill(&c, dio);
            pulled += got;
            if (!got) break;
        }
        CHECK(c.pull_stalls > 0, "the bound engaged");
        CHECK(pulled <= S573_PULL_LEAD_MAX, "never pulled past the bound");
        CHECK(c.desc.cur < 0x180000, "the window was NOT consumed");
        CHECKEQ(c.pulled_bytes, pulled, "pulled_bytes tracks the pull");
        /* once audio plays, the pull is allowed to continue */
        s573_core_queue_frame(&c, S573_FRAME_BEATS, 20000);
        (void)s573_core_advance_played(&c, 0);
        (void)s573_core_advance_played(&c, (uint16_t)(S573_FRAME_BEATS + S573_ELASTIC_BEATS));
        CHECKEQ(c.cons_bytes, 20000, "playback credited");
        c.in_pos = c.in_len;
        CHECK(s573_core_refill(&c, dio) > 0, "the pull resumes as audio drains");
        free(dio);
    }

    /* ------------------------------------------------------------------ */
    GROUP("a pull into not-yet-loaded memory rewinds EXACTLY, nothing plays twice");
    {
        /* Model the loader: the disc bytes exist only up to LOADED; beyond it
         * the DIO window still holds the POST's memory-test fill. The service
         * must be able to pull, discover the data is not there, undo the pull,
         * and later -- after the loader writes it -- produce the SAME stream a
         * one-shot descramble would have. */
        uint32_t i, n, one_shot_len, streamed_len = 0;
        uint8_t *dio  = (uint8_t *)malloc(0x10000);
        uint8_t *full = (uint8_t *)malloc(0x10000);
        uint8_t *ref  = (uint8_t *)malloc(0x10000);
        uint8_t *out  = (uint8_t *)malloc(0x10000);
        const uint32_t START = 0x40, END = 0x4040, LOADED = 0x1240;
        s573_desc_t one;
        for (i = 0; i < 0x10000; i++) full[i] = (uint8_t)(i * 131 + (i >> 3));
        memcpy(dio, full, 0x10000);
        for (i = LOADED; i < END; i += 2) {           /* e7c6, e7c5, ... */
            uint16_t w = (uint16_t)(0xe7c6 - (i - LOADED) / 2);
            dio[i] = (uint8_t)w; dio[i+1] = (uint8_t)(w >> 8);
        }
        /* the reference: the whole window descrambled from the FULL data */
        s573_desc_init(&one, START, END, 0x6546, 0, 0, 1);
        one_shot_len = (uint32_t)s573_desc_pull(&one, full, ref, 0x10000);

        s573_core_init(&c);
        mkcfg(&f, START, END, 0x6546, 0, 0, FLAGS_PLAY, 1);
        (void)s573_core_apply_cfg(&c, &f, 1, 0);

        /* pull 1: entirely inside the loaded region -- "decode" it all */
        n = s573_core_refill(&c, dio);
        CHECK(n > 0, "first pull");
        memcpy(out + streamed_len, c.in_buf, c.in_len); streamed_len += c.in_len;
        c.in_pos = c.in_len;

        /* pull 2: crosses into the unloaded fill (only the first 512 stream
         * bytes of it are real). Pretend the decoder got one real frame (400
         * bytes) out of it, then hit the fill. */
        n = s573_core_refill(&c, dio);
        CHECK(n > 0, "second pull");
        memcpy(out + streamed_len, c.in_buf, 400); streamed_len += 400;
        c.in_pos = 400;
        CHECKEQ(s573_core_no_frame(&c, dio), 0, "no frame in the rest: not the end, so a rewind");
        CHECKEQ(c.rewinds, 1, "rewound once");
        CHECKEQ(c.in_len, 0, "buffer emptied after consuming into the new bytes");
        CHECKEQ(c.pulled_bytes, streamed_len, "pull credit == exactly what was kept");
        CHECKEQ(c.desc.byte_counter, streamed_len, "the descrambler agrees");

        /* the loader catches up */
        memcpy(dio, full, 0x10000);

        /* keep pulling until the window is exhausted */
        for (i = 0; i < 100; i++) {
            n = s573_core_refill(&c, dio);
            if (!n) break;
            memcpy(out + streamed_len, c.in_buf, c.in_len); streamed_len += c.in_len;
            c.in_pos = c.in_len;
        }
        CHECKEQ(streamed_len, one_shot_len, "same total length as a one-shot descramble");
        CHECKEQ(memcmp(out, ref, one_shot_len), 0,
                "byte-identical: nothing lost, nothing duplicated across the rewind");
        free(dio); free(full); free(ref); free(out);
    }

    /* ------------------------------------------------------------------ */
    GROUP("a rewrite of the SAME window is a re-arm (the preview restart), an enable edge is not");
    s573_core_init(&c);
    mkcfg(&f, 0x1000, 0x2000, 1, 2, 3, FLAGS_PLAY, 1);
    (void)s573_core_apply_cfg(&c, &f, 1, 0);
    c.desc.cur = 0x2000;                          /* pretend it played out */
    mkcfg(&f, 0x1000, 0x2000, 1, 2, 3, FLAGS_STOP, 2);
    act = s573_core_apply_cfg(&c, &f, 2, 1);      /* epoch +1, enables moved: a stop */
    CHECK(!(act & S573_ACT_FLUSH), "epoch +1 with the enables moving = a bare stop, no re-arm");
    CHECKEQ(c.desc.cur, 0x2000, "descrambler position untouched by the stop");
    mkcfg(&f, 0x1000, 0x2000, 1, 2, 3, FLAGS_STOP, 7);
    act = s573_core_apply_cfg(&c, &f, 7, 0);      /* epoch +5, enables unchanged: setup writes */
    CHECK(act & S573_ACT_FLUSH, "same window, epoch +5, enables unchanged -> re-arm");
    CHECKEQ(c.desc.cur, 0x1000, "descrambler rewound to the start of the window");
    mkcfg(&f, 0x1000, 0x2000, 1, 2, 3, FLAGS_PLAY, 8);
    act = s573_core_apply_cfg(&c, &f, 8, 0);      /* epoch +1, enables moved: play */
    CHECK(!(act & S573_ACT_FLUSH) && (act & S573_ACT_DRAIN_ON), "then the play edge just starts it");
    mkcfg(&f, 0x1000, 0x2000, 1, 2, 3, FLAGS_PLAY, 12);
    act = s573_core_apply_cfg(&c, &f, 12, 1);     /* epoch +4, enables unchanged, mid-drain */
    CHECK((act & S573_ACT_FLUSH) && (act & S573_ACT_FLUSH_DEFER), "same window rewritten while playing -> live re-arm");
    mkcfg(&f, 0x1000, 0x2000, 1, 2, 3, FLAGS_PLAY, 13);
    act = s573_core_apply_cfg(&c, &f, 13, 1);     /* epoch +1, enables unchanged: one setup write (or the OSD bit) */
    CHECK(act & S573_ACT_FLUSH, "epoch +1 with the enables unchanged is still a setup write");

    /* ------------------------------------------------------------------ */
    GROUP("song end credits the undecodable tail so the fabric's cur reaches mp3_end");
    s573_core_init(&c);
    mkcfg(&f, 0x1000, 0x1100, 1, 2, 3, FLAGS_PLAY, 1);
    (void)s573_core_apply_cfg(&c, &f, 1, 0);
    c.cons_bytes = 0x100 - 185;                   /* what the logs showed: short by the tail */
    c.desc.cur = 0x1100; c.in_len = c.in_pos = 0; c.pcm_wr = c.pcm_rd = 3;
    CHECK(s573_core_should_stop(&c), "exhausted + drained -> stop");
    s573_core_song_end(&c);
    CHECKEQ(c.cons_bytes, 0x100u, "credit brought up to the whole window");
    CHECKEQ((uint16_t)(s573_core_cons_word(&c) - c.cons_ofs), 0x100u, "and that is what the mailbox reports (less the re-arm offset)");
    c.cons_bytes = 0x100 + 5;                     /* never credit backwards */
    s573_core_song_end(&c);
    CHECKEQ(c.cons_bytes, 0x105u, "an over-credit is left alone");

    /* ------------------------------------------------------------------ */
    GROUP("the loader watermark: never pull DRAM the game has not written (ddr3mj 2026-09-28)");
    {
        /* The hardware shape: window at DRAM 0, the game has written six 2 KB
         * sectors and set the write pointer to the seventh; everything above is
         * still the POST fill. The pull must stop at the pointer's sector
         * boundary; as the pointer advances, pulls resume; nothing is ever read
         * from an unwritten sector, so the stream is byte-identical to a one-shot
         * descramble of the fully loaded window. */
        uint32_t i, n, one_shot_len, streamed_len = 0, wp;
        uint8_t *dio  = (uint8_t *)malloc(0x10000);
        uint8_t *full = (uint8_t *)malloc(0x10000);
        uint8_t *ref  = (uint8_t *)malloc(0x10000);
        uint8_t *out  = (uint8_t *)malloc(0x10000);
        const uint32_t START = 0x0, END = 0x8000;
        s573_desc_t one;
        for (i = 0; i < 0x10000; i++) full[i] = (uint8_t)(i * 131 + (i >> 3));
        for (i = 0; i < 0x10000; i += 2) {                /* the POST fill everywhere */
            uint16_t w = (uint16_t)(0x3a00 + i / 2);
            dio[i] = (uint8_t)w; dio[i+1] = (uint8_t)(w >> 8);
        }
        s573_desc_init(&one, START, END, 0x6546, 0, 0, 1);
        one_shot_len = (uint32_t)s573_desc_pull(&one, full, ref, 0x10000);

        s573_core_init(&c);
        /* THE HARDWARE ORDER: the game writes six sectors, THEN arms the window
         * and starts playback -- so at the re-arm the pointer already sits at
         * sector 7 and has just stopped moving. It must gate from the first pull
         * (2026-09-29: treating an unmoved pointer as stale left the gate off at
         * every re-arm). */
        wp = 6 * 2048;
        memcpy(dio, full, wp);
        s573_core_set_write_ptr(&c, wp, 1, 1000000u);
        mkcfg(&f, START, END, 0x6546, 0, 0, FLAGS_PLAY, 1);
        (void)s573_core_apply_cfg(&c, &f, 1, 0);
        CHECKEQ(s573_core_loaded_limit(&c), wp, "watermark = the pointer (sector-aligned) from the re-arm on");
        s573_core_set_write_ptr(&c, wp + 700, 1, 1010000u);   /* mid-sector: only complete sectors count */
        CHECKEQ(s573_core_loaded_limit(&c), wp, "a half-written sector is not loaded");
        s573_core_set_write_ptr(&c, wp, 1, 1020000u);

        /* pull everything the watermark allows, "decoding" it all */
        for (i = 0; i < 100; i++) {
            n = s573_core_refill(&c, dio);
            if (!n) break;
            memcpy(out + streamed_len, c.in_buf, c.in_len); streamed_len += c.in_len;
            c.in_pos = c.in_len;
        }
        CHECKEQ(streamed_len, wp, "pulled exactly the six loaded sectors, not a byte more");
        CHECK(c.wp_holds > 0, "and the watermark is what held the pull");
        CHECKEQ(memcmp(out, ref, streamed_len), 0, "those bytes are the real stream");

        /* the loader keeps writing, a sector every 42 ms, and we keep up */
        while (wp < END) {
            memcpy(dio + wp, full + wp, 2048);
            wp += 2048;
            s573_core_set_write_ptr(&c, wp < END ? wp : END - 1, 1, 1020000u + wp * 20u);   /* rests at end-1 */
            for (i = 0; i < 100; i++) {
                n = s573_core_refill(&c, dio);
                if (!n) break;
                memcpy(out + streamed_len, c.in_buf, c.in_len); streamed_len += c.in_len;
                c.in_pos = c.in_len;
            }
        }
        CHECKEQ(streamed_len, one_shot_len, "same total length as a one-shot descramble");
        CHECKEQ(memcmp(out, ref, one_shot_len), 0,
                "byte-identical: nothing from the fill ever reached the decoder");

        CHECKEQ(c.wp_lifts, 0u, "a moving loader never looked stale");

        /* a pointer outside the window (the 4th Mix preload case) gates nothing */
        s573_core_set_write_ptr(&c, 0x00400000, 1, 5000000u);
        CHECKEQ(s573_core_loaded_limit(&c), END, "pointer outside the window: no watermark");
        s573_core_set_write_ptr(&c, 0x100, 0, 5000000u);
        CHECKEQ(s573_core_loaded_limit(&c), END, "older bitstream, no pointer: no watermark");

        /* a preload title whose parked pointer happens to sit INSIDE the window:
         * it holds the pull, does not move, and after S573_WP_STALE_US the gate
         * is lifted for the window -- but not one poll sooner */
        s573_core_init(&c);
        memcpy(dio, full, 0x10000);
        s573_core_set_write_ptr(&c, 0x2000, 1, 9000000u);
        mkcfg(&f, START, END, 0x6546, 0, 0, FLAGS_PLAY, 1);
        (void)s573_core_apply_cfg(&c, &f, 1, 0);
        streamed_len = 0;
        for (i = 0; i < 100; i++) {                       /* drains the 0x2000 it allows */
            n = s573_core_refill(&c, dio);
            if (!n) break;
            streamed_len += c.in_len; c.in_pos = c.in_len;
        }
        CHECKEQ(streamed_len, 0x2000u, "held at the parked pointer");
        s573_core_set_write_ptr(&c, 0x2000, 1, 9000000u + S573_WP_STALE_US - 1u);
        CHECKEQ(s573_core_refill(&c, dio), 0u, "still held one microsecond short of stale");
        CHECKEQ(c.wp_lifted, 0u, "not lifted yet");
        s573_core_set_write_ptr(&c, 0x2000, 1, 9000000u + S573_WP_STALE_US);
        (void)s573_core_refill(&c, dio);                   /* this hold declares it stale */
        CHECKEQ(c.wp_lifted, 1u, "stale after S573_WP_STALE_US without movement");
        CHECK(s573_core_refill(&c, dio) > 0, "and the pull runs on past it");
        CHECKEQ(s573_core_loaded_limit(&c), END, "gate lifted for the rest of the window");
        free(dio); free(full); free(ref); free(out);
    }

    /* ------------------------------------------------------------------ */
    GROUP("s573_desc_seek lands on the same key state and bytes as stepping there");
    {
        /* both key schedules, even and odd positions, the last byte, past it */
        static const uint32_t idxs[] = { 0, 1, 2, 3, 14, 15, 16, 29, 30, 31, 44, 45, 46,
                                         60, 61, 100, 101, 2047, 2048, 2049, 4093, 4094, 4095, 9999 };
        uint32_t i, k, m;
        uint8_t *dio = (uint8_t *)malloc(0x2000);
        uint8_t *ref = (uint8_t *)malloc(0x2000);
        uint8_t  out[64];
        for (i = 0; i < 0x2000; i++) dio[i] = (uint8_t)(i * 97 + (i >> 5) + 3);
        for (m = 0; m < 2; m++) {
            const uint32_t START = 0x100, END = 0x100 + 4096;      /* 2048 words: 4095 stream bytes */
            s573_desc_t one, seek;
            uint32_t len;
            s573_desc_init(&one, START, END, 0xA5C3, 0x3C5A, 0x0077, (int)m);
            len = (uint32_t)s573_desc_pull(&one, dio, ref, 0x2000);
            CHECKEQ(len, 4095u, "2N-1 bytes");
            for (k = 0; k < sizeof idxs / sizeof idxs[0]; k++) {
                uint32_t idx = idxs[k], want = idx > len ? len : idx, n;
                s573_desc_init(&seek, START, END, 0xA5C3, 0x3C5A, 0x0077, (int)m);
                /* disturb the live state: a seek must not depend on it */
                (void)s573_desc_pull(&seek, dio, out, 37);
                s573_desc_seek(&seek, dio, idx);
                CHECKEQ(seek.byte_counter, want, "byte_counter == idx (clamped)");
                n = (uint32_t)s573_desc_pull(&seek, dio, out, 64);
                if (want == len) CHECKEQ(n, 0u, "seek to the end: nothing more");
                else {
                    uint32_t exp = len - want < 64 ? len - want : 64;
                    CHECKEQ(n, exp, "bytes available after the seek");
                    CHECKEQ(memcmp(out, ref + want, n), 0, "and they are the stepped stream's bytes");
                }
            }
            /* the closed form over a long run: every position of a 15*16*3 stretch */
            for (k = 0; k < 720; k += 7) {
                s573_desc_init(&seek, START, END, 0xA5C3, 0x3C5A, 0x0077, (int)m);
                s573_desc_seek(&seek, dio, k);
                (void)s573_desc_pull(&seek, dio, out, 4);
                CHECKEQ(memcmp(out, ref + k, 4), 0, "closed-form key advance == stepping");
            }
        }
        free(dio); free(ref);
    }

    /* ------------------------------------------------------------------ */
    GROUP("a held low byte is ONE byte at the watermark, not a way past it (ddr3mj 2026-09-29)");
    {
        /* The pull count reaches the watermark on an odd byte: the descrambler
         * has read the last loaded word and holds its low byte. The next pull
         * may hand out that byte and nothing else. The first cut of the gate
         * skipped the whole check while a byte was held, and every window in
         * the log stalled at exactly 6 sectors + one pull (0x3a7x). */
        uint32_t i, n, wp = 6 * 2048, total = 0;
        uint8_t *dio = (uint8_t *)malloc(0x10000);
        for (i = 0; i < 0x10000; i++) dio[i] = (uint8_t)(i * 131 + (i >> 3));
        s573_core_init(&c);
        s573_core_set_write_ptr(&c, wp, 1, 1000000u);
        mkcfg(&f, 0, 0x8000, 0x6546, 0, 0, FLAGS_PLAY, 1);
        (void)s573_core_apply_cfg(&c, &f, 1, 0);
        /* consume in odd steps so a pull ends on an odd count */
        for (i = 0; i < 100; i++) {
            n = s573_core_refill(&c, dio);
            if (!n) break;
            total += n;
            c.in_pos = c.in_len;
            if (total == wp - 1) break;                   /* stop one byte short */
            if (c.in_len > 3) { /* leave room so the next pull is small */ }
        }
        /* force the exact shape: pulled = wp-1 (odd), a byte held */
        s573_core_init(&c);
        s573_core_set_write_ptr(&c, wp, 1, 1000000u);
        (void)s573_core_apply_cfg(&c, &f, 1, 0);
        c.in_pos = c.in_len = 0;
        {   /* pull wp-1 bytes in one go by bounding the room via in_len */
            uint32_t want = wp - 1, got = 0;
            while (got < want) {
                uint32_t room = want - got;
                c.in_pos = c.in_len = 0;
                if (room > S573_IN_BUF) room = S573_IN_BUF;
                c.in_len = S573_IN_BUF - room;            /* fake occupancy to bound the pull */
                n = s573_core_refill(&c, dio);
                CHECK(n == room, "bounded pull");
                got += n;
            }
        }
        CHECKEQ(c.pulled_bytes, wp - 1, "an odd byte count pulled");
        CHECKEQ(c.desc.cur, wp, "the descrambler has read the last loaded word");
        CHECKEQ(c.desc.hold_valid, 1u, "and holds its low byte");
        c.in_pos = c.in_len = 0;
        CHECKEQ(s573_core_refill(&c, dio), 1u, "the next pull is that one byte");
        c.in_pos = c.in_len = 0;
        CHECKEQ(s573_core_refill(&c, dio), 0u, "then the watermark holds");
        CHECK(c.wp_holds > 0, "counted as a hold");
        CHECKEQ(c.pulled_bytes, wp, "never a byte past the loader");
        free(dio);
    }

    /* ------------------------------------------------------------------ */
    GROUP("junk that reached the buffer before the loader is read AGAIN after a rewind, never kept");
    {
        /* The 2026-09-29 stall: the first pulls of a window ran past the loader
         * (no fresh pointer yet), the decoder consumed the real frames and left
         * the junk tail unconsumed; the rewind kept that tail as "old bytes" and
         * every later attempt found no frame across the old/new junction. Now a
         * rewind discards everything unconsumed and seeks back, so the same DRAM
         * is re-read once the loader has written it -- the stream comes out
         * byte-identical to a one-shot descramble. */
        uint32_t i, n, one_shot_len, streamed_len = 0;
        uint8_t *dio  = (uint8_t *)malloc(0x10000);
        uint8_t *full = (uint8_t *)malloc(0x10000);
        uint8_t *ref  = (uint8_t *)malloc(0x10000);
        uint8_t *out  = (uint8_t *)malloc(0x10000);
        const uint32_t START = 0x0, END = 0x8000, LOADED = 0x3200;   /* not a pull multiple: the boundary falls inside a buffer */
        s573_desc_t one;
        for (i = 0; i < 0x10000; i++) full[i] = (uint8_t)(i * 131 + (i >> 3));
        for (i = 0; i < 0x10000; i += 2) { uint16_t w = (uint16_t)(0x3940 + i / 2); dio[i] = (uint8_t)w; dio[i+1] = (uint8_t)(w >> 8); }
        memcpy(dio, full, LOADED);
        s573_desc_init(&one, START, END, 0x6546, 0, 0, 1);
        one_shot_len = (uint32_t)s573_desc_pull(&one, full, ref, 0x10000);

        s573_core_init(&c);                           /* no pointer: the pull is not gated */
        mkcfg(&f, START, END, 0x6546, 0, 0, FLAGS_PLAY, 1);
        (void)s573_core_apply_cfg(&c, &f, 1, 0);
        /* pulls until the buffer straddles the loaded boundary; "decode" up to
         * 3 bytes short of it, leaving the junk (and 3 real bytes) unconsumed */
        while (c.pulled_bytes <= LOADED) {
            n = s573_core_refill(&c, dio);
            CHECK(n > 0, "pull");
            if (c.pulled_bytes <= LOADED) { memcpy(out + streamed_len, c.in_buf, c.in_len); streamed_len += c.in_len; c.in_pos = c.in_len; }
        }
        {
            uint32_t real_here = LOADED - (c.pulled_bytes - c.in_len);   /* real bytes in this buffer */
            CHECK(real_here > 3 && real_here < c.in_len, "the boundary falls inside the buffer");
            c.in_pos = real_here - 3;
            memcpy(out + streamed_len, c.in_buf, c.in_pos); streamed_len += c.in_pos;
        }
        /* one more pull on top (compacts the junk-laden tail to the front, adds
         * more junk): now the junk is OLD bytes, the shape that kept it forever */
        n = s573_core_refill(&c, dio);
        CHECK(n > 0, "the pull after the junction");
        CHECKEQ(c.in_pos, 0u, "compacted");
        CHECKEQ(s573_core_no_frame(&c, dio), 0, "no frame across the junction: rewind");
        CHECKEQ(c.in_len, 0u, "nothing kept");
        CHECKEQ(c.pulled_bytes, streamed_len, "position = the first unconsumed byte");
        /* still not loaded: the retry finds junk again and rewinds again, same place */
        n = s573_core_refill(&c, dio);
        CHECK(n > 0, "retry pulls");
        CHECKEQ(s573_core_no_frame(&c, dio), 0, "rewind again");
        CHECKEQ(c.pulled_bytes, streamed_len, "same place");
        /* the loader lands */
        memcpy(dio, full, 0x10000);
        for (i = 0; i < 100; i++) {
            n = s573_core_refill(&c, dio);
            if (!n) break;
            memcpy(out + streamed_len, c.in_buf, c.in_len); streamed_len += c.in_len;
            c.in_pos = c.in_len;
        }
        CHECKEQ(streamed_len, one_shot_len, "same total length as a one-shot descramble");
        CHECKEQ(memcmp(out, ref, one_shot_len), 0, "byte-identical: the junk was re-read as real bytes");
        free(dio); free(full); free(ref); free(out);
    }

    /* ------------------------------------------------------------------ */
    GROUP("no frame at the spent window = the truncated tail, consumed so the song can end");
    {
        uint8_t *dio = (uint8_t *)malloc(0x10000);
        uint32_t i, n;
        for (i = 0; i < 0x10000; i++) dio[i] = (uint8_t)(i * 131 + (i >> 3));
        s573_core_init(&c);
        mkcfg(&f, 0x1000, 0x1200, 1, 2, 3, FLAGS_PLAY, 1);
        (void)s573_core_apply_cfg(&c, &f, 1, 0);
        n = s573_core_refill(&c, dio);
        CHECKEQ(n, 0x1FFu, "the whole (2N-1) window in one pull");
        CHECK(s573_core_window_exhausted(&c), "exhausted");
        c.in_pos = 0x1FF - 200;                            /* 200 undecodable tail bytes */
        c.pcm_wr = c.pcm_rd = 5;
        CHECK(!s573_core_should_stop(&c), "the tail holds the stop while unconsumed");
        CHECKEQ(s573_core_no_frame(&c, dio), 1, "no frame in it: it is the tail");
        CHECKEQ(c.in_pos, c.in_len, "consumed");
        CHECKEQ(c.tail_spent, 1u, "tail spent");
        CHECKEQ(c.pq_pending_bytes, 200u, "its bytes ride the (nonexistent) next frame's credit");
        CHECKEQ(c.rewinds, 0u, "no rewind at the end");
        CHECK(s573_core_should_stop(&c), "so the song can end");
        free(dio);
    }

    printf("\n%d groups, %d failures\n", groups, fails);
    if (fails) { printf("RESULT: FAIL\n"); return 1; }
    printf("RESULT: PASS\n");
    return 0;
}
