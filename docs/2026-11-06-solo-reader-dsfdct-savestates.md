# DDR Solo 2000 Start, Dreams Come True's installer, savestates out (2026-11-06)

**Branch:** `source-review`. **State:** the dsfdct cassette change is confirmed on the
SuperStation One (installer step 1); the core and firmware changes below are not yet
built.

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
