# MP3 gain, per-title controls and PCMCIA slot 1 (2026-10-20)

Driven by the first DrumMania / Guitar Freaks run on the cabinet (DM 2nd and 3rd Mix
played a full credit; DM 4th-9th and GF 5th Mix stopped at errors).

## 1. The MAS3507D gain was captured and never applied

DM 2nd/3rd: the music ran on after screen changes, and the drum hits (SPU) were
quieter than the backing track. The 2026-10-20 log (`local/re/mp3log2.txt`) shows the
game writing the MAS3507D gain matrix all the time: `gain=dfd91` (-12 dB) around song
starts and `gain=00000` (mute) at stops. Earlier logs show the DDR titles writing it too
(`d785e` -10 dB in ddr3mj, `dfd91`, `ffeb5` -64 dB). `rtl/mas3507d_i2c.v` captured the
values and the HPS service logged them, but nothing multiplied the PCM by them (the
2026-09-11 decision to ship unity + `atten=` while the encoding was unknown; the
conversion `s573_mas_gain_q12()` was written and unit-tested later, but never called).

MAME `mas3507d.cpp`: `gain_to_db(v) = round(20*log10((0x100000-v)/0x80000))`,
`gain_to_percentage(v) = v==0 ? 0 : powf(10,(db+6)/20)`, reset = 1.0, every output
sample multiplied by it.

**Fix: `rtl/s573_mas_gain.v`**, in the fabric, between `s573_mp3_pcm` and
`s573_audio_mix`. The dB step / percentage table (110 entries, +6 .. -114 dB) is
generated from MAME's exact arithmetic by `tools/gen_mas_gain_rom.py` and embedded in
the module; a write starts a ~110-cycle threshold scan per channel; the sample is
multiplied by the Q12 gain and saturated. At the OUTPUT, so a mute is immediate, not
~1.5 s late behind the PCM ring. No change to the MiSTer executable.

`sim/tb_s573_mas_gain.v`: unity before any write, every threshold and its neighbours,
every 61st value of all 2^20 (17,269 checks against MAME's formula), the logged values,
a write landing mid-scan, scale / saturation / mute. PASS.

Effect on DDR: music now sits at the level the game asks for (about -4 to -6 dB below
the old unity), relative to the SPU effects, and fades where the game fades it.

## 2. Per-title settings trailer: control layouts and card slot

An .mgl has no room for another item, so `tools/s573_stage.py` / `stage_573.py` append
8 bytes to the index-5 file (.u6 or .cas): `"S573" 'C' profile card xor`.
`rtl/s573_cfg_trailer.v` holds every index-5 byte back eight positions; a valid trailer
is swallowed, anything else reaches `s573_cass_pack` unchanged (files staged before this
behave exactly as before). `sim/tb_s573_cfg_trailer.v` runs loader -> trailer -> pack
for .u6, packs of both chip types, each with and without a trailer, a bad checksum, a
short file and back-to-back loads: the cassette side sees identical bytes and verdicts.

- **profile** from the GAME() input-port column of ksys573.cpp: ddr 0, ddrsolo 1,
  drmn 2, gtrfrks 3. OSD "573 Controls" (Auto / DDR / DDR Solo / DrumMania / Guitar
  Freaks, `status[113:111]`) replaces "573 Cabinet" (`status[100]`); Auto = trailer,
  else DDR. The DDR stage handshake (gn845pwbb) is on for the DDR standard profile only.
  - DrumMania (`INPUT_PORTS_START(drmn)`): P1 byte as the standard cab (LEFT High Tom,
    RIGHT Low Tom, UP Hi-Hat, DOWN Snare, B1 Cymbal, B3 Bass Drum); Select L/R are the
    P2 LEFT/RIGHT lines, now also driven by P1 Button 2 / Button 4.
  - Guitar Freaks (`INPUT_PORTS_START(gtrfrks)`): per player R/G/B = Button 1/2/3,
    Pick = D-pad Up or Down, Wailing = Button 4, Start; Effect Knob (2-bit IPT_DIAL,
    raw) stepped by D-pad Left/Right.
- **card**: 0 none, 1 slot 2 32 MB, 2 slot 1 32 MB, 3 slot 1 16 MB. A named card is
  fitted (as a 48 MB save already did) in the named slot. OSD "573 PCMCIA Card"
  becomes Auto / 32MB (slot 2) / 32MB (slot 1) (`status[115:114]`).

## 3. PCMCIA slot 1

GF 5th Mix: ERROR 146 "check that the flash card is inserted, DEVICE=PCCARD1". Every
digital Guitar Freaks (3rd-11th) keeps its game on a card in slot 1 (ksys573.cpp
pccard1_16mb / pccard1_32mb; flashbank_map 0x4000000-0x7ffffff = banks 16-31).
`s573_flash.v` takes `card_slot1`: the card decodes at banks 16-31 instead of 32-47
(same Fujitsu card, same SDRAM image, same bank-to-pair mapping and mirror), and the
card-detect lines report slot 1 fitted / slot 2 empty (IN1 bits 26/27, MAME
pccard_cd_r<0>/<1>). `sim/tb_s573_flash_pccard1.v` is the slot-2 bench re-run with
the card in slot 1 (bank 32 must read empty). Save layout: a slot-1 card rides as the
same 32 MB card region (`stage_573.save_layout`), so GF 5th's save is 48 MB + 1 KB + 9 KB.

## 4. Upgrade titles (stager, same day)

ERROR 194 on DM 4th/6th/7th power-up: "a different game is installed; <previous mix>
must be installed first". MAME ships the previous install as the set's 29f016a ROMs and
preloads it; the stager now seeds a new save's flash with them (drmn4m: GCA23 = DM 3rd,
drmn6m: G*B05 = DM 5th, drmn7m: G*C07 = DM 7th, gtrfrk5m: GEA24 = GF 4th).

## Still open

- DM 4th-9th: "Multisession unit not recognized" (MAME's k573msu is an empty stub).
  The test menu has "Session play settings" / "Multisession unit check"; with Select
  L/R now on P1, check whether session play can be switched off there.
- GF 3rd/4th use a 16 MB slot-1 card, backed here by the 32 MB image; untested.
