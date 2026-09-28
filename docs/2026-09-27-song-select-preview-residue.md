# ddrextrm song select: the previous preview plays briefly on the next song

**2026-09-27.** Reported by Ricky the same day the i-cache fix landed: scrolling quickly
through Select Music, the preview of the *previously* highlighted song sometimes plays for a
moment when the next song is highlighted, then the correct preview takes over (issue #7);
pops while scrolling (#6) are the same event heard from the other side.

## What the log shows

`local/sdlog/s573mp3-20260927.log`, seconds 225–230 (the scroll): each highlight change is
two adoptions —

```
CFG epoch=32 flags=000a start=<new> ... DRAIN OFF via ENABLES          <- game stops + re-arms
PCM FLUSH (re-arm, drain live, gap 1024) -- dropped 32510 beats (1.474 s), wr=1692 rd=668
CFG epoch=35 flags=000e start=<same> ... DRAIN ON                       <- game starts the preview
```

108 of the session's 146 flushes took the "drain live" path (the reader was still playing
the old preview when the new window arrived). That path (2026-08-02 design) parked the
writer **1024 zeroed beats ahead of the read-pointer snapshot taken at the top of the
poll** and let the reader run on until the poll's closing `ctrl_exchange()` turned the drain
off. Two holes:

1. The 1024-beat margin is 46 ms. The same log has `poll: loop max=79027us` and
   `143150us`, `decode max=67951us` — a decode burst or an fsynced log line between the
   snapshot and the stop is enough for the reader to overtake the park point, after which
   `(wr - rd)` wraps and it reads the ring's 1.47 s of the *old* song as valid data.
2. When the game's stop and start fall inside one poll interval (fast scrolling), the HPS
   sees only "new window, stream still enabled": no drain 1→0 edge ever reaches the fabric,
   so `s573_mp3_pcm`'s STOP FLUSH never fires and its 512-sample (11.6 ms) elastic buffer
   plays the old preview first, then 46 ms of zeros, then the new song mid-frame — the
   blip and the pop.

MAME's rule (`k573fpga.cpp update_mp3_decode_state()` on any key/start/end write, and
`set_fpga_ctrl()` on any enable change → `mas3507d_device::reset_playback()`, which zeroes
the decoder's input *and* its decoded `samples`) is that a re-arm discards every
decoded-but-unplayed sample at that instant.

## The fix (firmware only, `support/s573/s573mp3.cpp`)

On a re-arm with the reader live: push `DRAIN_EN=0` to the fabric **first** (the 1→0 edge
gates `s573_pcm_ring` and empties `s573_mp3_pcm`), poll `CMD_573_PTRS` until the read
pointer reads the same twice (the one in-flight beat), collapse the writer to **that**
pointer + 1, reset minimp3, and restore the config's drain state so the poll's closing
`ctrl_exchange()` re-raises it *after* `decode_some()` has prefilled — the same 0→1 start a
fresh song takes. No snapshot race, no 46 ms hole, no elastic-buffer residue. Cost: 2–9 SPI
exchanges. Log line: `PCM FLUSH (re-arm, reader stopped, gap 1)`.

Host tests 20/20 + 4 mutations RED (unchanged core lib); firmware `out/deploy-20260927/MiSTer`
md5 `ac92e1e41b6fa03273e071f3fcfc1161`, deployed to `E:\MiSTer` (previous kept as
`MiSTer.prev-20260927a`).

## Also seen in this log, not fixed here

Mid-song underruns with a FULL ring: +492 samples (11 ms) at second 453 and +825 (19 ms) at
571, both `ctrl=0002 free≈400`. The DDR3 read path did not deliver a beat for longer than
the 512-sample elastic buffer covers — arbitration against the (now faster) PSX side. Two
events in ~270 s of gameplay; if audible as a dropout, the lever is `s573_mp3_pcm` `AW`
(512→1024 samples) or DIO read priority in `s573_ddram_arb`. Watch item.
