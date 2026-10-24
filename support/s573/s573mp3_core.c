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
    c->cons_bytes   = 0;
    c->pulled_bytes = 0;
    c->rst_ack      = rst_epoch;
    c->ptrs_thawed = 1;                /* our view; the fabric thaws next poll */
    s573_core_pq_reset(c);
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
    /* A re-arm can also carry the SAME window: MAME update_mp3_decode_state()
     * re-inits (cur <- start) on ANY setup-register write, whatever the value,
     * and k573dio.v pulses reload (epoch +1 per write) the same way. A song
     * select restarting its preview rewrites the identical start/end/keys. The
     * epoch tells the two apart: an enable-only change is exactly one write to
     * 0xae (+1); a setup sequence is at least two writes (start hi+lo), so an
     * epoch that moved by more than one, or that moved with the enables
     * unchanged, carries a setup write. (2026-09-28, previews playing once.) */
    if (c->have_cfg && !rearmed) {
        uint16_t delta = (uint16_t)(authoritative_epoch - c->cfg_epoch);
        int en_now  = (cfg->flags & (S573_CFG_CTRL13 | S573_CFG_CTRL14));
        int en_prev = c->flags_prev & (S573_CFG_CTRL13 | S573_CFG_CTRL14);
        if (delta > 1 || (delta == 1 && en_now == en_prev)) rearmed = 1;
    }
    c->flags_prev = cfg->flags;

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
        c->tail_spent = 0;
        c->wp_lifted  = 0;          /* the watermark is trusted afresh for this window */
        c->wp_seen_at = c->now_us;  /* ... and its stale clock starts now */
        /* decoded audio that never played is discarded with the ring, so its
         * queue entries must go too or they would credit the NEW song */
        s573_core_pq_reset(c);
        /* Resetting the credit is safe: s573_mp3_credit rebaselines on the same
         * epoch change (it watches k573dio directly, not our report), so our
         * first post-change report is adopted with ZERO credit released. */
        /* The fabric credit (s573_mp3_credit.v) rebaselines on the epoch change
         * by ADOPTING THE FIRST REPORT THAT DIFFERS from the last one, with zero
         * credit. If our restarted count (0) equals the word it last saw -- a
         * re-arm while nothing had played yet, e.g. the second re-arm of a
         * song-select stop+start pair -- it adopts the first REAL count instead
         * and those bytes are never credited: cur parks short of mp3_end, bit 12
         * never clears, the preview never restarts (2026-09-28c log: previews 2
         * and 3 looped never, preview 1 once). So offset the reported word by
         * one past the last one sent; the deltas the fabric sums are unchanged. */
        c->cons_ofs     = (uint16_t)(s573_core_cons_word(c) + 1);
        c->cons_bytes   = 0;
        c->pulled_bytes = 0;
#ifndef S573_MUT_APPLY_NOFLUSH
        /* Gated on the drain state BEFORE this adoption. When it was already
         * off, the fabric reader parked seconds ago and collapsing now is safe.
         * When it was on, defer -- and SAY so, rather than failing silently.
         * The first implementation of this deferred unconditionally and measured
         * INERT: ddrsbm delivers the new window and stream_en=1 in ONE adoption,
         * so the deferral cancelled the intent every single time. */
        /* FLUSH_DEFER means "the reader is live": the caller must stop the
         * fabric first and collapse behind where it actually stopped. Neither
         * waiting (left the whole old tail playing) nor a fixed 1024-beat gap
         * (a poll stall let the reader overtake it; the elastic buffer kept
         * 11.6 ms of the old song with no stop edge) was correct -- 2026-09-27. */
        act |= S573_ACT_FLUSH;
        if (drain_before) act |= S573_ACT_FLUSH_DEFER;
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
        /* belt and braces: a resume without a re-arm gets a fresh tail verdict
         * too, so a stale one can never end the song the moment it restarts */
        c->tail_spent = 0;
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

uint32_t s573_core_ring_collapse(s573_core_t *c, uint32_t gap)
{
    uint32_t dropped = s573_core_pcm_used(c);
    s573_core_pq_reset(c);
    /* Park ONE BEAT AHEAD of the fabric's read pointer, not ON it. If the reader
     * is mid-4-phase on the beat at our snapshot it will complete and increment
     * once more; had we written wr == rd, that increment would make
     * (wr - rd) read 0xFFFF and the reader would replay the entire ring twice.
     * wr == rd+1 lands on empty in both cases. */
    c->pcm_wr = (uint16_t)((c->pcm_rd + gap) & S573_PCM_PTR_MASK);
    c->flushes++;
    c->beats_dropped += dropped;
    return dropped;
}

int s573_core_window_exhausted(const s573_core_t *c)
{
    return c->have_cfg && (c->desc.cur >= c->desc.mp3_end);
}

void s573_core_song_end(s573_core_t *c)
{
    /* The fabric's stream position `cur` (k573_mp3stream) advances only on the
     * consumption credit we report, and 0xae bit 12 ("still streaming", MAME
     * get_fpga_ctrl: cur < end) clears only when cur reaches mp3_end. The
     * credit follows PLAYED audio, and a window never ends on a frame boundary:
     * the undecodable tail (185-368 bytes in every logged exhaustion) was never
     * credited, cur parked short of mp3_end, bit 12 stayed 1 and the game never
     * saw its preview end -- so it never restarted it. MAME's update_stream()
     * walks mp3_cur_addr to mp3_cur_end_addr regardless of what the decoder
     * makes of the bytes; credit the remainder now that the audio has drained. */
    uint32_t len = c->win_end - c->win_start;
    if (c->have_cfg && c->win_end > c->win_start && c->cons_bytes < len)
        c->cons_bytes = len;
}

int s573_core_should_stop(const s573_core_t *c)
{
    /* The honest end: the descrambled window is spent AND the decoded tail has
     * drained, so the song plays out rather than being cut mid-phrase. `cur`
     * landing exactly on mp3_end is the clean-termination signature. */
    if (!(c->ctrl_flags & S573_CTRL_DRAIN_EN)) return 0;
    if (!s573_core_window_exhausted(c))        return 0;
    /* Undecoded bytes hold the stop -- UNLESS they are the truncated final
     * frame the decoder has already refused (see tail_spent). Requiring
     * in_pos == in_len outright is what made this test unreachable on real
     * windows, which do not end on a frame boundary. */
#ifdef S573_MUT_TAIL_STRICT
    /* the 2026-09-14 bug: a real window does not end on a frame boundary, so
     * this can never come true and the song can never end by itself. */
    if (c->in_pos < c->in_len)                   return 0;
#else
    if (c->in_pos < c->in_len && !c->tail_spent) return 0;
#endif
    return s573_core_pcm_empty(c);
}

void s573_core_mark_tail_spent(s573_core_t *c)
{
    /* Guarded on exhaustion: mid-song the same "no sync" break means the bytes
     * are not LOADED yet (the game streams a song in while it plays), and
     * ending the song there would cut it off at the first loader hiccup. */
    if (s573_core_window_exhausted(c)) c->tail_spent = 1;
}

int s573_core_may_decode(const s573_core_t *c)
{
    /* STRICTLY free space. Never elapsed time -- "top up the buffer each poll"
     * is the MP3_UNPACED flood relocated into C, with no sim oracle to catch it.
     */
    return s573_core_pcm_free(c) >= S573_FRAME_BEATS;
}

void s573_core_set_write_ptr(s573_core_t *c, uint32_t wp, int valid, uint32_t now_us)
{
    if (wp != c->wp || !c->wp_valid) c->wp_seen_at = now_us;
    c->wp       = wp;
    c->wp_valid = (uint8_t)(valid ? 1 : 0);
    c->now_us   = now_us;
}

uint32_t s573_core_loaded_limit(const s573_core_t *c)
{
    uint32_t lim;
#ifdef S573_MUT_NO_WP_GATE
    return c->desc.mp3_end;              /* the pre-2026-09-28 behaviour */
#endif
    if (!c->wp_valid || c->wp_lifted) return c->desc.mp3_end;
    if (c->wp < c->desc.mp3_start) return c->desc.mp3_end;
    /* at (or past) the end: the whole window has been written. The pointer of a
     * fully streamed window rests at mp3_end - 1 (the odd last byte), hence -2. */
    if (c->wp + 2u >= c->desc.mp3_end) return c->desc.mp3_end;
    /* the game writes whole 2 KB sectors, one pointer write each (24/s on
     * ddr3mj); only COMPLETE sectors below the pointer are certainly there --
     * the pointer moves with every posted 0xb4 write, ahead of the DDR3 drain */
    lim = c->wp & ~0x7FFu;
    if (lim < c->desc.mp3_start) lim = c->desc.mp3_start;
    return lim;
}

#ifdef S573_MUT_KEEP_TAIL
static uint32_t mut_snap_in_len;
#endif

uint32_t s573_core_refill(s573_core_t *c, const uint8_t *dio)
{
    uint32_t keep, room, got, lim;

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

    /* THE DEMAND MODEL. Never pull further ahead of the speakers than the ring
     * can hold. Without this, a stretch the decoder cannot sync to costs the
     * whole window: each failed decode pulled more, and the stream ran off the
     * end while the game was still waiting to hear the first bar. */
    /* lead = pulled - played. A rewind cycle over garbage can leave the credit
     * ahead of the pull (2026-09-29 log: lead=4294964858, stalls climbing,
     * every pull refused for the rest of the window); a negative lead is zero
     * lead, never a 4 GB one. */
    {
        uint32_t lead = (c->pulled_bytes >= c->cons_bytes) ? c->pulled_bytes - c->cons_bytes : 0u;
        if (lead >= S573_PULL_LEAD_MAX) {
            c->pull_stalls++;
            return 0;
        }
        if (room > S573_PULL_LEAD_MAX - lead)
            room = S573_PULL_LEAD_MAX - lead;
    }

    /* THE LOADER WATERMARK: never pull DRAM the game has not written yet (see
     * s573mp3_core.h). One descrambled byte per DRAM byte (the last word's low
     * byte is the only exception, and it sits at mp3_end), so the byte distance
     * to the watermark bounds the pull directly. */
    lim = s573_core_loaded_limit(c);
    {
        /* bytes the descrambler can still emit from DRAM below the watermark:
         * the words up to it, plus the low byte it is holding from a word it
         * has ALREADY read. That held byte is one byte, not a licence to read
         * on: the first cut of this gate skipped the whole check while a byte
         * was held, and at cur == lim (an odd pull count) the next pull ran
         * 2.6 KB past the loader -- the exact stall position in every ddr3mj
         * window of the 2026-09-29 log (0x3a7x = 6 sectors + one pull). */
        uint32_t loaded = (c->desc.cur < lim ? lim - c->desc.cur : 0u)
                        + (c->desc.hold_valid ? 1u : 0u);
#ifdef S573_MUT_HOLD_SKIP
        /* the 2026-09-29 bug: a held byte waived the whole watermark check */
        if (c->desc.hold_valid) loaded = room;
#endif
        if (loaded == 0) {
            if (lim < c->desc.mp3_end) {
                c->wp_holds++;
                /* a pointer that holds us but has not moved in S573_WP_STALE_US
                 * is not a loader at work -- it is where some earlier write
                 * parked (a preload title). Lift the gate for this window; a
                 * re-arm trusts it again. */
                if (!c->wp_lifted &&
                    (uint32_t)(c->now_us - c->wp_seen_at) >= S573_WP_STALE_US) {
                    c->wp_lifted = 1;
                    c->wp_lifts++;
                }
            }
            return 0;                      /* nothing certainly there (or the window is spent) */
        }
        if (room > loaded) room = loaded;
    }

#ifdef S573_MUT_KEEP_TAIL
    mut_snap_in_len = c->in_len;
#endif
    got = (uint32_t)s573_desc_pull(&c->desc, dio, c->in_buf + c->in_len, room);
    c->in_len        += got;
    c->pulled_bytes  += got;
    /* NOTE: pulling does NOT credit. The credit is paid out in
     * s573_core_advance_played(), as the audio those bytes became is actually
     * drained, so `cur` -- and therefore the game's 0xae bit12 guard and its
     * sense of song position -- tracks the speakers rather than the decoder. */
    return got;
}

void s573_core_pq_reset(s573_core_t *c)
{
    c->pq_head = c->pq_tail = 0;
    c->pq_part = 0;
    c->pq_pending_bytes = 0;
    c->rd_primed = 0;
}

void s573_core_carry_bytes(s573_core_t *c, uint32_t bytes)
{
    /* A frame minimp3 consumed but produced no audio from (an ID3 tag, a
     * skipped frame) still advances the stream position -- its bytes ride along
     * with the next frame that does produce audio, so the credit stays exact. */
    uint32_t n = c->pq_pending_bytes + bytes;
    c->pq_pending_bytes = (uint16_t)(n > 0xFFFFu ? 0xFFFFu : n);
}

void s573_core_queue_frame(s573_core_t *c, uint32_t beats, uint32_t bytes)
{
    uint8_t nxt = (uint8_t)((c->pq_tail + 1u) % S573_PQ_LEN);
    uint32_t b  = bytes + c->pq_pending_bytes;

    c->pq_pending_bytes = 0;
    if (nxt == c->pq_head) {
        /* Unreachable at the designed depth (the ring holds ~57 frames against
         * a 128-entry queue), but drop the OLDEST rather than silently writing
         * over a live entry, and let the byte credit ride forward so the
         * position stays honest even in the impossible case. */
        c->pq_pending_bytes = c->pq[c->pq_head].bytes;
        c->pq_head = (uint8_t)((c->pq_head + 1u) % S573_PQ_LEN);
    }
    c->pq[c->pq_tail].beats = (uint16_t)beats;
    c->pq[c->pq_tail].bytes = (uint16_t)(b > 0xFFFFu ? 0xFFFFu : b);
    c->pq_tail = nxt;
}

uint32_t s573_core_advance_played(s573_core_t *c, uint16_t fab_rd)
{
    uint32_t drained, done = 0;

    if (!c->rd_primed) { c->last_fab_rd = fab_rd; c->rd_primed = 1; return 0; }

    /* lag by the elastic buffer: a beat the reader took is not at the speaker
     * yet. Credit only what has had time to get there. */
    fab_rd = (uint16_t)((fab_rd - S573_ELASTIC_BEATS) & S573_PCM_PTR_MASK);
    drained = (uint32_t)((uint16_t)(fab_rd - c->last_fab_rd) & S573_PCM_PTR_MASK);
    c->last_fab_rd = fab_rd;
    if (!drained) return 0;
    if (drained > S573_PCM_BEATS) return 0;    /* pointer went backwards (a reset) */

    c->pq_part += drained;
    while (c->pq_head != c->pq_tail && c->pq_part >= c->pq[c->pq_head].beats) {
        c->pq_part -= c->pq[c->pq_head].beats;
        c->cons_bytes    += c->pq[c->pq_head].bytes;
        c->frame_sync_cnt = (uint8_t)(c->frame_sync_cnt + 1u);
        c->pq_head = (uint8_t)((c->pq_head + 1u) % S573_PQ_LEN);
        done++;
    }
    /* Beats drained with nothing queued are the collapse's parked beat, or
     * stale reads after a flush -- they must not be carried into the next
     * song's accounting. */
    if (c->pq_head == c->pq_tail) c->pq_part = 0;
    return done;
}

void s573_core_rewind_pull(s573_core_t *c, const uint8_t *dio)
{
    uint32_t unconsumed, idx;

    if (c->in_pos > c->in_len) c->in_pos = c->in_len;
    /* pulled_bytes is the stream index just past the last byte in in_buf (it
     * counts every byte the descrambler emitted since the re-arm, and every
     * rewind puts it back the same way), so the first unconsumed byte is that
     * many bytes short of it. Frames already decoded stay decoded: they are
     * queued and will play, and the seek lands right after them. */
    unconsumed = c->in_len - c->in_pos;
#ifdef S573_MUT_KEEP_TAIL
    /* the 2026-09-29 bug: undo only the newest pull and KEEP the older
     * unconsumed tail -- which, when that tail was itself fetched ahead of
     * the loader, kept its junk in the buffer for the rest of the window */
    if (c->in_pos <= mut_snap_in_len) {
        idx = c->pulled_bytes - (c->in_len - mut_snap_in_len);
        s573_desc_seek(&c->desc, dio, idx);
        c->pulled_bytes = idx;
        c->in_len       = mut_snap_in_len;
        c->rewinds++;
        return;
    }
#endif
    idx        = c->pulled_bytes - unconsumed;
    s573_desc_seek(&c->desc, dio, idx);
    c->pulled_bytes = idx;
    c->in_len       = 0;
    c->in_pos       = 0;
    c->rewinds++;
}

int s573_core_no_frame(s573_core_t *c, const uint8_t *dio)
{
    if (c->in_pos > c->in_len) c->in_pos = c->in_len;
    if (s573_core_window_exhausted(c)) {
        /* The window is spent and what is left holds no whole frame: the
         * truncated final frame (185-368 bytes in every logged exhaustion;
         * windows never end on a frame boundary). Consume it so the stop test
         * sees an empty buffer, and credit it with the next frame -- there is
         * none, so s573_core_song_end() brings cur up to mp3_end instead. */
        s573_core_carry_bytes(c, c->in_len - c->in_pos);
        c->in_pos     = c->in_len;
        c->tail_spent = 1;
        return 1;
    }
    /* Not the end: the bytes are not loaded yet (the game streams the song in
     * behind its own playback), or a frame's head whose rest the next pull
     * brings. Either way they must be READ AGAIN, not skipped: skipping a
     * frame head as junk desynchronises the stream (the "scratched CD" skip of
     * 2026-09-29, when a watermark hold left a partial frame in the buffer and
     * the old not-loaded test let it be consumed as a skip). */
    s573_core_rewind_pull(c, dio);
    return 0;
}

uint16_t s573_core_ctrl_word1(const s573_core_t *c)
{
    return (uint16_t)(((uint16_t)c->frame_sync_cnt << 8) | c->frame_idle_cnt);
}

uint16_t s573_core_cons_word(const s573_core_t *c)
{
    return (uint16_t)((c->cons_bytes + c->cons_ofs) & 0xFFFFu);
}

