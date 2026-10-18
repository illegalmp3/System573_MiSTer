# System 573 MiSTer core -- working notes for a session

A MiSTer FPGA core for the Konami **System 573** arcade board (a PlayStation
derivative), built on the vendored MiSTer PSX core. One developer, one cabinet.
Read `docs/STATUS.md` first: what runs, what is open, how things are built.

## The setup (there is no build host and no ssh)

* The working copy is on a Windows PC: `C:\Users\ricky\Documents\System573_MiSTer`.
* **Jobs**: `tools/win/jobrunner.ps1` runs files dropped in `local/jobs/queue/`
  in name order (`.cmd` -> Windows, `.sh` -> WSL Ubuntu as root, from the project
  root) and leaves `NAME.log` / `NAME.rc` in `local/jobs/done/`. Builds, sims and
  git all go through it.
* **Bitstream**: `tools/build-573.ps1` (Quartus 17.0; HDMI + analog). ~27 minutes. `-Crt` = analog only. Do not
  edit sources while one runs.
* **Sims**: `make -C sim` (Icarus), `make -C support/s573/tests test mutate`.
* **Firmware**: `tools/build-hps-mp3.sh all` -> `out/MiSTer`.
* **Hardware**: a DE10-Nano tested by moving the SD card and the games drive by
  hand. Not on a network. Evidence comes back as `s573mp3.log` on the card.
* MAME sources for reference: `dumps/mame573/` (ksys573.cpp, k573dio/fpga,
  mas3507d, zs01, pccard, ...). The PSX core's upstream source is `psx/`.

## Rules that have each been paid for

1. **Sources before builds.** A change is argued from MAME / the upstream PSX
   core / a log, and simulated, before a bitstream is built. No builds on a guess.
2. **A claim needs a number.** "Works" is a log line, a counter, a bench result --
   not a reading of a screenshot.
3. **RED before GREEN.** A bench for a fix must fail on the unfixed code.
4. **Verify what was copied.** Read a deployed `.rbf` / `MiSTer` back from the card
   and compare; a valid Cyclone V `.rbf` starts 0xFF with entropy ~7. Keep the
   previous file on the card as `*.prev-YYYYMMDDx`.
5. **Vendored `psx/` stays pristine.** Every change to the PSX core is a numbered
   `psx_patches/NNNN-*.patch` applied by `tools/apply_psx_patches.sh`. Debug
   probes ship gated off.
6. **The design is at ~99 % LABs.** Area is a budget; check the fit summary.
7. **Git**: work is on a topic branch; commit locally, push only when asked.
   Dumps, `local/`, `out/` and build output are never committed.
