# System 573 core -- status

The one live status page. Last updated 2026-10-26. The page this replaced (the
2026-09-09 evidence ledger and dump hashes) is `docs/archive/STATUS-2026-09-09.md`.
Dated notes in `docs/` are the record of how each thing was found; `docs/README.md`
says which ones still describe the current tree.

## What runs

Reported from the cabinet (DE10-Nano, 128 MB SDRAM, CRT over composite/S-Video,
games on a USB SSD). "Credit" = a full credit of songs played with music.

| title | set | state | notes |
|---|---|---|---|
| Hyper Bishi Bashi Champ | hyperbbc | boots, flash-only | first flash title |
| Hyper Bishi Bashi Champ 2P | hypbbc2p | CD install works | |
| DDR Solo Bass Mix | ddrsbm | credit | first title with MP3 audio |
| DDR Solo 2000 | ddrs2k | credit | attract gameplay demo cuts off after ~2 s (open) |
| Dancing Stage Euro Mix | dsem | credit | X76F041 cassette, stage PCB handshake |
| DDR USA | ddrusa | credit | ZS01 cassette |
| Dancing Stage feat. Disney's Rave | dsfdr | credit | two cassettes |
| DDR 4th Mix | ddr4m | credit | first 32 MB PCMCIA title |
| DDR 4th Mix (J) | ddr4mj | boots from flash | songs not reported |
| DDR 4th Mix Plus | ddr4mp | boots, credit started | songs not reported |
| DDR 3rd Mix (A) | ddr3ma | installs and boots | songs not reported |
| DDR 3rd Mix (J) | ddr3mj | credit | streams songs from CD during play |
| DDR MAX | ddrmax | credit | |
| DDR MAX2 | ddrmax2 | credit | |
| DDR 5th Mix | ddr5m | runs | 60 fps confirmed |
| DDR Extreme | ddrextrm | credit | 60 fps arrows, full-speed background video |

Staged on the drive, not yet reported: ddr3mk, ddr3mka, ddr3mp, ddr4mps, ddr4ms,
ddr4msj, dsem2, dsfdct.

Opening the MiSTer OSD pauses the game AND its MP3 music, and play resumes in
sync (confirmed on the cabinet 2026-10-17, and in the 2026-10-18 log: two mid-song
pauses, the MP3 read pointer frozen for exactly the paused seconds, no underrun;
docs/2026-10-02-osd-pause-music.md).

HDMI is back (2026-10-18): one bitstream drives an HDMI TV and the S-Video/composite
CRT at the same time, confirmed on the cabinet (docs/2026-10-18-hdmi-output.md).

Out of scope for this core as it stands:
the analog-board titles (2nd Mix family, dsfdcta, dsftkd) -- they play songs as
CD-DA tracks and use PCMCIA slot 1; neither exists in the RTL.

## Memory cards (2026-10-26)

DDR's memory card reader (the White I/O board on the JVS port) is in, for card files
and for real cards on SNAC: the board's CPU runs its own boot ROM and the program the
game uploads, emulated on the HPS; the 573's JVS MCU and the SNAC byte exchange are in
the fabric. OSD "573 Card Reader" (Auto = DDR profiles), "573 P1/P2 Card" (File /
SNAC), "573 P1/P2 Card File" (S2/S3). Needs `885a01.bin` (MAME ddr3m*/ddr4m* zips)
in `games/System573`. Cabinet 2026-10-28: SNAC cards and a home-version .sav both
read and save in ddrextrm. Each player's "Card In/Out" button (map it in Define
System573 buttons) pulls the card file out when the game asks and pushes it back in.
docs/2026-10-26-white-io-reader.md.

## Open

* Intro / attract videos run slow on the Tier 1-2 titles (music ends ~5 s before
  the picture on ddr4m's intro). Not re-measured since the i-cache patch 0004 was
  retired (which fixed the same symptom in ddrextrm gameplay).
* ddrs2k attract demo cut-off (above). Same CD path as the ddr3mj wedge fixed
  2026-10-02; not re-tested on that build.
* The game-visible music position starts when the first MP3 frame has finished
  PLAYING; MAME's model starts it when the frame is DECODED
  (docs/2026-10-02-project-review.md, finding A). The player reports sync as
  spot-on, so nothing is planned unless real-hardware evidence says otherwise.
* By inspection only, never observed: s573_ddram_arb's read count across a reset,
  s573_cdimg S_STREAM on a short transfer, an auto-save armed by a cassette write
  during play (same review, finding F).
* `sim`: s573_flash_erase aborts inside vvp in some runs and passes in others.
* The build PC has killed Quartus with access violations in quartus_fit and
  quartus_sta (docs/2026-10-02-review-steps-2-3.md). Re-run a dead build before
  diagnosing it.

## Current build

| | |
|---|---|
| bitstream | job 419 (branch wio-reader, card reader), HDMI + analog: 35,964 ALM (86 %), LABs 4,118 / 4,191, DSP 95 / 112, worst setup 0.139 ns (pll_hdmi) / hold 0.241 ns. Previous: job 326, docs/2026-10-18-hdmi-output.md |
| firmware | Main_MiSTer release 2026-10-10 + `support/s573` (MP3 service, card reader service, CD trace hook, .sav grow hook, card slot guard) |
| PSX core | `psx/` submodule + `psx_patches/` (list and order: `tools/apply_psx_patches.sh`) |
| tests | `sim/`: 76 Icarus benches; `support/s573/tests`: `make test mutate`, `make wio wio-red` (needs 885a01.bin + a DDR GAME.DAT) |

## How things are done here

* **Build**: `tools/build-573.ps1` (Quartus 17.0, Windows; `-Crt` = the old analog-only variant), run as a job file
  through `tools/win/jobrunner.ps1`. It fails on negative slack and on undriven nets.
* **Sims and firmware**: WSL Ubuntu (`tools/wsl/`): `make -C sim`,
  `make -C support/s573/tests test mutate`, `tools/build-hps-mp3.sh all`.
* **Test**: SD card and USB drive moved by hand; the MiSTer is not on a network.
  The service's log (`/media/fat/s573mp3.log`, switched on by `s573mp3.debug`) is
  the instrument. After copying a `.rbf`, read it back and compare.
* **Staging a title**: `tools/stage_573.py` (reads `ksys573.cpp`), launchers in `mgl/`.
