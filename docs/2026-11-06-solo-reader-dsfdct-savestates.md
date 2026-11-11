# DDR Solo 2000 Start, Dreams Come True's installer, savestates out (2026-11-06)

**Branch:** `source-review`. **State:** the dsfdct cassette change is confirmed on the
SuperStation One (installer step 1). The core and firmware changes below are built from
`db97ddd` (job 657, seed 7: 35,993 ALMs, 4,112 / 4,191 LABs = 98.1 %, 97 DSP; worst
setup slack +0.130 ns, hold +0.078 ns, all corners non-negative; seeds 3 and 5 missed
pll_hdmi setup by 0.044 / 0.188 ns) and deployed to the card on 2026-11-07
(`.rbf` md5 491def62..., `MiSTer_System573` md5 232e282a..., both read back; previous
files kept as `*.prev-20261107a`). Tested 2026-11-10 (below).

## DDR Solo 2000: no Start with the card reader fitted

**Symptom (2026-11-05):** ddrs2k reached attract but Start did nothing, even after
re-mapping the controls. It had played full credits on 2026-09-12, before the memory
card reader existed.

**Evidence:** the session log (session 13) shows OSD "573 Card Reader" = Auto fitting
the reader ("reader fitted (OSD) -- board on", "JVS sense -> 1"), and the game probing
the JVS bus at boot: `f0 d9` reset, `f1 01` set address, `10` ID -- answered by the
reader. Auto fitted the reader for every DDR control profile, Solo included. MAME fits
it only on the machines that add `KONAMI_573_MEMORY_CARD_READER` (ddr3m, ddr3mp,
ddr4ms, ddr5m configs and the sets built on them -- not ddrs2k).

**Confirmed (2026-11-06):** with "573 Card Reader" = Off, Start works and a full credit
plays.

**Fix:** Auto now follows the title. `tools/stage_573.py cfg_trailer()` sets bit 7 of
the trailer's card byte for the reader sets (the same `READER_SETS` the stager already
derives from ksys573.cpp and its test checks), and `rtl/emu.sv` `wio_osd_en` takes Auto
from that bit; with no trailer at all it keeps the old rule (DDR profiles). Older cores
read the card byte only as `!= 0`, `== 2`, `== 3`, and every reader title has card
code 1, so 0x81 means the same to them as 0x01. The reader titles must be re-staged
(or their trailers patched) for Auto to fit the reader on the new core.

## Dancing Stage featuring Dreams Come True: the installer's cassette

**Symptom:** "The correct security cassette was not found. Insert the GE887 JA / GN887
JA cassette with authentication number 0000-0002 and restart."

psx-spx games.md: dsfdct's installer asks for the cassette of a previous game that
may be upgraded (here 3rd Mix) and invalidates it. MAME's dsfdct "install" cassette
(`ge887ja_gn887ja.u1`, BAD_DUMP) is a GN887 JA cassette that has already been
installed on a board: its data holds that board's Digital I/O DS2401 ID as an
8-byte record in send order, `01 12 34 56 78 9a bc 3d`. That is MAME's own board
(k573dio `digital-id.bin`, CRC32 2b977f4d = `3d bc 9a 78 56 34 12 01`). The core's
board is serial 2 (`k573dio DS_SERIAL = CART_SERIAL + 1`), record
`01 02 00 00 00 00 00 53`, and "0000-0002" is that serial. The ZS01 blocks of every
installed ZS01 title's `.sav` hold the same record, so the core's board ID is not
changed.

The cassette's data is 8-byte records, each self-checking: header `"JAGN"` + inverted
byte sum, `82 00 01 00 00 00 00 7c` (inverted sum of the first seven), the cassette's
own DS2401 record and the machine record (DS2401 CRC-8). Re-tying the cassette means
replacing the machine record with the core's; no other checksum covers it.

**Confirmed (2026-11-06):** with the re-tied `dsfdct.cas` the installer reports
"conversion information authenticated" and asks for the GC910 JC cassette. Still to
see: the rest of the install and gameplay.

**Second try (2026-11-07, session 19, one launch, 12 OSD resets, from a blank
`.sav`).** Photos of every installer screen. The installer is a state machine across
restarts and tells the operator which cassette to fit at each restart: the GE887 JA /
GN887 JA cassette (3rd Mix label; core: *573 Cassette = Install*) or the GC910 JC
cassette (Dreams Come True label; *Game*). Screens seen: conversion-information
authentication with GE887 ("authenticated -- write 0000-0002 on the GC910 JC
cassette, fit GC910 JC and restart"), "press Test to start installing GC910 JC",
"is GC910 JC fitted?", "convert from 3rd MIX?", the flash write, "transfer complete
-- fit GE887 and restart", and, with GE887 fitted after the conversion, "start the
uninstall of GC910 JC?" -- which was answered yes once and undid the install. The run
ended at "transfer complete -- fit GE887" with *Cassette = Game* still selected, so
the authentication screen that followed failed ("fit the GE887 cassette with
authentication number 0000-0002"). Every failure seen matches the wrong cassette for
the step; none points at the core. The `.sav` from this run is kept as
`_replaced-saves/dsfdct.sav.half-installed-20261107` and a blank one put back.

Sources for reading these screens: psx-spx security-cartridges.md "XID" -- the
Digital I/O board's DS2401 serial is written to the cartridge during installation, the
`XXXX-YYYY` number is that serial, and blank labels are for the operator to write it
on; bios.md "Boot sequence" -- *573 Boot Device* is DIP switch 4: "Flash ROM" boots
the flash when it holds a valid executable and falls back to the disc otherwise, so
"Flash ROM" serves the whole procedure, while "CD-ROM" always runs the disc installer.

**Open:** X76F100 writes are kept in the core only for the launch (X76 cassettes reload
from their dumps; only ZS01 state is in the `.sav`). If dsfdct writes the board's
serial (XID) into GC910 JC during the install and checks it at every boot, a relaunch
after the install will fail; the dumped `gc910jc.u1` has XID = 0 (as do ddrs2k's and
ddr3m*'s, which play across launches). To test: finish the install in one launch, then
relaunch from the menu.

**Installed (2026-11-10, session 20: one launch, 5 OSD resets, from a blank `.sav`).**
Order that worked, as the screens asked: *Game* (GC910 JC) for the conversion and flash
write, *Install* (GE887) for the authentication, *Game* again -> attract, a credit
played; then *Auto* (Boot Device = Flash ROM, so Game) after an OSD reset -> attract.
The `.sav` holds the install (235 non-empty 64 KB blocks of the 16 MB flash). Still
open: a fresh launch -- every dsfdct boot so far was an OSD reset inside session 20,
so the X76F100 question above is not answered yet.

Same build, same night: ddrs2k with *573 Card Reader = Auto* -> "reader removed
(OSD)" at 3.6 s (trailer bit 7 clear), Start works, a credit played (session 21);
ddrextrm with Auto -> reader stays fitted, 111 card frame reads and 5 card writes
saved to the card file (session 22). Pause(Core) and Card In/Out re-mapped and working.

**Fix in the tools:** `tools/s573_stage.py remarry()` (and `tools/make_cas_pack.py`)
re-tie any install cassette that carries MAME's board ID.

## Savestates removed

Removed from `rtl/emu.sv`: `savestate_ui`, the "Savestates" button (and the dead
"Fastforward" and "Toggle Dualshock" entries) from *Define System573 buttons*, the
Alt-F1/F1 keys, the DBG_AUTOSS capture tool, the commented OSD entries and the
CONF_STR savestate DDR region (`PSX;SS3E000000:400000;` -> `PSX;;`). The J1 list
now ends `...,L3,R3,Pause(Core),Card In/Out`: those two move, so a player who had
mapped them maps them once more. Internally the old joy bit numbers are kept.

Kept: psx's `savestates` entity. It is also the PSX core's reset sequencer --
`savestates.vhd` starts its WAITPAUSE / LOAD sequence in `resetMode` on every falling
`reset_in` and resets the modules over the savestate bus -- so it can only go with a
rewrite of the PSX core's reset. Its save path was already cut (psx_patches/0034,
`save_state` / `load_state` = 0).

## Logs

`MiSTer_System573` named the previous game's save in each session's first lines:
Main keeps the index-4 path of the previous core load until the launcher mounts the
new `.sav`. The save is now noted once the CD is mounted (or after 10 s for a
flash-only title).
