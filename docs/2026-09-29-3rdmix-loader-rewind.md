# ddr3mj: the preview dies after half a second -- three service defects, one host reproduction

**2026-09-29.** Firmware-only (support/s573). Hardware: pending.

## The report

3rd Mix (ddr3mj and variants): every song preview plays about half a second, then
"skips like a scratched CD", then goes silent; a selected song never starts at READY
and times out to CLEARED with 0 steps. Unchanged by the loader watermark v2
(firmware ca00b84b). The 2026-09-29 `s573mp3.log` (hb=1 dump=1) holds six windows;
four died, two played through -- and the two that played were the ones whose PCM
ring happened to be empty at the re-arm.

## What the log says

Every window starts the same way (epochs 35, 46, 57, 68, 79, 90 -- start=0):

```
CFG epoch=35 ... start=00000000 end=00046353 ... DRAIN ON
decode STALL (bytes not loaded yet -- rewinding the pull) at cur=00003a80 (14976 of 287571 bytes into the window, 0 played)
```

`0x3a80` = six sectors (`0x3000`, what the game writes before it arms) plus one
pull. The watermark was supposed to hold the pull at `0x3000`. Then, in the four
dead windows:

```
rst=3 ... in=0/0 cons=19658 ... lead=4294964022 stalls=0 rewinds=260   (+200 per second, decode 0 bursts)
```

`in=0/0`, `rewinds` climbing exactly once per 5 ms poll for the rest of the window
while the loader (`dio: wp=`) marched to the end untouched. In the two live windows
`rewinds` stopped after the first one.

## The three defects (all in the service; the fabric was doing its job)

1. **The watermark had a hole for a held byte.** The descrambler emits two bytes per
   DRAM word and holds the low byte between calls. The gate was
   `if (cur >= lim && !hold_valid) hold;` -- with a byte held (an odd pull count,
   which the 4096-byte pulls produce routinely) the whole check was skipped and the
   pull ran on unbounded. That is the 2.6 KB past the loader in every window. Now the
   loaded byte count is `(lim - cur) + (hold_valid ? 1 : 0)` and the pull is bounded
   by it; a held byte is one byte.

2. **The rewind kept junk.** A pull that reached unwritten DRAM was undone by
   restoring a snapshot of the descrambler from *before that pull*, keeping the
   buffer's older unconsumed tail as "real bytes, a partial frame". When that tail had
   itself been fetched ahead of the loader (defect 1 put it there), its junk copy sat
   at the front of the buffer for the rest of the window: every retry found no frame
   across the old/new junction, rewound to the same place, and the pull count went
   *below* the credit (`lead=4294964022`). The rewind is now an exact seek
   (`s573_desc_seek`): discard everything unconsumed, put the descrambler at the first
   unconsumed byte, re-read that DRAM next poll. The key schedule is a function of the
   word index (key1 period 15, key2 a fixed number of rotations per key1 period, key3
   a counter; ddrsbm key1 period 16), so the seek is at most 30 key steps, never a
   replay of the window. The old snapshot machinery is gone.

3. **Torn frames were handed to minimp3.** Whenever the watermark (or the lead bound)
   held a pull with fewer than a whole frame in the buffer, the decoder was still
   called. minimp3 decodes a frame only when the *next* frame's header is in the
   buffer too, and when it is not it `memset`s its entire state -- bit reservoir and
   synthesis filter -- before scanning. Each hold therefore cost one frame and a click
   (the "scratched CD"), and its "no frame" verdict (`frame_bytes == avail`, never 0)
   went down the skip path when no new bytes were involved, consuming a frame head as
   junk and desynchronising the stream. Now a frame is offered only when a worst-case
   frame plus a header (`S573_DECODE_MIN` = 1445) is held, or the window is spent; a
   scan that finds nothing has its decoder state put back; and "no frame" has one
   meaning (`s573_core_no_frame`): the window's truncated tail if the window is spent
   (consumed, `tail_spent`, the song may end), otherwise a rewind -- never a skip. A
   found frame with no audio (the reservoir case) is consumed and carried, as before.

Also: the re-arm reads the write pointer **fresh** (`refresh_write_ptr()` on
`S573_ACT_FLUSH`) instead of inheriting one up to 20 ms old; 3rd Mix writes its six
sectors and arms in one burst, and a pointer from before that burst is the previous
window's resting place -- past the new window's end it reads as "fully loaded". The
CFG log line now carries `wp=`. `wp_lifts` counts a lift once.

## The reproduction (`support/s573/tests/sim_loader.c`)

The real core + descrambler + minimp3, an 18 s 128 kbps MP3 scrambled with the
epoch-35 keys into a simulated DRAM (BIOS fill or the previous preview's bytes
elsewhere), a loader that writes six sectors, arms, then one sector per 1/24 s, a
44.1 kHz drain, 5 ms polls, 20 ms pointer refreshes, and `decode_some()` kept in step
with the service. Against the ca00b84b core: **4.2 % of the samples, 200 rewinds a
second, dead at 0.75 s** -- the log's shape. Against this core: 100 % in every
scenario (fresh or stale pointer at the re-arm, fill or old-preview junk, a preload
title with the pointer past the end / inside / below the window, a window at
0x100000, a pointer never reported). `make loader MINIMP3_PATH=... MP3=...` runs it.

## The suite (`make test`, `make mutate`)

T24 `s573_desc_seek` == stepping (both schedules, odd/even, the last byte, past it,
every 7th position of a 720-byte run); T25 the held byte is one byte at the watermark;
T26 junk pulled ahead of the loader is re-read after a rewind, byte-identical to a
one-shot descramble; T27 no frame at the spent window is the truncated tail. Two new
mutations restore the defects -- `S573_MUT_HOLD_SKIP` (1) and `S573_MUT_KEEP_TAIL`
(2) -- and the suite goes RED under each. 27 groups, 7 mutations red.

## What to test on the cabinet

ddr3mj from `ddr3mj.mgl`, Boot Device = Flash ROM: song previews play in full and
loop; a selected song starts at READY and plays through. Then the same for a preload
title (ddrextrm) to confirm nothing regressed. Log: `E:\s573mp3.log` -- for each
start=0 window expect `CFG ... wp=000300x/ok`, no `decode STALL` lines, `rewinds`
flat, `dio:` `holds` rising only while the decoder waits on the loader.
