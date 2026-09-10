# First upstream claim reproduced: the GX700 POST runs on our bitstream

**Date:** 2026-09-10 · **Board:** DE10-Nano · **Bitstream:** the 2026-09-09 build
(94% ALM, timing met by 6 ps, savestate gate in) · **BIOS:** `573bios.bin` =
`700a01.22g`, crc `11812ef8`, loaded via the OSD `F0` entry.

## What the board showed

Core loaded, reset, BIOS loaded from the OSD. Screen flashed, then a blue
self-test screen:

```
REG OK  16H OK  16G OK  14H OK  14G OK  12H OK  12G OK
 9H OK   9G OK   4L OK   4P OK  10Q OK  18E OK
CDR BAD
HARDWARE ERROR ... RESET
```

## Why this matters

This is the GX700 power-on self-test, and it is **upstream's recorded frontier
reproduced on this bench** — the first claim to move out of the "claimed
upstream" tier of the evidence ledger. It establishes, in one screen:

* the R3000 executes the Konami BIOS out of real SDRAM (`REG OK` and everything
  after it);
* every RAM/ROM position the BIOS probes reads back correctly
  (`16H`…`10Q` — the work RAM, VRAM and sound RAM positions);
* **`18E OK`** — the H8/3644 I/O MCU self-test **passes**. There is no such chip
  on a DE10; that check is answered in RTL by `rtl/s573_io.v`, so this is a
  direct confirmation of that emulation rather than of a socket;
* the GPU renders text and video scans out end to end;
* and the savestate change does not break boot — the same bitstream that gates
  savestates off gets all the way here.

It also validates the whole build chain assembled this week: the `Konami_System_573.qpf`
written from scratch, `tools/build-573.ps1`, serial routing, and the BIOS staging.

## `CDR BAD` is expected, and is not a wall

The self-test is sequential and stops at the first failure. There is no CD
attached and no flash image loaded, so the CD-ROM check is the first thing that
can fail — and it does.

`rtl/emu.sv` documents the way past it. With a valid 16 MB flash image staged in
SDRAM the BIOS finds the `PS-X EXE` signature at `0x1f000024` and boots from
flash without reaching the CD path at all. The comment at `FLASH_START` records
the inverse as a past bug: flash reads wrapped past the 32 MB SDRAM module, the
signature was never seen, "the flash boot failed, and the BIOS fell through to
the CD path -> CDR BAD". That is precisely this screen, for the benign reason
that no flash image exists yet.

**Next:** build `hbbflash.bin` with `tools/pack_hyperbbc.py` from a `hyperbbc.zip`
MAME set at `dumps/mame573/hyperbbc.zip`, stage it with `hbbnvram.bin`
(`876ea.22h`), and launch `mgl/hyperbbc_console.mgl`.

## Not concluded

An earlier attempt with the `gchgchmp` game-in-BIOS variant gave a black screen,
but two things differed (a core reset, and the BIOS file) and the file turned out
to be staged in the wrong folder — so nothing is concluded about that BIOS
variant. Retest pending.
