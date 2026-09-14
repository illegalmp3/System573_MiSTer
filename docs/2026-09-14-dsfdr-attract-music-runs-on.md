# dsfdr: attract music "never stops" — the natural song end was structurally unreachable

Reported 2026-09-14 after the first dsfdr play session: *"any music that is played during
the attract phase, such as gameplay demonstration music, never stops playing until a credit
is entered and the game is started"*, clarified as **it does not loop, it just keeps running
on**. Diagnosed from `MiSTer_Data/s573mp3.log` read directly off the SD card
(archived as `s573mp3.log.pre-tailfix`, 32,811 lines, including one 589-second dsfdr session).

## What the log ruled OUT

**The MAS3507D gain mute.** This was the leading hypothesis going in: the game sets its own
output level through the I2C gain matrix and MAME treats a zero there as a mute, so a mute we
failed to apply would sound exactly like music that will not stop. It is not what happens.
Every CFG line in the session — and in `.run1`, `.run2`, `.run3` — reads
`gain=00000/00000 seen=0`. dsfdr never writes the gain matrix at all.

Confirmed structurally as well as empirically. dsfdr's MP3 driver is not in `PSX.EXE`; it is
in the 0x80010000 overlay inside `GAME.DAT` (`PS-X EXE` at file+0x60000, t_size 0xbc800).
Disassembled, its MAS3507D lane is: the boot `WRITE_MEM bank0 0x32f = 0x00030` + `RUN 0x0fcb`
pair at 0x8002c698 (the ACK-only boot gate we already model), the bit-bang primitives at
0x8002d0f0/0x8002d228, and a **volume** command — `mas_mem_write(bank1, 0x7f8, 4 words)` at
0x8002e444, fed from a 104-entry dB table at 0x800a2990 ending `af3cd a5621 9a537 8deb8
80000 …` — reachable only as index 11 of the dispatch table at 0x800a2928. The command
exists; the game simply never issues it in an attract session.

**A missed stop command.** The service is not sleeping through the game's stops. There are
40+ `DRAIN OFF via ENABLES` events, several cutting a window after ~1 second (song-select
preview scrolling). `fpga_ctrl` bit 14 clears are seen and honoured.

## What the log showed

**`DRAIN OFF via EXHAUSTION` appears exactly zero times in 32,811 lines** — including for
windows that demonstrably played to their end (3,200,606 B in 100 s, 3,008,346 B in 99 s,
which at the 256 kbps these `D00nn.DAT` files actually are is 0.99× real time).

The gate is in `s573_core_should_stop()`:

```c
if (c->in_pos < c->in_len)  return 0;   /* undecoded bytes left */
```

A window ends where the *game* says it ends, not on an MP3 frame boundary. When
`s573_desc_pull()` parks on `cur >= mp3_end`, the input buffer still holds a **truncated final
frame**, and no more bytes can ever be pulled to complete it. `mp3dec_decode_frame()` returns
`frame_bytes == 0` on it forever, `decode_some()` breaks at "no MPEG sync found" without
advancing `in_pos`, and the condition above is therefore **permanently false**. The log shows
the residue plainly and constantly: `in=836/1505`, `in=0/668`, `in=1672/2340`.

So on this build the *only* thing that could ever stop audio was the game explicitly clearing
bit 14. Any screen that ends a demo without clearing it leaves the stream running on — which
is exactly the report, including "it does not loop": nothing restarts, the window simply
plays out to its end and then the next `DRAIN ON` takes over.

The unit test that should have caught this was complicit. `GROUP("should_stop needs
exhaustion AND a drained tail")` sets `c.in_pos = 10` by hand, and `GROUP("pulling a whole
window really does reach exhaustion")` pulls with `c.in_pos = c.in_len; /* pretend the
decoder ate it all */`. Both pretend away the one thing that is never true on real audio.

## The fix

A new core flag, `tail_spent`, set by the caller when the decoder has been offered what is
left **with the window already exhausted** and made no progress on it. `should_stop()` then
reads:

```c
if (c->in_pos < c->in_len && !c->tail_spent) return 0;
```

`s573_core_mark_tail_spent()` is guarded on `s573_core_window_exhausted()`, which is what
keeps the fix from becoming a worse bug: the identical "no MPEG sync found" break fires
mid-song when the game's loader has not written the bytes yet (hardware 2026-09-12, the BIOS
POST fill read 48 KB into a window), and ending a song there would cut it off at the first
loader hiccup. Mid-song the mark is a no-op. The flag is cleared on a re-arm and on every
`DRAIN ON`, so a verdict can never survive into the next window.

Two new host-test groups, both driving real pulls rather than poking `in_pos`:
T16 "the truncated final frame must not hold the song open" and T17 "a mid-song sync loss
must NEVER end the song". 20 groups, 0 failures. New mutation `S573_MUT_TAIL_STRICT` restores
the old gate and the suite goes **RED** under it, so the coverage is real:

```
S573_MUT_WROTE_MASK15: RED   S573_MUT_FREE_MASK15: RED
S573_MUT_APPLY_NOFLUSH: RED  S573_MUT_TAIL_STRICT: RED     MUTATION CHECK: PASS
```

Rebuilt with the pinned gcc-arm-10.2 toolchain, ABI gate passed (GLIBC_2.28, same floor as
the board's own binary), deployed to `MiSTer_Data/MiSTer` (`e03a234f…`; stock still at
`MiSTer.orig`). **No FPGA rebuild is involved.**

## Still open: the core runs slower than real time

Separate from the above and not fixed by it. The MP3 lane measures 0.99× real time
(`cons` advances 31,765 B/s against 32,000 B/s for a 256 kbps stream), while the video is
in slow motion on every title and the intro's audio finishes before its picture. Audio at
real time against a stretched game clock means every stop the game *does* issue lands late
in wall-clock, which will still read as music running on past where it belonged. Needs the
stopwatch ratio (audio-end vs video-end on the intro) before touching MDEC/DMA/VRAM
bandwidth.
