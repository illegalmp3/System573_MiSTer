# System 573 core -- status

The one live status page. Last updated 2026-10-02. The page this replaced (the
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
| DDR 5th Mix | ddr5m | runs | 60 fps confirmed |
| DDR Extreme | ddrextrm | credit | 60 fps arrows, full-speed background video |

Staged on the drive, not yet reported: ddr3mk, ddr3mka, ddr3mp, ddr4mps, ddr4ms,
ddr4msj, ddrmax, ddrmax2, dsem2, dsfdct. Out of scope for this core as it stands:
the analog-board titles (2nd Mix family, dsfdcta, dsftkd) -- they play songs as
CD-DA tracks and use PCMCIA slot 1; neither exists in the RTL.

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
| bitstream | job 218, CRT-only (`-Crt`, no HDMI scaler), seed 5: 36,652 ALM (87 %), LABs 4,150 / 4,191, DSP 90 / 112, worst setup 0.794 ns / hold 0.073 ns |
| firmware | Main_MiSTer at the 2026-09-07 release + `support/s573` (MP3 service, CD trace hook, .sav grow hook) |
| PSX core | `psx/` submodule + `psx_patches/` (list and order: `tools/apply_psx_patches.sh`) |
| tests | `sim/`: 65 Icarus benches; `support/s573/tests`: 27 host groups + 7 mutations |

## How things are done here

* **Build**: `tools/build-573.ps1 -Crt` (Quartus 17.0, Windows), run as a job file
  through `tools/win/jobrunner.ps1`. It fails on negative slack and on undriven nets.
* **Sims and firmware**: WSL Ubuntu (`tools/wsl/`): `make -C sim`,
  `make -C support/s573/tests test mutate`, `tools/build-hps-mp3.sh all`.
* **Test**: SD card and USB drive moved by hand; the MiSTer is not on a network.
  The service's log (`/media/fat/s573mp3.log`, switched on by `s573mp3.debug`) is
  the instrument. After copying a `.rbf`, read it back and compare.
* **Staging a title**: `tools/stage_573.py` (reads `ksys573.cpp`), launchers in `mgl/`.
