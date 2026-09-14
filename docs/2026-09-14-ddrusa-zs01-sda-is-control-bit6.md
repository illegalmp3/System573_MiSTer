# ddrusa ROOT CAUSE: ZS01 SDA is CONTROL bit 6 alone -- D0 is not wired to the chip

**Date:** 2026-09-14
**Symptom:** `ERROR 121 / Cassette error. (3) / Cassette does not match this game (G*A44UAA)`
**Status:** ROOT-CAUSED from the game's own machine code. One-line RTL fix applied.

## The fix

`rtl/s573_seccart.v`:

```verilog
-    wire zs01_sda_i = d_q[0] & ~io0_dir;   // open-drain: low if EITHER driver pulls low
+    wire zs01_sda_i = ~io0_dir;            // CONTROL bit 6, active-low. D0 NOT wired.
```

## How this was established (no guessing, no bitstream)

`PSX.EXE` was extracted directly from the ddrusa disc and disassembled:

* `dumps/mame573/a44uaa02.chd` is a CHD **v4**, compression 2 (zlib), 9792-byte hunks
  = 4 x 2448-byte CD frames. A ~60-line pure-Python reader (stdlib `zlib` only) walks
  the hunk map, and the ISO9660 PVD at LBA 16 validates the frame mapping.
* `/PSX.EXE` : LBA 8216, 368,640 bytes, magic `PS-X EXE`, `t_addr=0x80300000`
  (matches `docs/2026-09-14-ddrusa-error121-decoded.md` exactly).

The installer carries **two separate cassette drivers**:

| region | driver | how it drives SDA |
|---|---|---|
| `0x80323800-0x80324300` | **X76** (detector B at `0x80323fb4`) | data bit on **latch D0** (`andi latch,0xfffe; or data; sh 0x1f6a0000`) -- 10 such sites. Control bit 6 is only the IO0 output ENABLE (`0x803208c8(1)` to drive, `andi 0xffbf` at `0x80323cd4` to release before a read). |
| `0x80325000-0x80326200` | **ZS01** (detector A at `0x803250b8`) | **CONTROL bit 6 only**, via the setter `0x803208f4`. A scan of the whole region finds **zero** D0 manipulations: the only two `0x0001` immediates are detector A building the compare constant `0x5a530001` (`0x80325224`) and a stack-built command byte (`0x803253ac`). |

The control-bit-6 setters are unambiguous:

```
803208c8/803208f4:  andi $a0,$a0,1 ; sll $a0,$a0,6 ; andi $v0,$v0,0xffbf
                    or $v0,$v0,$a0 ; sh $v0,0(0x1f500000)
```

and the ZS01 STOP generator at `0x80325f9c` is built purely from it:
`0x803208f4(1)` (SDA low) -> latch `ori 0x0002` (SCL high) -> `0x803208f4(0)` (SDA high).
Detector A calls `0x803208f4(0)` before the response-to-reset to RELEASE SDA.

This is exactly MAME `k573cass.cpp`: `konami573_cassette_zi_device` overrides
`write_line_d1/d2/d3/d4` and `write_line_zs01_sda`, but **not** `write_line_d0` --
the base `konami573_cassette_interface::write_line_d0` is an empty method. And
`ksys573.cpp` wires OUT2 (`control_w`) bit `0x40` `IP_ACTIVE_LOW` to
`write_line_zs01_sda`, hence `sda = ~io0_dir`.

## Why it presented as "cassette does not match"

The ZS01 driver never sets D0, so `d_q[0]` stays 0 and `d_q[0] & ~io0_dir` pinned the
chip's SDA input **LOW forever**. Consequences, each matching the measured fabric:

* The response-to-reset still worked -- it only *drives* `sda_o` and never reads
  `sda_i`. Hence `cs_seen=1, rtr_probes=1, rtr_edges=33, rtr_emit=0xb4a60002`.
* But a START (SDA 1->0 while SCL high) can never be seen if SDA is always 0, so the
  packet phase was dead: `i2c_starts=0, pkts=0`.
* So detection SUCCEEDED (type 3) and the **ZS01 verify** failed -> verifier returns
  **-10**, which maps to displayed sub-code **(3)** -- the same digit as the -2
  "never identified" case. `docs/2026-09-14-ddrusa-error121-decoded.md` read the (3)
  as -2; the fabric counters show it was -10.

## What was NOT wrong (both proven in simulation first)

* **The cipher.** An independent line-for-line Python port of MAME `zs01.cpp` agrees
  with `tools/zs01_ref.py` primitive-for-primitive over 500 random vectors each for
  decrypt/decrypt2/encrypt/calc_crc, reproduces all 13 committed ddrusa golden
  vectors byte-for-byte, and a READ of address 0 decodes to `47 4b 41 34 34` = "GKA44".
* **The response-to-reset emission.** Modelling `zs01.v`'s ST_RTR against a faithful
  port of MAME's `write_scl` shows the core presents all 32 id bits identically to
  MAME (both assemble `0x5a530001`) and reproduces the hardware's `rtr_edges=33` /
  `rtr_emit=0xb4a60002` exactly. The detector reads SDA **while SCL is low**
  (`lhu $v1,6($s7)` at `0x803251a0`, *before* driving SCL high) after a priming
  SCL cycle -- 33 falling edges, 32 reads. `tb_zs01_rtr.v` already models this phase.

The one remaining core/MAME divergence is cosmetic for detection: MAME PARKS idle-high
after the 4 id bytes (`m_sdar=1; m_state=STATE_STOP`), `zs01.v` LOOPS. A 33-edge
detector never reaches it, but it should be reverted to match.

## Bench changes

`sim/tb_s573_seccart.v` Part 3's master drove the ZS01 command bits on `dl3[0]` (D0)
with `io0_3` held released -- the same wrong assumption as the RTL, which is why it
passed. Its `z_sda/z_start/z_stop/z_send/z_read` now drive SDA on `io0_3`
(`io0_3=1` -> SDA low, `io0_3=0` -> released), as the game does.

## Addendum: Part 3 had never run, and its expectations were wrong

Once `dumps/mame573/gtrfrk5m.zip` was supplied and `sim/gen_secdata.sh` produced the
fixture, `tb_s573_seccart` Part 3 executed for the first time. Its three hardcoded
expectations did not match the real dump -- they were shifted by one 8-byte slot
(the game code "GEA26" was expected in the *config* slot; in MAME's `nvram_read`
layout it is data addr 0, `image[28:36]`, which is where the dump has it). Had the
test ever run, it would have failed at once and this path would have been examined
months earlier. The silent skip cost more than the wiring bug.

Fixes: `z_eep` is pre-zeroed (the generator emits the raw 140 B image); a missing
fixture now counts as a FAILURE; and the addr0/addr1/config expectations are derived
from the loaded image via the documented layout (config with `CONFIG_RC`=0, as MAME
zeroes it on every good-CRC command), not hand-typed. With that, Part 3 passes:
RtR, four authenticated reads and the wrong-key negative control.

`sim/tb_zs01_cmd.v` (ddrusa dump, 13 golden ciphertext vectors through
`s573_seccart`, D0 held low) is the regression test for the wiring bug itself: it
FAILS on the old expression with `i2c_starts=0, packets=0` -- the hardware's exact
fabric counters -- and PASSES on the fix.

## Also in this build: response-to-reset now PARKS like MAME

`rtl/zs01.v` ST_RTR: after the 4th id byte the chip drives SDA idle-high and goes to
ST_STOP (`m_sdar = 1; m_state = STATE_STOP` in zs01.cpp), instead of looping the four
bytes. Modelled against a port of MAME's `write_scl` the core is now bit-identical over
40 host reads including the idle tail (previously diverged from sample 33). The real
detector (33 falling edges, 32 reads) sees the same bits either way; `rtr_edges` now
reports 32 rather than 33 because the counter stops at the park.

`sim/tb_zs01.v` Part 2 had the same never-run, shifted-constant real-data section as
`tb_s573_seccart` Part 3; fixed identically (pre-zero, layout-derived expectations,
missing fixture = FAIL). Full suite: 55/55.
