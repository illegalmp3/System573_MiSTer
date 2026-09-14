# ddrusa ERROR 185 (120): the installer tries to flash the CR-589's firmware

**Date:** 2026-09-14 (same day the ZS01 fix cleared ERROR 121 on hardware)
**Screen:** `CD-ROM BAD` (installer status line) / `ERROR 185 / CD-ROM drive version
update failed. (120) / Please call a dealer near you.`
**Status:** decoded from PSX.EXE; one-constant fix in `rtl/atapi.v`; sim-validated.

## The decode

* Message table entry 185 (`0x803409c8`) -> the string at `0x8033ea54`. One raise site:
  `0x80314348`, inside the update task's display handler, reached when the task state
  word (`0x803f96c0`) is 4; `(120)` is the sub-code stored at `0x803f96c8`.
* The update routine (`0x80314374`) sets state 4 / sub-code **120** when its FIRST step
  returns negative: `0x8031fba8` = ATAPI **`0xCC` FIRMWARE DOWNLOAD ENABLE**, 28 bytes
  DATA-OUT (the drive's current identity echoed back). `atapi.v` has no `0xCC`.
* The full sequence (all from the disassembly, matched against MAME `bus/ata/cr589.cpp`):
  `0xCC`(enter download) -> INQUIRY (must say `MATSHITA CD98Q4 DOWNLOAD`, else 131) ->
  **WRITE BUFFER `0x3b` mode 5** of the 52,086-byte firmware image embedded at
  `0x8034ada0` (length word `0x80357918`) -> **READ BUFFER `0x3c`** of len-32 ->
  memcmp(image+32, readback) (161) -> `0xCC`(exit) -> INQUIRY -> verify vendor/product
  and **revision == "gscb"** (`0x80300894`; 181 on mismatch).
* The firmware image's own embedded identity (body+0x3ab, exactly where MAME's
  `identity_offset` lives) is `MATSHITACD-ROM CR-589   gscb`. So **gscb is what the
  drive reports after a successful factory flash**.

## Why "report gscb" is the right fix, not "emulate the flash"

`drive_identify` (`0x80314774`) walks the table at `0x80340be4` -- `GS0N`, `kona`,
`GSCA` -- and returns -1 for any other revision. Those are the revisions the installer
knows how to upgrade FROM. The task init (`0x80313f2c`) launches the flash routine only
on 0; on -1 it returns without starting it. `run_task` (`0x80300fbc`) exits on init<0.
The caller (`0x8030b5cc`) never examines the result. Boot continues.

That is the path every deployed ddrusa cabinet takes on every power-up: the drive was
flashed once at install and reports `gscb` forever after. Reporting the stock `GS0N`
(MAME `cr589.cpp` `nvram_default`) modelled a factory-fresh drive and made the
installer attempt the flash, which the core cannot service. Reporting `gscb` models the
steady state. No `0xCC`/`0x3b`/`0x3c`, no 64 KB buffer, no NVRAM.

* There is NO pre-update revision gate other than this table: the only reference to
  `gscb` is the post-flash verify; the only reference to the image is inside the flash
  routine. Reporting the DOWNLOAD identity would NOT help -- it sets a flag that skips
  only the "enter download mode" step and proceeds straight to WRITE BUFFER.
* `GAME.DAT` carries the same program (+0x24) plus a second module that also references
  `gscb` -- consistent with the flash-resident game expecting the updated drive.
* dsfdr's installer (PSX.EXE from 936eaa.chd, MODE1/2048) contains **no** CR-589
  identity strings, no revision table and no update flow; its ERROR 184 was purely the
  INQUIRY transfer length. It is unaffected by the revision bytes.

## Caveat for future titles

Another 573 title could list `gscb` among ITS upgrade-from revisions and target something
newer; it would then hit 185 the same way. If that happens the reported revision should
become a per-title launcher setting (like the cassette type). For now one constant.

## Files

`rtl/atapi.v` INQUIRY bytes 32..35: `"GS0N"` -> `"gscb"` (comment rewritten; the old
comment placed the revision table in dsfdr's EXE -- it is ddrusa's).
`sim/tb_atapi_inquiry.v`: revision expectations -> `gscb`.
Tooling: `~/work/chdread.py` (CHD v4 zlib reader, now handles cooked MODE1/2048),
`iso_extract.py`, `mipsdis.py` (MIPS-I disassembler) -- the same kit that decoded 121.
