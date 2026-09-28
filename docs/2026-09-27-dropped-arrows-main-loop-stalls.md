# ddrextrm: occasional dropped arrows — Main's loop stalls, and a press-width guard

**2026-09-27.** After the i-cache fix Ricky first thought the dropped-input report (#1) had
gone with it, then saw it again: occasional, random arrows not registering in gameplay,
on two different keyboards.

## What the 573 does with a panel

`ksys573.cpp` INPUT_PORTS `ddr`: the four panels per player are plain `IP_ACTIVE_LOW`
bits of IN2 (`0x1f400008`; `gn845pwbb_read()` returns the STAGE port AND the stage
mask, which is `0xffffffff` outside the boot handshake). The game samples the register
once a frame; a mechanical closure is tens of milliseconds, so nothing is ever missed.

## What the log says about the path a MiSTer press takes

USB → Linux evdev → Main's main loop (`input_poll`) → `user_io_digital_joystick` over SPI
→ `joystick_0` → `emu.sv` → `s573_io` IN2. Main services evdev only when its loop runs.
`s573mp3` measures the loop period from inside it (`poll: loop … max=`), and in
`local/sdlog/s573mp3-20260927.log`:

| seconds | worst loop gap: median | p90 | max |
|---|---|---|---|
| video playing (272) | 25.5 ms | 81 ms | 83 ms |
| music, no video (601) | 21.8 ms | 80 ms | 145 ms |
| no music at all (1075) | 22.4 ms | 81 ms | 1.98 s |

Independent of game state and of MP3 decoding (bursts ≤ 1.9 ms). Every second something
holds Main for ~22 ms, and roughly every tenth second for ~80 ms. A tap whose press and
release both queue during such a stall is delivered as two SPI updates microseconds apart
— a pulse no 60 Hz poll sees. A press that lands mid-stall arrives up to 80 ms late,
which DDR judges as a miss; both read as "dropped" from the pad.

## Two changes

1. **`rtl/s573_press_hold.v`** (in `emu.sv` on `joy`/`joy2` bits 11:0, the JAMMA
   lines): every press is visible for ≥ 32 ms from its **edge**; the edge itself is
   combinational (no latency); a press longer than 32 ms is untouched (release not
   delayed). `sim/tb_s573_press_hold.v`: 1-clk pulse → 32 ms, long press releases at
   once, two taps 40 ms apart stay two taps, reset clears. This makes a coalesced tap
   survive; it cannot fix the latency.
2. **Firmware attribution:** the `poll:` line now carries `ours avg/max` (time inside
   `s573mp3_poll`), `before the worst gap` (our time in the call that preceded the
   worst gap) and `hb max` (the once-a-second heartbeat/profile dump block). If the
   worst gap ≫ ours, the stall is Main/kernel; if it matches `hb max`, it is our own
   logging/dumps (suspects: 16 fsynced log lines a second, FAT cluster allocation as the
   log grows — the ~80 ms every ~10 s has that shape).

## Result (2026-09-28 log, `local/sdlog/s573mp3-20260928a.log`)

Still a dropped input in the third song (the guard alone is not enough: a press that
arrives 80 ms late is a miss even if it is visible). The attribution is unambiguous:

| | median | p90 | max |
|---|---|---|---|
| worst loop gap | 24.5 ms | 82 ms | 2.03 s |
| our call before the worst gap | 24.1 ms | 82 ms | 1.69 s |
| heartbeat block | 24.1 ms | 82 ms | 1.69 s |

540 of 545 seconds: the worst gap **is** the heartbeat block. And inside it, the log:
`logf` was `_IONBF`, so `vfprintf` issued the write() calls itself against the FAT SD
card, dozens per line, *before* the timed `fflush+fsync` (which therefore always
reported 13–16 µs — nothing left to flush). The SPI dumps are microseconds.

**Fix (firmware `36f21ca4…`):** `s573_log()` now formats and queues; a logger thread
writes, fsyncs and mirrors to stdout. Main's loop never touches the SD card. Dropped
lines (queue of 64) are counted on the `poll:` line. Expect `hb max` to fall to the
SPI cost (< 1 ms) and the worst loop gap with it.

### Confirmed (2026-09-28b log, three songs, no dropped inputs reported)

| gameplay seconds (251) | before (09-28a) | after (logger thread) |
|---|---|---|
| worst Main-loop gap, median | 30.8 ms | **1.9 ms** |
| worst Main-loop gap, p90 / max | 83 ms / 83 ms | 2.3 ms / **3.0 ms** |
| heartbeat block, median | 30 ms | 1.6 ms (the SPI dumps) |

The six remaining > 20 ms gaps all fall outside gameplay with our time at 2–12 µs — Main's
own song loading (CD sector service), not this service. The logger's 64-line queue overflowed
213 times during those loads; now 256 lines and one fsync per drained burst instead of per
line (firmware `d5ece4c5…`). Song-select re-arms took the "reader stopped" path 31 times, the
"drain live" path never; underruns only at stream starts (13–152 samples = the DDR3 fetch
latency before the first beat, silence-before-audio, inaudible).

Issue #1 (dropped arrows): closed as a Main-loop stall caused by our own SD-card logging,
with the press-width guard as belt-and-braces.
