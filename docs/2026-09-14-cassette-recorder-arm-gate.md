# The cassette recorder's arm gate, and why it got its own testbench

ddrusa's `ERROR 121 (3)` decodes to "the game never identified the cassette"
(`docs/2026-09-14-ddrusa-error121-decoded.md`). Every simulation of the logic
passes: 13/13 golden ZS01 wire vectors against an independent Python
transcription of MAME's `zs01.cpp`, the detector probe replayed against
`s573_seccart` across all four `io0_dir` x `D0` combinations, and the same probe
driven through the real exp1 bus. The board agrees with all of it -- `max_byte=4115`,
type 2 selected, `cs_seen=1`, `rtr_probes=1`, `rtr_edges=33`, `rtr_emit=0xb4a60002`
(the id shifted left once through a 32-bit register, i.e. correct for 33 edges).

So the logic model is right and the **stimulus** model is wrong, and the only way
to see the stimulus is to record it on hardware.

## Three wasted bitstreams, all the same mistake

| attempt | gate | why it produced nothing |
|---|---|---|
| 1 | `misc_rd && !cs_n` | the game holds CS asserted and polls that same word for coins forever, so idle reads overwrote the probe |
| 2 | `misc_rd && sec_in_rtr` | the "RTR loops until a start/stop" fix shipped in the *same* bitstream, so `in_rtr` never falls -- idle reads won again, and the capture read `0x00000000` with the read counter saturated at 255 |
| 3 | fill-once 128-entry ring | filled with 128 boot-time cassette latch writes (`scl=0` on every one, zero misc reads) long before the probe. That is the board DS2401 being bit-banged on latch D4, which the 16-bit entry format does not even record. The same commit also replaced the RST-armed frozen capture with `32'd0`, so `assembled 0x00000000` in that log is a literal, not a measurement |

Each gate looked obviously correct when written. Each cost a 25-minute Quartus
build plus a hardware session. That is a method failure, not three unlucky
hypotheses, so the fix is to the method.

## What the instrument is now

`rtl/s573_sectrace.v` -- a **module**, so `sim/tb_sectrace_arm.v` can drive it with
the measured boot traffic followed by the real detector probe and *assert that the
window opens on the probe*. The gate is now falsifiable for free.

* **Primary trigger: the RST rising edge with the cassette selected**, and it
  **re-arms**. That is the edge that starts the response-to-reset, so the window
  begins exactly where PSX.EXE's detector begins. `zs01.v`'s `dbg_rtr` counter says
  this edge fires exactly **once** in a whole run (`rtr_probes=1`), so re-arming
  cannot be flooded the way CS and `in_rtr` were -- and anything recorded before it
  is discarded, which makes a spurious early arm harmless.
* **Fallback trigger: an SCL edge with the cassette selected**, used only if RST
  never rises. The 128 captured boot entries prove this discriminates: `scl` was 0
  on every one and never moved, because the DS2401 needs no clock.
* **256 entries, not 128.** The probe alone is ~99 events: the RST write, one
  throwaway SCL cycle, then 32 x {read, SCL high, SCL low}. A 128-deep ring would
  have truncated the tail of the very thing it was built to record.
* `trace_count` bit 9 reports whether the window ever opened, and the service says
  so out loud after 30 s if it did not. A silent zero-entry trace must never again
  look like "no data".
* The **frozen first-32-reads assembly** is restored alongside it, in the original
  `4023f19` 48-bit layout (`{rtr_edges, cap_cnt, cap_bits}`) so the existing parser
  is unchanged. `cap_cnt` counts *every* read in the window, so a 33-read probe
  shows up as a count rather than as bits silently shifted out.

The ring is the primary instrument: with the correct window, the value the CPU
assembled is **reconstructed from the recorded reads** rather than captured by a
register whose window length had to be guessed in advance. The service prints that
reconstruction from the first 32 reads (not the last 32 -- the error screen keeps
polling, and a "last 32" window would be the same mistake one layer up).

## The window can move backwards

Because the window re-arms, `trace_count` can *decrease*. The incremental dump in
`s573mp3.cpp` detects that, resets its high-water mark and says `window RE-ARMED`.
Without it the service would sit behind a stale mark and print nothing at all for
the real probe -- the same silent failure, relocated into the HPS.

## What the next bitstream answers

Either the trace shows the CPU's reads interleaved with our 33 SCL edges and the
bits it took, in which case the assembled value is known exactly and the fault is
localised to a specific edge or read; or `ARMED=0`, in which case the game never
clocked the chip and the fault is upstream of the cassette entirely. Both are
conclusive. Neither depends on a guess made before the build.
