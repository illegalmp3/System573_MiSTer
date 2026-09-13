# dsem STAGE PCB: the line polarity, measured (2026-09-13, runs 5-8)

Four bitstreams with the GN845-PWB(B) model in place still stopped at
`STAGE PCB INITIALIZE ERROR`. Each round added observability instead of a
guess, and the last one recorded the wire.

## What the board said

* Run 5 (`stage:` heartbeat word): `en=1`, the game clocked the stage-0 line,
  `id_seen=0`. The edge arithmetic that seemed to show "two reply bits passed"
  was wrong: the per-frame lamp writer (GAME.DAT 0x800863a4 -> 0x80086cac)
  toggles the same CLK line as an idle heartbeat with DO=1 once the handshake
  is over, so edge counts and `sh0=0x1fff` after the fact say nothing about
  the handshake itself.
* Run 6/7: `last_mask=0xffff` -- INIT never started; the 1 Hz sample cannot see
  a handshake that lasts ~40 ms.
* Run 8: the line-event trace (gn845pwbb records the first 128 changes of the
  stage-0 DO/CLK lamp bits with 64-clk timestamps; CMD_573_STAGETRACE 0x6C
  reads them out; `sim/gn845pwbb_dsem_trace.txt` is the capture). Steps are
  ~606 ticks = ~38.8k clocks = 1.15 ms apart (the game's 0x12-tick wait on a
  ~15.6 kHz counter). Decoding DO at each edge of CLK under each polarity
  convention, exactly one gives the ID:

      DO = lamp[4] (NOT inverted), sampled on lamp[7] RISING (NOT inverted)
      -> 0,0,0,0,1,0,0,1,0,0,1,1,0 = 0x0c90 LSB-first, bit for bit.

  The first cut used MAME's `DO = !data`, `clk = !data` literally, i.e. both
  lines inverted, and clocked in the complement of every bit.

## Why the disassembly misled

GAME.DAT 0x80086974 (the stage line driver) keeps its shadow word INVERTED --
`val != 0` CLEARS the bit, `val == 0` SETS it (the `nor a0,zero,a1 / and` vs
`or` branches read the other way round at first glance) -- and then writes
`~shadow` to the DIO lamp register. Net: the lamp bit IS the logical level.
MAME's `!data` is relative to how its own k573dio output path presents the
bit; in this core's register sense no inversion belongs on either line.

## Fix

`rtl/gn845pwbb.v`: `do0 = lamp[4]`, `ck0 = lamp[7]` (and 12/15 for stage 1).
Nothing else changes: the shift direction, the 0x0c90 compare, the 22-step
mask table and the JAMMA masking were all confirmed by replaying the game's
own routine (0x800873fc / 0x80086f98) against the model in Python.

`sim/tb_gn845pwbb.v` now REPLAYS THE RECORDED BOARD WAVEFORM and requires the
ID to be recognised at trace event 34 (the 13th CLK rising edge) -- red on
the old polarity, green on this one -- alongside the synthetic handshake.

The trace stays in the design (a few flops and one M10K) and the incremental
dump stays in the service: the next standard-cab title gets the same view for
free.
