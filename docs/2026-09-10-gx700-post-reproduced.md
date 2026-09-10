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

---

## Resolved: the gchgchmp variant is not a game-in-BIOS (2026-09-10)

The retest was run properly — same procedure as the successful standard-BIOS run,
only the BIOS file different, with the file staged in the right folder this time.
Result: **a byte-identical self-test screen, ending in `CDR BAD`.**

The MAME driver explains why, and `dumps/README.md` was wrong:

```
ROM_SYSTEM_BIOS( 1, "gchgchmp", "Found on Gacha Gachamp" )
```

`700a01(gchgchmp).22g` is a BIOS **revision**, not a BIOS containing a game.
MAME's `gchgchmp` (Gacha Gachamp, GE877) requires eight onboard flash ROMs
(`710ja.*`), **eight PCMCIA card ROMs** — a 16 MB PC card — and a
security-cassette EEPROM (`ge877jaa.u1`). It is among the *harder* targets on this
board. There was never a built-in game to reach, so the identical `CDR BAD` was
the only possible outcome.

`dumps/README.md` is corrected and `mgl/gchgchmp_console.mgl` is retitled as what
it actually is: a one-file BIOS POST smoke test.

## hyperbbc flash image built and pre-flight checked

`tools/pack_hyperbbc.py` ran against a fully non-merged `hyperbbc.zip`. All nine
inputs CRC-match MAME:

```
876ea.31m a76043cb   876ea.27m 689ddd94   876ea.31l d011c7a5   876ea.27l 950a5267
876ea.31j ae497ebc   876ea.27j 9c156b1b   876ea.31h 368372fb   876ea.27h 49175f99
876ea.22h 8e11d196  (M48T58 NVRAM)
```

Output: `dumps/hyperbbc/flash16m.bin` (16 MB, 0.1% blank) and `nvram8k.bin`.

**The check that predicts whether it boots.** `emu.sv`'s `FLASH_START` comment
records that the BIOS reads a flash-boot signature at `0x1f000024` and that a past
bug made it miss `PS-X EXE` there, falling through to the CD path and giving
`CDR BAD`. In the packed image:

```
0x00 : "GQ876\0\0\0" 0x19 0x98 "JAA\0\0\0"
0x24 : "PS-X EXE"
```

The signature is at exactly `0x24`, and the image opens with the game's own code
(`GQ876`, 1998, JAA). Both confirm the byte-lane interleave and the m/l/j/h bank
order are right — the two things the packer could plausibly have got wrong.

Staged as `local/sd-stage/games/System573/hbbflash.bin` and `hbbnvram.bin`.
