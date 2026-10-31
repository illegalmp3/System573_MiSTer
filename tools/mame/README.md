# MAME reference runs (2026-10-30)

`study.lua` is a MAME 0.264 autoboot script that logs every SPU KEYON (voice, sample
address, volume, pitch), the Digital I/O MP3 commands (start/end/play, streaming flag) and
the MAS3507D I2C writes (decoded from DIO 0xac), takes a snapshot every SNAP seconds, and
can play a credit (coin, start, arrows mashed while a long MP3 plays). `install.lua` runs a
title's CD -> flash install (Start Up Device = CD-ROM, TEST pressed for the drive update).
Used for docs/2026-10-30-music-level-and-announcer.md. Run headless:

    SDL_VIDEODRIVER=dummy OUT=study.log PLAY=1 START2=1 SNAP=1 \
      mame ddrextrm -rompath roms -video none -sound none -nothrottle \
      -seconds_to_run 700 -autoboot_script study.lua

Notes: MAME drops write taps when the map is rebuilt, so the script reinstalls them every
few frames; with -video none the frame notifier stops once the game blanks the screen, so
it uses emu.register_periodic.
