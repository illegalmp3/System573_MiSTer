# MP3 service as a separate Main binary (`MiSTer_System573`), selected per core

**Date:** 2026-10-23. **Goal:** nobody has to replace their stock `/media/fat/MiSTer`.

## How stock Main picks a binary (Main_MiSTer `065d0d2`, 2026-10-22)

* `cfg.cpp`: INI key `MAIN` (string), default `strcpy(cfg.main, "MiSTer")`.
* `user_io.cpp` `user_io_init()`, after the core is loaded and `cfg_parse()` ran:

      const char *main = getFullPath(cfg.main);
      if (strcasecmp(main, getappname()) && FileExists(main))
          app_restart(path, xml, main);

  `getFullPath` prefixes the storage root (`/media/fat`, or `/media/usbN` when USB
  storage is selected) unless the value is absolute; `getappname()` is
  `readlink(/proc/<pid>/exe)`. `app_restart` (`fpga_io.cpp`) `execl`s the other binary
  with the same core path and `.mgl` path; it does not reprogram the FPGA, and the
  `.mgl`'s file loads (`mgl_parse`, later in `user_io_init`) run in the new binary.
* The menu and every other core get the default `main=MiSTer`, so the same check
  restarts back into the stock binary. No loop: in the alternate binary the check
  compares equal.

## Which INI section applies -- why `[System573]`, not `[Konami_System_573]`

`cfg.cpp` `ini_get_section()` accepts `[MiSTer]`, `[arcade]` (MRA only), and a section
equal to `user_io_get_core_name(0)` or `(1)`: the override name and the core's own
name. The `.rbf` file name is not consulted.

* own name (`orig_name`): the first CONF_STR field, `"PSX"` (`rtl/emu.sv`). It must
  stay `PSX`: `is_psx()` (`strcasecmp(orig_name, "PSX")`) gates Main's PSX disc
  handling that this core's CHD mount uses.
* override name: `arcade_pre_parse(xml)` -> `<setname>` -> `user_io_name_override()`;
  every launcher in `mgl/` has `<setname>System573</setname>`. This is also the
  `games/System573` folder and the `config/System573.*` files, so it is not renamed.

So `[System573]` applies to every launcher, `[Konami_System_573]` to nothing, and a
bare `.rbf` (name `PSX`) gets neither -- it already got no MP3 (the service's own
`is_573()` gate, `docs/2026-09-11-hps-mp3-service.md`).

## What changed in the repo

* `tools/build-hps-mp3.sh`: output `out/MiSTer_System573`; `deploy` installs it beside
  the stock binary, restores the stock `MiSTer` from `MiSTer.orig` when an earlier
  deploy had replaced it, and adds `[System573] main=MiSTer_System573` (plus
  `debug=1` in that section only, for the service's log) to `MiSTer.ini` and every
  `MiSTer_*.ini`. The glibc gate now compares against the card's own stock `MiSTer`
  when there is no `MiSTer.orig`.
* `tools/s573_stage.py --install-mp3 ROOT [--mp3-binary PATH]`: the same for users --
  copies the binary and adds/repairs the section (idempotent, line endings kept,
  one-time `.bak573` backup). Test: `tools/test_s573_stage_ini.py`.
* README step 4 rewritten.

No firmware change: the binary is the same build under another name.

## Hardware check (Ricky's console currently runs the fork AS `/media/fat/MiSTer`)

1. On the PC with the SD card in: copy `MiSTer` (the current fork) to
   `MiSTer_System573`, then copy `MiSTer.orig` over `MiSTer` -- or run
   `tools/build-hps-mp3.sh deploy`, which does both.
2. Add `[System573]` / `main=MiSTer_System573` to `MiSTer.ini`
   (`python3 tools/s573_stage.py --install-mp3 E:\` does it).
3. Boot. Launch any Digital DDR launcher: music must play (the switch is invisible;
   with `debug=1` the console log shows "Current exec is /media/fat/MiSTer, core
   requires exec /media/fat/MiSTer_System573").
4. Back to the menu, start another core (e.g. PSX or N64) -- it must run normally; and
   load a DDR title again to confirm the switch happens every time.
