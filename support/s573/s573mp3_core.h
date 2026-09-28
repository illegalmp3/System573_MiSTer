/* -----------------------------------------------------------------------------
 * s573mp3_core.h - Konami System 573 HPS MP3 service: the portable core
 *
 * Everything in the service that can be decided WITHOUT touching /dev/mem, the
 * SPI mailbox or minimp3 lives here, so it can be exercised by host tests on an
 * ordinary machine (support/s573/tests). The Main-side glue (mmap, spi_w,
 * mp3dec_decode_frame, printf) lives in s573mp3.cpp and calls into this.
 *
 * The contract this implements is written in the RTL, not invented here:
 *   rtl/s573_hps_ext.v    - CMD_573_PTRS / STATUS / CTRL / MP3CFG word layouts,
 *                           the reset-epoch freeze, the cumulative-counter rule
 *   rtl/s573_pcm_ring.v   - ring geometry and the FULL-WIDTH pointer compare
 *   rtl/s573_mp3_credit.v - the cumulative consumption credit + its rebaseline
 *   rtl/k573_mp3stream.v  - what `cur` (and therefore 0xae bit12) means
 *
 * Four defects are pre-cleared here because they were paid for once already:
 *   1. the core-name gate (docs/2026-07-31-mp3-audio-WORKING.md) - s573mp3.cpp
 *   2. cfg_epoch adopted as 8 bits while compared as 16
 *      (docs/2026-08-02-mp3-stop-cfg-epoch-truncation.md)
 *   3. the PCM write pointer masked to 15 bits, dropping the wrap MSB the
 *      fabric's empty test needs (docs/2026-08-02-mp3-stale-pcm-residue.md)
 *   4. no discard of already-decoded PCM on a re-arm (same doc)
 * Each has a host test whose mutation define restores the bug; the test must go
 * RED under it, or the test is not testing anything.
 *
 * C99. No allocation, no libc I/O, no globals.
 * Released under the GNU GPL v2.
 * ---------------------------------------------------------------------------- */
#ifndef S573MP3_CORE_H
#define S573MP3_CORE_H

#include <stdint.h>
#include <stddef.h>
#include "s573_descramble.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- DDR3 geometry. MUST track the RTL; a mismatch is silent corruption. ---- */
#define S573_DIO_PHYS        0x32000000u   /* s573_ddram_arb DIO window base    */
#define S573_DIO_SIZE        0x02000000u   /* 32 MiB                            */
#define S573_PCM_BEATS_LOG2  15            /* s573_pcm_ring BEATS_LOG2          */
#define S573_PCM_BEATS       (1u << S573_PCM_BEATS_LOG2)   /* 32768 beats       */
#define S573_PCM_BYTES       (S573_PCM_BEATS * 8u)          /* 256 KiB          */
#define S573_PCM_RING_OFF    (0x3E2000u * 8u)               /* RING_OFF_BEAT<<3 */
#define S573_PCM_PHYS        (S573_DIO_PHYS + S573_PCM_RING_OFF)  /* 0x33F10000 */

/* One beat = 8 bytes = 2 interleaved stereo int16 samples (L0 R0 L1 R1). */
#define S573_BEAT_BYTES      8u
#define S573_BEAT_SAMPLES    2u

/* Pointer convention (rtl/s573_pcm_ring.v:43-47,:54-55,:83): a pointer is
 * [BEATS_LOG2:0] -- the wrap MSB is PART OF the value, and the fabric's
 * have_data test compares ALL of it. Mask the pointer with PTR_MASK for
 * arithmetic and only ever with IDX_MASK when converting to an offset. */
#define S573_PCM_PTR_MASK    ((1u << (S573_PCM_BEATS_LOG2 + 1)) - 1u)  /* 0xFFFF */
#define S573_PCM_IDX_MASK    (S573_PCM_BEATS - 1u)                     /* 0x7FFF */

/* SPI command codes (rtl/s573_hps_ext.v). MP3CFG must stay top of range. */
#define CMD_573_PTRS         0x68
#define CMD_573_STATUS       0x69
#define CMD_573_CTRL         0x6A
#define CMD_573_MP3CFG       0x6B

/* CMD_573_CTRL word2 (ctrl_flags). bit0 is RESERVED: the descramble scheme is
 * OSD-owned now (emu.sv: status[101] -> k573dio), so writing it does nothing. */
#define S573_CTRL_RESERVED0  0x0001
#define S573_CTRL_DRAIN_EN   0x0002

/* CMD_573_MP3CFG word8: {12'd0, fpga_ctrl[15:13], cfg_ddrsbm} */
#define S573_CFG_DDRSBM      0x0001
#define S573_CFG_CTRL13      0x0002
#define S573_CFG_CTRL14      0x0004   /* a1 = STREAMING_ENABLE (the start gate) */
#define S573_CFG_CTRL15      0x0008

/* Playback queue depth: frames decoded-but-not-yet-played. The ring holds
 * 32768 beats = 56.9 frames, so 128 is comfortably more than can ever be
 * outstanding. */
#define S573_PQ_LEN          128

/* The fabric's elastic buffer (s573_mp3_pcm, 512 samples = 256 beats) sits
 * between the ring reader -- where we see beats consumed -- and the DAC. It
 * runs full during playback (buf=512 on every hardware heartbeat), so a beat
 * the reader fetched reaches the speaker ~11.6 ms later. Credit is lagged by
 * that much, otherwise the game's clock leads the audio and the arrows arrive
 * early -- which is what a player reported on the first playable credit. */
#define S573_ELASTIC_BEATS   256u

/* When a re-arm arrives while the drain is LIVE (the song-select scroll does
 * this: the next preview is armed before the previous one stops), the reader
 * is advancing ~110 beats per 5 ms poll. Parking one beat past a snapshot of
 * it is a race -- it may already be past us, and the difference then reads
 * as a full ring of replay. Park THIS far ahead instead, zeroed: up to 46 ms
 * of silence instead of the old preview's 1.5 s tail. Upstream deferred the
 * flush in this case, having measured that the case never occurred; it does. */
#define S573_LIVE_GAP_BEATS  1024u   /* retired 2026-09-27: the live case now stops the reader first */

/* minimp3 emits 1152 samples per MPEG-1 Layer III frame. */
#define S573_FRAME_SAMPLES   1152u
#define S573_FRAME_BEATS     (S573_FRAME_SAMPLES / S573_BEAT_SAMPLES)   /* 576 */

/* Scrambled-window input buffer. Must exceed one maximum frame (1441 B) by
 * enough that a frame never splits across a refill; 4096 was the size upstream
 * ran on silicon. NOT 8192 - a single 8 KiB descramble costs ~1.3 ms inside a
 * ~5 ms poll (decision-B spike, "CPU cost"). */
#define S573_IN_BUF          4096u
#define S573_IN_KEEP         1600u   /* >= 1441 B lookahead kept on a refill */

/* How far the descrambler may run AHEAD of the audio that has actually played,
 * in stream bytes. This is the demand model, and without it the service is not
 * paced at all when the data does not decode: on hardware 2026-09-12 a
 * 1,517,482-byte window was consumed in ~2 s while 16 KB of audio played,
 * because every failed decode simply pulled more. Real DIO silicon cannot do
 * that -- it is paced by the MAS3507D consuming bytes -- so neither may we.
 * 48 KB is ~3 s at 128 kbps, comfortably more than the ring's 1.486 s, so it
 * never throttles healthy playback; it only bounds a runaway. */
#define S573_PULL_LEAD_MAX   49152u

/* ---- one CMD_573_PTRS exchange, as read back ---- */
typedef struct {
    uint16_t fab_pcm_rd;   /* word0 up: fabric ring read pointer, FULL width   */
    uint16_t fab_pos_lo;   /* word1 up: k573_mp3stream cur[16:1] echo          */
    uint16_t cfg_epoch;    /* word2 up: the AUTHORITATIVE 16-bit config epoch  */
    uint8_t  rst_epoch;    /* word3 up: core-reset epoch, 8 bits               */
} s573_ptrs_t;

/* ---- one CMD_573_MP3CFG exchange, as read back ---- */
typedef struct {
    uint16_t epoch8;       /* word0: cfg_epoch[7:0] IDENTITY ECHO only. Never
                            * compare this against a 16-bit epoch - that is
                            * bug 2, and it cannot match past 255.            */
    uint32_t mp3_start;    /* words 1,2 - byte offset inside the DIO window    */
    uint32_t mp3_end;      /* words 3,4 - exclusive                            */
    uint16_t key1, key2, key3;   /* words 5,6,7                                */
    uint16_t flags;        /* word8: S573_CFG_*                                */
    uint32_t gain_ll;      /* MAS3507D output gain matrix, 20 bit, 0 = mute    */
    uint32_t gain_rr;
    uint8_t  gain_seen;    /* sticky: has the game EVER set the gain?          */
} s573_cfg_t;

/* ---- what apply_cfg tells the caller to do (a bitmask) ---- */
#define S573_ACT_FLUSH        0x01  /* collapse the ring + mp3dec_init NOW     */
#define S573_ACT_FLUSH_DEFER  0x02  /* re-arm seen while draining: deferred    */
#define S573_ACT_DRAIN_ON     0x04  /* ctrl_flags DRAIN_EN just went 0 -> 1    */
#define S573_ACT_DRAIN_OFF    0x08  /* ctrl_flags DRAIN_EN just went 1 -> 0    */
#define S573_ACT_SCHEME_BAD   0x10  /* our descramble scheme != the fabric's   */

typedef struct {
    /* ---- mailbox mirror ---- */
    uint16_t pcm_wr;          /* OUR ring write pointer, FULL width incl wrap  */
    uint16_t pcm_rd;          /* fabric read pointer as of the last PTRS       */
    uint16_t cfg_epoch;       /* last adopted config epoch, FULL 16 bits       */
    uint8_t  rst_ack;         /* the reset epoch we will ack / have acked      */
    uint8_t  have_cfg;        /* a config has been adopted at least once       */
    uint8_t  ptrs_thawed;     /* our view: rst_ack == the epoch last seen      */
    uint8_t  ctrl_primed;     /* the CTRL baselines have been adopted          */
    uint16_t ctrl_flags;      /* what we last sent as CMD_573_CTRL word2       */

    /* ---- cumulative event counters, 8 bit on the wire ---- */
    /* BOTH are referenced to the DRAIN, not to the decoder. The decoder runs a
     * full ring ahead of the speakers -- 32768 beats is 1.486 s -- so crediting
     * either of these at decode time puts the game's clock 1.5 s ahead of the
     * audio, which in a rhythm game is the whole ballgame. The transport design
     * said so outright: "an HPS-credit-paced cur leads real audio by ~1.5 s and
     * a PCM-drain-referenced one by ~5 ms". Measured on hardware 2026-09-12:
     * the chart desynced, the song-select preview lagged, and a stage sat at
     * READY and cleared with 0 steps. */
    uint8_t  frame_sync_cnt;  /* ++ per frame actually PLAYED                  */
    uint8_t  frame_idle_cnt;  /* ++ per decode attempt that yielded no frame   */

    /* ---- the end-of-window input tail ----
     * A window does not end on a frame boundary, so when `cur` lands on
     * mp3_end the input buffer still holds a TRUNCATED final frame that
     * minimp3 will never consume: no more bytes can ever be pulled to
     * complete it. in_pos therefore stays < in_len forever, and gating the
     * song end on in_pos == in_len makes s573_core_should_stop() structurally
     * unreachable -- measured on hardware 2026-09-14 (dsfdr): 32,811 log lines,
     * 40+ stops, and not ONE "DRAIN OFF via EXHAUSTION". The only thing that
     * could stop audio was the game explicitly clearing fpga_ctrl bit14; any
     * screen that does not clear it leaves the stream running on.
     * The caller sets this when the decoder has been offered the tail with the
     * window already exhausted and made no progress on it. */
    uint8_t  tail_spent;

    /* ---- the option-(c) consumption credit ---- */
    uint32_t cons_bytes;      /* stream bytes whose audio has actually PLAYED  */
    uint32_t pulled_bytes;    /* stream bytes pulled since the re-arm          */
    uint32_t pull_stalls;     /* times the lead bound held the pull back       */

    /* ---- pull snapshot, so a pull into not-yet-loaded memory can be undone ----
     * The game streams a song into DIO RAM WHILE it plays. Real DIO silicon
     * fetches on demand and cannot outrun that loader; we can, and on hardware
     * 2026-09-12 we did: 48 KB into the window we read the BIOS POST's memory
     * test fill (e7c6 e7c5 e7c4...) instead of the song, consumed it as
     * "no sync, skip", and the real bytes then landed behind us where nothing
     * would ever re-read them. Deadlock at lead=49152 until the game gave up.
     * The descrambler is deterministic and resumable (the spike proved chunked
     * pulls are byte-identical), so a pull can be rewound EXACTLY and retried
     * next poll, by which time the loader has caught up. */
    s573_desc_t snap_desc;
    uint32_t snap_in_len;
    uint32_t snap_pulled;
    uint16_t snap_pending;
    uint8_t  snap_valid;
    uint32_t rewinds;         /* pulls undone because the bytes were not there */

    /* ---- playback queue: turns drained beats into frames+bytes played ---- */
    struct { uint16_t beats; uint16_t bytes; } pq[S573_PQ_LEN];
    uint8_t  pq_head, pq_tail;
    uint32_t pq_part;         /* beats drained into the frame at the head      */
    uint16_t pq_pending_bytes;/* input bytes of skipped frames, ride the next  */
    uint16_t last_fab_rd;     /* to diff the fabric read pointer per poll      */
    uint8_t  rd_primed;

    /* ---- descrambler + window ---- */
    s573_desc_t desc;
    uint32_t win_start, win_end;   /* the window the descrambler is armed to   */
    uint16_t key1, key2, key3;
    uint8_t  ddrsbm;

    /* ---- input sliding window over the descrambled stream ---- */
    uint8_t  in_buf[S573_IN_BUF];
    uint32_t in_len;
    uint32_t in_pos;

    /* ---- observability ---- */
    uint32_t flushes;
    uint32_t beats_dropped;
    uint32_t frames;
    uint32_t torn_cfg;        /* MP3CFG word0 echo disagreed with the PTRS low byte */
} s573_core_t;

void     s573_core_init(s573_core_t *c);

/* CMD_573_CTRL word0 carries the fabric's CURRENT cumulative baselines. Adopt
 * them as our own counts and echo them back in the same exchange, so the diff
 * is zero and no pulses are fabricated. Required whenever the service (re)starts
 * without a core reset - the fabric's `rebaseline` covers only its own reset. */
void     s573_core_adopt_ctrl_baseline(s573_core_t *c, uint16_t word0);

/* A core reset was observed (PTRS word3 moved). Pointers are FROZEN in the
 * fabric until we ack, so: zero our writer, forget the config, re-prime CTRL.
 * Returns nonzero if the caller must also flush decoded PCM + mp3dec_init. */
int      s573_core_on_core_reset(s573_core_t *c, uint8_t rst_epoch);

/* Adopt a freshly read config. `authoritative_epoch` MUST be the 16-bit epoch
 * from PTRS word2, never cfg->epoch8 (bug 2). `drain_before` is ctrl_flags
 * DRAIN_EN as it stood BEFORE this call. Returns an S573_ACT_* mask. */
int      s573_core_apply_cfg(s573_core_t *c, const s573_cfg_t *cfg,
                             uint16_t authoritative_epoch, int drain_before);

/* Ring accounting. Both compare the FULL pointer width including the wrap MSB:
 * a ring exactly one lap ahead is FULL, not empty. */
uint32_t s573_core_pcm_used(const s573_core_t *c);
uint32_t s573_core_pcm_free(const s573_core_t *c);
int      s573_core_pcm_empty(const s573_core_t *c);

/* Byte offset of a pointer within the 256 KiB ring mapping. This is the ONLY
 * place the wrap MSB may be masked off - forgetting it here makes
 * (S573_PCM_BYTES - offset) underflow and runs the memcpy off the mapping. */
uint32_t s573_core_pcm_byte_off(uint16_t ptr);

/* Advance our write pointer by `beats` (full-width, wrap MSB preserved). */
void     s573_core_wrote_pcm(s573_core_t *c, uint32_t beats);

/* Queue a decoded frame for playback accounting: `beats` of PCM produced from
 * `bytes` of the descrambled stream. Call once per frame actually written to
 * the ring. Bytes from frames that produced no audio are carried forward. */
void     s573_core_queue_frame(s573_core_t *c, uint32_t beats, uint32_t bytes);
void     s573_core_carry_bytes(s573_core_t *c, uint32_t bytes);

/* Advance playback accounting from the fabric's ring read pointer. Returns the
 * number of frames that finished playing since the last call; those are added
 * to frame_sync_cnt and their input bytes to cons_bytes. */
uint32_t s573_core_advance_played(s573_core_t *c, uint16_t fab_rd);

/* Drop the playback queue (a re-arm discards decoded audio that never played). */
void     s573_core_pq_reset(s573_core_t *c);

/* Collapse the ring to empty-relative-to-the-fabric: park our writer `gap`
 * beats ahead of where the fabric has read to, so nothing already-decoded
 * replays. gap=1 -- the caller stops the fabric reader first when it was live
 * (2026-09-27), so the snapshot it collapses against is the frozen one.
 * Returns the number of beats dropped. */
uint32_t s573_core_ring_collapse(s573_core_t *c, uint32_t gap);

/* The honest song-end test: the descrambled window is exhausted AND the decoded
 * tail has drained. The enable bits are a START gate only - ddrsbm asserts
 * fpga_ctrl[14:13] once and never clears them
 * (docs/2026-07-31-mp3-audio-WORKING.md). */
int      s573_core_window_exhausted(const s573_core_t *c);
int      s573_core_should_stop(const s573_core_t *c);
/* "the decoder was offered what is left and could not use it". Only takes
 * effect once the window is exhausted, so a mid-song sync loss (bytes not
 * loaded yet) can never cut a song short. */
void     s573_core_mark_tail_spent(s573_core_t *c);

/* May we decode another frame? STRICTLY a free-space test - never a timer.
 * (transport-design prerequisite 4: the MP3_UNPACED flood relocated to C is
 * exactly the failure mode this guards.) */
int      s573_core_may_decode(const s573_core_t *c);

/* Top up in_buf from the DIO window, compacting what minimp3 has not consumed.
 * `dio` points at the mmap of S573_DIO_PHYS. Returns bytes added. Takes the
 * pull snapshot first. */
uint32_t s573_core_refill(s573_core_t *c, const uint8_t *dio);

/* Did the decoder's scan of [in_pos, in_pos+skip) reach into the bytes the
 * LAST refill pulled? If so those bytes held no frame and were probably not
 * loaded yet. */
int      s573_core_skip_hits_new_bytes(const s573_core_t *c, uint32_t skip);

/* Undo the last refill EXACTLY: the descrambler, the pull credit and the input
 * length go back to before it, minus any bytes real frames consumed out of it
 * (the descrambler is advanced past those without re-emitting them, so nothing
 * plays twice). Next poll re-pulls the same region. */
void     s573_core_rewind_pull(s573_core_t *c, const uint8_t *dio);

/* The 16-bit words to send in the down direction. */
uint16_t s573_core_ctrl_word1(const s573_core_t *c);   /* {sync, idle}         */
uint16_t s573_core_cons_word(const s573_core_t *c);    /* cons_bytes low 16    */

#ifdef __cplusplus
}
#endif
#endif /* S573MP3_CORE_H */
