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

/* minimp3 emits 1152 samples per MPEG-1 Layer III frame. */
#define S573_FRAME_SAMPLES   1152u
#define S573_FRAME_BEATS     (S573_FRAME_SAMPLES / S573_BEAT_SAMPLES)   /* 576 */

/* Scrambled-window input buffer. Must exceed one maximum frame (1441 B) by
 * enough that a frame never splits across a refill; 4096 was the size upstream
 * ran on silicon. NOT 8192 - a single 8 KiB descramble costs ~1.3 ms inside a
 * ~5 ms poll (decision-B spike, "CPU cost"). */
#define S573_IN_BUF          4096u
#define S573_IN_KEEP         1600u   /* >= 1441 B lookahead kept on a refill */

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
    uint8_t  frame_sync_cnt;  /* ++ per decoded MPEG frame                     */
    uint8_t  frame_idle_cnt;  /* ++ per decode attempt that yielded no frame   */

    /* ---- the option-(c) consumption credit ---- */
    uint32_t cons_bytes;      /* cumulative stream bytes pulled; low 16 go out */

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

/* Collapse the ring to empty-relative-to-the-fabric: park our writer one beat
 * ahead of where the fabric has read to, so nothing already-decoded replays.
 * Returns the number of beats dropped. */
uint32_t s573_core_ring_collapse(s573_core_t *c);

/* The honest song-end test: the descrambled window is exhausted AND the decoded
 * tail has drained. The enable bits are a START gate only - ddrsbm asserts
 * fpga_ctrl[14:13] once and never clears them
 * (docs/2026-07-31-mp3-audio-WORKING.md). */
int      s573_core_window_exhausted(const s573_core_t *c);
int      s573_core_should_stop(const s573_core_t *c);

/* May we decode another frame? STRICTLY a free-space test - never a timer.
 * (transport-design prerequisite 4: the MP3_UNPACED flood relocated to C is
 * exactly the failure mode this guards.) */
int      s573_core_may_decode(const s573_core_t *c);

/* Top up in_buf from the DIO window, compacting what minimp3 has not consumed.
 * `dio` points at the mmap of S573_DIO_PHYS. Returns bytes added. */
uint32_t s573_core_refill(s573_core_t *c, const uint8_t *dio);

/* The 16-bit words to send in the down direction. */
uint16_t s573_core_ctrl_word1(const s573_core_t *c);   /* {sync, idle}         */
uint16_t s573_core_cons_word(const s573_core_t *c);    /* cons_bytes low 16    */

#ifdef __cplusplus
}
#endif
#endif /* S573MP3_CORE_H */
