# Hardware-source review of the 2026-10-20/21 PC work (2026-10-23)

Rule from here on: every behaviour the core models must trace to a hardware source --
the GX700-PWB / flash-card KiCad schematics and data sheets in
Konami-System-573-Documentation, psx-spx `docs/arcade/konami/573/*.md`, a chip data
sheet, or a dump of real hardware. MAME is a cross-check and a title inventory, not
a source for behaviour. Where nothing but MAME exists, the code says so and the item
gets a test on the core that uses the game's own self-test as the judge.

Scope: everything on the PC's `main` after `5bcd741` (18de8ea, 4193548, 161a34b,
bea667c, a79ed45, f923e59) and the uncommitted "gfdm-r2" WIP (preserved as commit
2223c83 "WIP as found on the PC").

| # | Item | Status | Source / action |
|---|------|--------|-----------------|
| 1 | MAS3507D output gain (`s573_mas_gain.v`, `gen_mas_gain_rom.py`, `s573_mas_gain_q12`) | **Replaced** | Was MAME's `gain_to_percentage` (adds +6 dB to every setting, so unity reads as 2x). Withdrawn in this branch; the 20-commit patch brings the data-sheet version (MAS3507D data sheet: output = -coef x input, `$80000` = 0 dB). |
| 2 | DDR Solo input map (`p1_solo`, `p2_solo`, `btn5_p1/p2`) | **Confirmed** | psx-spx games.md "DDR Solo input and light mapping" (from the Solo Bass Mix service manual) + builtin-io.md bit tables for 0x1f400008 / 0x1f40000c / 0x1f40000e. Checked line by line, all 20 JAMMA lines agree. Comment updated to cite it. |
| 3 | DrumMania and Guitar Freaks input maps (`p2_dm`, `p1_gf`, `p2_gf`, effect knob) | **MAME-only, unconfirmed** | Neither psx-spx nor Konami-System-573-Documentation documents which instrument is on which JAMMA line, or how the guitar's effect knob is encoded. psx-spx has the DrumMania *light* wiring only. The bit positions themselves are psx-spx's (0x1f400008 table). Kept as-is so the games stay playable, comments marked "NOT HARDWARE-CONFIRMED", test below. |
| 4 | PCMCIA slot 1 (`card_slot1`, banks 16-31, card-detect bit 10) | **Confirmed** | psx-spx registers.md 0x1f500000: banks 16-31 = slot 1, 32-47 = slot 2. builtin-io.md 0x1f400006: bit 10 = card 1, bit 11 = card 2 insertion, 0 = present (`s573_io.v` packs `pcmcia_present[1:0]` into [11:10]). Card = Fujitsu 32 MB, 16x MBM29F016A/017A (psx-spx games.md replacement-card table). Comments now cite these. Which title uses which slot comes from the ksys573.cpp machine configs -- title inventory, not behaviour -- and the game itself confirms it (GF 5th: ERROR 146 "DEVICE=PCCARD1" without it). |
| 5 | 16 MB slot-1 card (trailer card code 3, GF 3rd/4th) | **Open** | psx-spx documents only 32 MB cards for these games (and an 8 MB Sharp card for GunMania). "16 MB" comes from MAME `pccard1_16mb`. Code 3 is backed by the 32 MB image, i.e. behaves as a 32 MB card. Real 16 MB card behaviour above 16 MB (mirror vs. open bus) is unknown -- needs a dump or a photo of a real GF 3rd/4th card. Untested on the core. |
| 6 | Upgrade-title flash preload (stager seed, ERROR 194) | **Confirmed** | ERROR 194 text is psx-spx games.md "Bemani launcher error and status codes" ("Non-applicable game installed. To install this game, %s1 shall be installed first."). The seed data are dumps of real onboard flash chips (`.31m`, `.27m`). Lane order: psx-spx registers.md bank 0 = chips 31M + 27M; GX700-PWB `573-ROM.kicad_sch` puts **31M on IO-DATA-0..7** and **27M on IO-DATA-8..15** (both `~CE` = FLASH-CE3), so 31M = even byte (lane 0) as the stager has it. Also matched against an installed drmn3m.sav on the PC. |
| 7 | Per-title machine config in the launchers (I/O board, cassette type, card slot) | **Inventory** | From ksys573.cpp machine configs. Cassette type is cross-checked by the stager against the dump itself (ZS01 response-to-reset + command key, X76F041 size). A wrong I/O board shows up as the game's own boot error. No behaviour taken from MAME here. |
| 8 | Settings trailer (`s573_cfg_trailer.v`, stager) | **Tooling** | Not 573 hardware: 8 bytes the stager appends to the index-5 file, swallowed before the cassette. Bench `tb_s573_cfg_trailer` proves the cassette sees identical bytes. Kept. |
| 9 | ascal vcpt pipeline (`psx_patches/0033`), qsf SEED 7, HDMI triage | **Tooling / timing** | MiSTer scaler timing closure, not 573 behaviour. GHDL equivalence bench `sim/ascal_equiv`. Kept. |
| 10 | Debug OSD entries (Flash Debug, Dbg Field, MDEC Timing) | **Tooling** | 18de8ea took them off the OSD for release; the WIP put them back. Kept as found (developer build); take them off again before a release. |
| 11 | DM 4th-9th "Multisession unit not recognized" | **Open (next)** | psx-spx external-modules.md documents the unit (`GXA25-PWB(A)`: TMPR3927, XC2S200, four MP3 decoders). Any work on it starts from that page, not from MAME's empty `k573msu` stub. |

Card-reader OSD note: the 20-commit patch's "573 Card Reader / Card 1 / Card 2"
options used status bits 111-114, which the WIP now uses for "573 Controls"
(`[113:111]`) and "573 PCMCIA Card" (`[115:114]`). They move to `[117:116]`, `[118]`,
`[119]` when the patch is applied (emu.sv, s573wio.cpp, tests glue stub, README).

## Test on the SuperStation One: DrumMania / Guitar Freaks input maps (item 3)

The game's own TEST MODE input check is the judge: it shows what the game reads on
each line, which is what a real cabinet's wiring delivers.

1. Launch DrumMania 2nd Mix (no install needed). OSD: 573 Controls = Auto.
2. Press the Test button (gamepad Test, or keyboard T) to enter TEST MODE.
3. Move to the input / I/O check item with the menu buttons the screen lists at the
   bottom, open it.
4. Press each MiSTer control ALONE and write down what lights on screen:
   D-pad Left, Right, Up, Down; Button 1, 2, 3, 4; Start; pad 2 D-pad Left, Right.
   Expected (MAME `drmn`): Left = High Tom, Right = Low Tom, Up = Hi-Hat, Down =
   Snare, B1 = Cymbal, B3 = Bass Drum, B2 = Select L, B4 = Select R, pad 2 Left /
   Right = Select L / Select R, Start = Start.
5. Repeat with Guitar Freaks 5th Mix (installed): per player B1 = R, B2 = G, B3 = B,
   D-pad Up or Down = Pick, B4 = Wailing, Start = Start. Then tap D-pad Right four
   times and Left four times and write down the effect-knob value shown after
   every tap. Expected (MAME `gtrfrks`): 0, 1, 2, 3, 0 ... going right.
6. Send the list (a photo of each screen is fine). Any row that differs is fixed to
   the screen, and that list becomes the hardware record for these maps.
