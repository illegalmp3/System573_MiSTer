# Guitar Freaks / DrumMania (Digital I/O) -- feasibility (2026-10-18)

Source: dumps/mame573/ksys573.cpp (machine configs, input ports, output
callbacks), k573dio.cpp, MAME k573msu.cpp (GitHub master).

## Machine configs, GF 3rd-9th / DM 2nd-9th (all k573d = the board the core has)

| config | titles | cassette | PCMCIA | extra |
|---|---|---|---|---|
| gtrfrk3m | GF 3rd, 4th | cassxzi (ZS01 game + X76F041 install) | **slot 1** 16 MB | JVS memory card reader |
| gtrfrk5m / gtrfrk7m | GF 5th-9th (+ 3rd "versionup") | casszi (ZS01) | **slot 1** 32 MB | -- |
| drmn2m | DM 2nd, 3rd | cassxzi | none | drmn_output_callback (lamps) |
| drmn4m / drmn9m | DM 4th-9th | casszi | none | k573msu (stub in MAME), lamps |

Standard BIOS for all of them (no ROM_DEFAULT_BIOS). GF/DM 1st and GF 2nd Mix
are analog (k573a) and belong with the analog core.

## Findings

- **Controls are plain JAMMA input bits** (INPUT_PORTS gtrfrks / drmn): GF = R, G,
  B, Pick, Wailing (a switch), Start, and the Effect Knob as a 2-bit value on IN2
  (P1 bits 8-9, P2 bits 0-1). DM = Hi-Hat, Snare, High Tom, Low Tom, Cymbal, Bass
  Drum, Select L/R, Start. No new interface chip -- a per-title input mapping in
  s573_io.
- **Outputs gate nothing.** drmn_output_callback only drives lamps (pads, neon,
  spot, woofer neon); GF has lamp bits only. Nothing like the DDR stage handshake.
- **k573msu (DM 4th-9th)** is the GF x DM session box; MAME's device is an empty
  stub (no handlers), so the games run without it. The network PCB is commented
  out in MAME for GF/DM 9th-10th.
- **Sound is stereo.** konami573 has one 2-channel speaker; k573dio's MP3 path
  (k573fpga) routes channels 0/1 to it. The board has one MAS3507D. A 4-speaker
  cabinet is amp wiring of that stereo pair, so no downmix is needed.
- **The real gap: PCMCIA slot 1.** Every digital Guitar Freaks keeps its game on a
  card in slot 1 (banks 16-31); rtl/s573_flash.v decodes slot 2 only (banks
  32-47). The card is the same Fujitsu 16/32 MB device already modelled. Gacha
  Gachamp also uses slot 1.
- MAME flags these sets MACHINE_NOT_WORKING -- as it does every digital DDR the
  core already plays -- so the flag is not a blocker on its own.

## Work list

1. PCMCIA slot 1 in s573_flash.v (+ stager/save layout: card in slot 1).
2. Per-title control mapping (DDR / Guitar / Drum) -- ties in with the planned
   automatic DDR-vs-Solo detection (both are per-title config, which the
   launcher can carry; the GF/DM launchers have a free item).
3. Launchers + stager table entries; per-title MP3 key check.
4. Optional: JVS memory card reader (GF 3rd/4th; same as the memory card item).

Dumps needed from the user: GF 3rd-9th and DM 2nd-9th non-merged zips + CHDs
(only gtrfrk5m.zip is in dumps/mame573, no disc).

## The user's sets (T7 bemaniMAME, scanned 2026-10-18; local/re/bemani_scan.txt)

Every GF 1st-11th and DM 1st-10th set is there with its zip complete against the
driver's CRCs (drmnu / drmna zips absent; their discs are present) and every
disc matching its DISK_IMAGE SHA1. Dance Maniax / Dance Freaks (dmx sets) are
NOT on the drive.

- Digital GF/DM discs are data-only (no audio tracks) -- music is MP3, as for DDR.
- DM 4th-10th carry a second "multisession" disc (session box, not needed solo);
  GF 3rd, GF 10th, DM 9th and others also have separate "install" discs
  (MAME regions install / install2 / runtime; install2 = e-Amusement HDD data,
  needs the network unit). The runtime disc is the one that boots; a title whose
  first install needs another disc gets a disc swap (separate launcher or OSD).
- Several data discs are v5 CHDs whose hunks use **cdfl (FLAC)** even for data
  (885jab01, d09jab01, 921jbb02 ...). Copied-as-is discs are fine (Main's libchdr
  reads them), but a v5 MODE1/2048 disc that needs the cue+raw2352 rebuild would
  stop tools/s573_stage.py with its "codec cdfl" message -- the shipped titles'
  two MODE1 discs (936eaa, 910jca02) are v4 zlib, so nothing shipped is affected
  yet. The stager needs a FLAC decoder before any v5 MODE1 title is added.
