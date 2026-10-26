# DDR Extreme: "PCCARD2 not installed", then ERROR 175 (2026-10-25)

## Report

The first boot of ddrextrm after the virtual card-file work said PCCARD2 was not
installed (set DIP-SW4 to CD-ROM). The next boot showed launcher ERROR 175: "Cassette is
not corresponding with the machine ... replace it with Cassette No.0000-0002" (psx-spx
games.md, Bemani launcher message index 75).

## What the files show

`games/System573/ddrextrm.sav` (T7), 50,341,888 bytes:

| region | state |
|---|---|
| onboard flash, 16 MB | == every good backup (the install, header ID 5f878a97f943384f) |
| PCMCIA card, 32 MB | == every good backup |
| cassette block (`573NVCAS`, 140 bytes ZS01 NV) | == the pristine `ddrextrm.u1`. Every good backup has the install's writes (bytes 52, 53, 59, 84, 85, 91) |
| timekeeper block (`573NVTKP`, 8 KB) | all zero. Good backups: ~780 bytes in use |

So the install itself was intact. The cassette and timekeeper blocks were overwritten
with a never-installed cassette and an empty M48T58. The flash records the install
against the cassette, so the cassette no longer matched it. ERROR 175 is the same
mechanism s573_cass_nv was written to fix on 2026-09-16.

## Cause (s573mp3.log, four sessions)

The boot-time restore holds the CPU in reset (`flash_loading`) for ~25 s. Sessions 1, 2
and 4 show that: the cassette is not clocked for 30 s ("NOT ARMED"), then a new reset
epoch when the restore ends. Session 3 (the PCCARD2 boot) has no restore at all: the
CPU ran ~23 s after the last download and clocked the cassette with no epoch in
between. That session also shows the OSD in use at once (the card reader went Off ->
Virtual -> SNAC, 3-4 s after the downloads).

`saver_reset` includes `status[0]`, the OSD "Reset". A Reset during the restore aborts
it. `flash_load_taken` was set when the restore *started* and cleared only by a new
slot-4 mount or a flash/cassette/NVRAM download, so the restore never ran again. Then:

1. The CPU booted off whatever the SDRAM still held from the previous session, with
   the card region not restored (PCCARD2), the .u1's pristine cassette and an empty
   timekeeper.
2. The game wrote the timekeeper. 3 s later u_tk_nv asked for its partial save, and
   s573_flash_saver wrote the cassette and timekeeper blocks -- un-restored -- at the
   end of the .sav.
3. Session 4's restore (complete) loaded that file: an installed flash with a
   pristine cassette, so ERROR 175.

Nothing in Main's .mgl flow resets the saver: the .mgl `<reset>` item is a keyboard
reset (`buttons[1]`, menu.cpp states 4/5), and the bench has always modelled it that
way. Only RESET, status[0] and the flash/cassette/NVRAM downloads do.

## Fix (rtl/emu.sv)

* `flash_restored`: set when a restore ends with `saver_reset` low (it ran to its last
  block). Cleared by a new slot-4 mount and by a flash, cassette or NVRAM download.
* A `saver_reset` while a restore is taken but not finished clears `flash_load_taken`.
  The restore runs again as soon as the reset clears, and the CPU stays held for it.
* `flash_restore_hold` (in `reset_or`): the CPU stays in reset from the moment a
  non-empty save is mounted (at least 1 block) until its restore has finished. This
  closes the cycles between the end of the aborting reset and the restore starting
  again. The first GREEN run caught that gap as a CPU release before the image was
  complete.
* `sav_writes_ok = ~flash_save_mounted | flash_restored` gates every write to the
  mounted file: the OSD-open auto-save and "Save Flash" (flash_save_trigger), the
  install auto-save (flash_wr_ack / autosave_en into the saver), and the timekeeper's
  partial save (part_trigger). Erase Flash Save is left alone, because it is a
  deliberate wipe.

Bench: `sim/tb_s573_sav_mount_order.v` S6 is an OSD Reset 3 s into the restore,
followed by the game's timekeeper write.

* `make NO_RESTORE_GUARD=1` gives the old logic. S6 FAILs: the image is never the
  file's, the CPU boots on the leftover image, and the file is written first.
* By default S6 passes: the restore runs again, the CPU waits for it, and the partial
  save comes after it.

## Recovery

The damaged file is kept as `games/System573/_replaced-saves/ddrextrm.sav.error175-20261025`.
`ddrextrm.sav` now equals `local/t7-archive-20261002/_old_saves/ddrextrm.sav.20260929-before-restore`
(the newest good copy; same flash and card, installed cassette, timekeeper as of
2026-09-29). Timekeeper bookkeeping recorded after 2026-09-29 is lost.
