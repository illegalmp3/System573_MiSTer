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

## Result

_(pending the next cabinet log)_
