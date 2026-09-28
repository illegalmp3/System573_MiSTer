# ddrextrm: the song-select preview plays once — the game never sees the stream end

**2026-09-28.** Ricky: the preview music for each song on Select Music plays once, where it
should repeat until the "___ Stage" screen.

## What the log says

Every exhaustion in three sessions (`local/sdlog/s573mp3-2026092{7,8a,8b}.log`), from the
heartbeat right after `song end -- window exhausted`:

| window length (bytes) | credited consumption `cons=` | short by |
|---|---|---|
| 60,527 (a preview) | 60,342 | 185 |
| 1,479,319 | 1,478,952 | 367 |
| 1,504,915 | 1,504,548 | 367 |
| 1,368,155 | 1,367,787 | 368 |
| 1,568,067 | 1,567,777 | 290 |
| 3,007,929 | 3,007,639 | 290 |
| 1,367,419 / 1,307,799 / 1,192,603 | … | 367 each |

After the one preview that reached its end (09-27 epoch 702), the game issued **no MP3
register write at all** for the ~2 s until the next scroll — it never learned the preview
had ended.

## Why

The fabric streamer `k573_mp3stream` advances its position `cur` only on the consumption
credit the HPS reports (`s573_mp3_credit.v`), and `0x1f6400ae` bit 12 — MAME
`get_fpga_ctrl()`: "streaming" = enabled ∧ `cur < mp3_end` — clears only when `cur`
reaches `mp3_end`. The credit follows audio that actually PLAYED (`cons_bytes`, paid out
from the fabric's ring read pointer), and a window never ends on a frame boundary: the last
partial frame minimp3 refuses (`tail_spent`) was never credited. So `cur` parked 185–368
bytes short, bit 12 stayed 1, and the game — whose MP3 layer reads exactly that bit
(`0x800bf814` → vtable slot 8 `0x800c1250`, used by the start/stop routines at
`0x800b1238/0x800b1364/0x800b1788`) — kept believing the preview was streaming.

MAME's `update_stream()` walks `mp3_cur_addr` to `mp3_cur_end_addr` whatever the decoder
makes of the bytes; the end is a position, not a decode result.

A second gap sat behind the first: the restart. The game re-arms a preview by rewriting
the **same** start/end/keys; `k573dio.v` pulses `reload` (cur ← start, epoch +1 per write)
as MAME's `update_mp3_decode_state()` does on any setup write, but the HPS `apply_cfg`
only treated a *changed* window as a re-arm — a same-window rewrite would have been
adopted as nothing, with the descrambler still parked at the end: silence.

## Fix (firmware `df0aad09…`, `support/s573/s573mp3_core.c`)

1. `s573_core_song_end()`: when `should_stop` fires, raise `cons_bytes` to the full window
   length. The fabric releases the remaining credit, `cur` reaches `mp3_end`, bit 12 → 0.
2. `apply_cfg`: a same-window adoption is a re-arm when the epoch moved by more than one
   (a setup sequence is ≥ 2 writes: start hi+lo) or moved with the enable bits unchanged
   (not an `0xae` write). An enable-only edge (epoch +1, enables changed) stays a bare
   stop/start that keeps buffered audio, as before.

Host tests: two new groups (T21 same-window re-arm vs enable edge; T22 tail credit), 22/22
PASS, 4 mutations RED. Deployed to `E:\MiSTer`, previous kept as `MiSTer.prev-20260928c`.

## To verify on the cabinet

Select Music, stay on one song past the end of its preview: it should restart and keep
looping until the stage screen. In the log, expect `song end … EXHAUSTION` followed within a
second by `CFG epoch=N` lines carrying the same window and `PCM FLUSH (re-arm …)`.

## Second round (12:34): only the first song looped

Log `s573mp3-20260928c.log`: preview 1 (Graduation) ended, the game rewrote the same window
(epoch +7 = start hi/lo, end hi/lo, key1/2/3, enables unchanged) → re-arm → looped. Previews
2 and 3 ended with the tail credited (`cons=` = window length) and the game did nothing.

The difference: previews 2 and 3 were reached by scrolling, which is a stop + new window
(epoch N, flush) followed by the start (epoch N+3, `flags=000e`, same window) — and the new
same-window rule made that second adoption a re-arm too, resetting `cons_bytes` to 0 **while
it was already 0**. `s573_mp3_credit.v` rebaselines on an epoch change by adopting the first
report that *differs* from the last one it saw, with zero credit; a restarted count equal to
the last word is not a change, so it adopted the first real count (~418 bytes, the first
frame) as the baseline instead. Those bytes were never credited, `cur` parked that far short
of `mp3_end`, bit 12 stayed 1. Preview 1 had only one re-arm (fresh from a different window,
last word ≠ 0) and escaped.

Fix: `cons_ofs` — every re-arm offsets the reported credit word to one past the last word
sent, so the fabric always sees a change to adopt; the deltas it sums are unchanged. Test
T11 extended (re-arm with a zero count still changes the word, by exactly one, real bytes
ride on top). Firmware `5f440fe0…`.
