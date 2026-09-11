/* -----------------------------------------------------------------------------
 * s573mp3_core.c - Konami System 573 HPS MP3 service: the portable core
 * See s573mp3_core.h for the contract and the four pre-cleared defects.
 * Released under the GNU GPL v2.
 * ---------------------------------------------------------------------------- */
#include "s573mp3_core.h"
#include <string.h>

void s573_core_init(s573_core_t *c)
{
    memset(c, 0, sizeof(*c));
    /* rst_ack starts at 0; the core-load reset pulse itself bumps rst_epoch, so
     * the first PTRS always reports a nonzero epoch and we ack it then. One poll
     * of startup latency, one code path for every reset (s573_hps_ext header). */
    c->ptrs_thawed = 0;
    s573_desc_init(&c->desc, 0, 0, 0, 0, 0, 0);
}

void s573_core_adopt_ctrl_baseline(s573_core_t *c, uint16_t word0)
{
    /* word0 up = {last_sync_cnt, last_idle_cnt}: what the FABRIC currently holds
     * as our counts. Adopting them and echoing them back in the same exchange
     * makes the delta exactly zero, so no pulses are fabricated -- correct both
     * after a core reset (where the fabric would have rebaselined anyway) and
     * after a bare Main restart (where it would NOT have). */
    c->frame_sync_cnt = (uint8_t)(word0 >> 8);
    c->frame_idle_cnt = (uint8_t)(word0 & 0xFF);
    c->ctrl_primed    = 1;
}

int s573_core_on_core_reset(s573_core_t *c, uint8_t rst_epoch)
{
    if (c->ptrs_thawed && rst_epoch == c->rst_ack)
        return 0;                      /* nothing moved */

    /* The fabric zeroed fab_rd_ptr, ctrl_flags and the counters, and it is
     * IGNORING our pointer words until hps_rst_ack matches. Re-baseline our
     * whole writer side; the ack goes out in this same exchange and the pointer
     * leg thaws on the next one. */
    c->pcm_wr      = 0;
    c->pcm_rd      = 0;
    c->ctrl_flags  = 0;
    c->have_cfg    = 0;
    c->ctrl_primed = 0;
    c->in_len      = 0;
    c->in_pos      = 0;
    c->cons_bytes  = 0;
    c->rst_ack     = rst_epoch;
    c->ptrs_thawed = 1;                /* our view; the fabric thaws next poll */
    return 1;                          /* caller: flush PCM + mp3dec_init */
}

int s573_core_apply_cfg(s573_core_t *c, const s573_cfg_t *cfg,
                        uint16_t authoritative_epoch, int drain_before)
{
    int act = 0;
    int rearmed;
    int stream_en;

    /* A re-arm is a NEW WINDOW or NEW KEYS -- not an enable edge. On a bare
     * pause/resume the buffered PCM is exactly the audio the resume continues
     * with, and dropping it would fast-forward the song by up to 1.49 s: the
     * mirror image of the bleed-through bug. MAME draws the line in the same
     * place (update_mp3_decode_state touches cur+keys, set_fpga_ctrl does not).
     * docs/2026-08-02-mp3-stale-pcm-residue.md */
    rearmed = (!c->have_cfg)
           || (cfg->mp3_start != c->win_start)
           || (cfg->mp3_end   != c->win_end)
           || (cfg->key1 != c->key1) || (cfg->key2 != c->key2)
           || (cfg->key3 != c->key3);

    /* word0's echo is cfg_epoch[7:0] BY DESIGN. Compared against the low byte of
     * the 16-bit epoch it is a torn-read detector; compared against the 16-bit
     * epoch itself it is bug 2, which past 255 can never agree again. */
    if ((uint8_t)cfg->epoch8 != (uint8_t)(authoritative_epoch & 0xFF))
        c->torn_cfg++;

    c->win_start = cfg->mp3_start;
    c->win_end   = cfg->mp3_end;
    c->key1 = cfg->key1; c->key2 = cfg->key2; c->key3 = cfg->key3;
    c->ddrsbm = (uint8_t)((cfg->flags & S573_CFG_DDRSBM) ? 1 : 0);

    s573_desc_set_window(&c->desc, cfg->mp3_start, cfg->mp3_end);
    s573_desc_set_keys(&c->desc, cfg->key1, cfg->key2, cfg->key3);
    s573_desc_set_ddrsbm(&c->desc, c->ddrsbm);

    if (rearmed) {
        s573_desc_reload(&c->desc);
        c->in_len     = 0;
        c->in_pos     = 0;
        /* Resetting the credit is safe: s573_mp3_credit rebaselines on the same
         * epoch change (it watches k573dio directly, not our report), so our
         * first post-change report is adopted with ZERO credit released. */
        c->cons_bytes = 0;
#ifndef S573_MUT_APPLY_NOFLUSH
        /* Gated on the drain state BEFORE this adoption. When it was already
         * off, the fabric reader parked seconds ago and collapsing now is safe.
         * When it was on, defer -- and SAY so, rather than failing silently.
         * The first implementation of this deferred unconditionally and measured
         * INERT: ddrsbm delivers the new window and stream_en=1 in ONE adoption,
         * so the deferral cancelled the intent every single time. */
        if (!drain_before) act |= S573_ACT_FLUSH;
        else               act |= S573_ACT_FLUSH_DEFER;
#endif
    }

    /* The enables are a START gate. ddrsbm asserts fpga_ctrl[14:13] once and
     * never clears them for a song change, so the END comes from
     * s573_core_should_stop(); but a real STOP (ctrl14 cleared, flags=000b) does
     * arrive here and must take effect. */
    stream_en = ((cfg->flags & (S573_CFG_CTRL13 | S573_CFG_CTRL14))
                  == (S573_CFG_CTRL13 | S573_CFG_CTRL14));

    if (stream_en && !(c->ctrl_flags & S573_CTRL_DRAIN_EN)) {
        c->ctrl_flags |= S573_CTRL_DRAIN_EN;
        act |= S573_ACT_DRAIN_ON;
    } else if (!stream_en && (c->ctrl_flags & S573_CTRL_DRAIN_EN)) {
        c->ctrl_flags &= (uint16_t)~S573_CTRL_DRAIN_EN;
        act |= S573_ACT_DRAIN_OFF;
    }

    c->cfg_epoch = authoritative_epoch;   /* adopt what the test compares */
    c->have_cfg  = 1;

    if (c->ddrsbm != (uint8_t)((cfg->flags & S573_CFG_DDRSBM) ? 1 : 0))
        act |= S573_ACT_SCHEME_BAD;       /* cannot happen; loud if it does */

    return act;
}

uint32_t s573_core_pcm_used(const s573_core_t *c)
{
#ifdef S573_MUT_FREE_MASK15
    /* the 2026-08-02 bug: masking the wrap MSB out of the difference. A ring
     * exactly one lap ahead then reads EMPTY instead of FULL. */
    return (uint32_t)((c->pcm_wr - c->pcm_rd) & S573_PCM_IDX_MASK);
#else
    return (uint32_t)((uint16_t)(c->pcm_wr - c->pcm_rd) & S573_PCM_PTR_MASK);
#endif
}

uint32_t s573_core_pcm_free(const s573_core_t *c)
{
    uint32_t used = s573_core_pcm_used(c);
    if (used >= S573_PCM_BEATS) return 0;   /* full, or an impossible overshoot */
    return S573_PCM_BEATS - used;
}

int s573_core_pcm_empty(const s573_core_t *c)
{
    return c->pcm_wr == c->pcm_rd;          /* the fabric's own test, full width */
}

uint32_t s573_core_pcm_byte_off(uint16_t ptr)
{
    /* The one place the wrap MSB is masked. Omitting this mask while the pointer
     * is full-width makes (S573_PCM_BYTES - off) underflow and the memcpy run
     * off the end of the 256 KiB mapping -- the companion half of bug 3. */
    return (uint32_t)(ptr & S573_PCM_IDX_MASK) * S573_BEAT_BYTES;
}

void s573_core_wrote_pcm(s573_core_t *c, uint32_t beats)
{
#ifdef S573_MUT_WROTE_MASK15
    c->pcm_wr = (uint16_t)((c->pcm_wr + beats) & S573_PCM_IDX_MASK);
#else
    c->pcm_wr = (uint16_t)((c->pcm_wr + beats) & S573_PCM_PTR_MASK);
#endif
}

uint32_t s573_core_ring_collapse(s573_core_t *c)
{
    uint32_t dropped = s573_core_pcm_used(c);
    /* Park ONE BEAT AHEAD of the fabric's read pointer, not ON it. If the reader
     * is mid-4-phase on the beat at our snapshot it will complete and increment
     * once more; had we written wr == rd, that increment would make
     * (wr - rd) read 0xFFFF and the reader would replay the entire ring twice.
     * wr == rd+1 lands on empty in both cases. */
    c->pcm_wr = (uint16_t)((c->pcm_rd + 1u) & S573_PCM_PTR_MASK);
    c->flushes++;
    c->beats_dropped += dropped;
    return dropped;
}

int s573_core_window_exhausted(const s573_core_t *c)
{
    return c->have_cfg && (c->desc.cur >= c->desc.mp3_end);
}

int s573_core_should_stop(const s573_core_t *c)
{
    /* The honest end: the descrambled window is spent AND the decoded tail has
     * drained, so the song plays out rather than being cut mid-phrase. `cur`
     * landing exactly on mp3_end is the clean-termination signature. */
    if (!(c->ctrl_flags & S573_CTRL_DRAIN_EN)) return 0;
    if (!s573_core_window_exhausted(c))        return 0;
    if (c->in_pos < c->in_len)                 return 0;   /* undecoded bytes left */
    return s573_core_pcm_empty(c);
}

int s573_core_may_decode(const s573_core_t *c)
{
    /* STRICTLY free space. Never elapsed time -- "top up the buffer each poll"
     * is the MP3_UNPACED flood relocated into C, with no sim oracle to catch it.
     */
    return s573_core_pcm_free(c) >= S573_FRAME_BEATS;
}

uint32_t s573_core_refill(s573_core_t *c, const uint8_t *dio)
{
    uint32_t keep, room, got;

    /* Defensive, and not theoretical: an in_pos past in_len would make the
     * unsigned difference below wrap and memmove ~4 GiB. The caller never does
     * that, but "the caller never does that" is how the 15-bit mask survived
     * too, and a clamp costs one compare. */
    if (c->in_pos > c->in_len) c->in_pos = c->in_len;

    /* compact: keep what minimp3 has not consumed */
    if (c->in_pos > 0) {
        keep = c->in_len - c->in_pos;
        if (keep > 0) memmove(c->in_buf, c->in_buf + c->in_pos, keep);
        c->in_len = keep;
        c->in_pos = 0;
    }

    room = S573_IN_BUF - c->in_len;
    if (room == 0) return 0;

    got = (uint32_t)s573_desc_pull(&c->desc, dio, c->in_buf + c->in_len, room);
    c->in_len    += got;
    /* The credit is cumulative stream bytes PULLED. One credit is one byte, and
     * the streamer emits the identical sequence (proven bit-exact over 45,377
     * bytes), so `cur` -- and therefore the game's 0xae bit12 start/stop guard --
     * tracks real consumption instead of free-running. */
    c->cons_bytes += got;
    return got;
}

uint16_t s573_core_ctrl_word1(const s573_core_t *c)
{
    return (uint16_t)(((uint16_t)c->frame_sync_cnt << 8) | c->frame_idle_cnt);
}

uint16_t s573_core_cons_word(const s573_core_t *c)
{
    return (uint16_t)(c->cons_bytes & 0xFFFFu);
}
