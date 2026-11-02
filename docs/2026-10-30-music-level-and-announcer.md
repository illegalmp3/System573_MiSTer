# Music level and the announcer/crowd during songs (2026-10-30)

**Update 2026-11-01.** After testing on the SuperStation One: Music Level now steps 0..+6 dB
in 1 dB steps on the music only (the SPU-reduction positions are gone), and the
**Announcer/Crowd option is withdrawn** -- it worked most of the time, but a stray crowd
cheer could still be heard near the end of some songs (the fixed 8 s tail does not hold
for every song). Its module, benches and SPU patch are kept for a different approach later:
`tools/attic/voice_duck/`, `psx_patches/retired/0035-s573-spu-voice-duck.patch`. The
study below stands as data.

Originally two OSD options, both defaulting to the core as it was:

* **573 Music Level** (`status[122:120]`, `rtl/s573_audio_trim.v`): 0 dB, +3 dB, +6 dB,
  +6 dB with the SPU -3 dB, +6 dB with the SPU -6 dB.
* **573 Announcer/Crowd** (`status[124:123]`, `rtl/s573_voice_duck.v` + `psx_patches/0035`):
  Normal, -6 dB, -12 dB, Off, for the SPU voices keyed during a stage song, between its
  READY / HERE WE GO and its end cheer.

Neither is hardware behaviour. They exist because the balance between the music and the
SPU (announcer, crowd, effects) on the real boards is set by an analog stage no source we
hold describes.

## What is known about the music level

| Fact | Source |
|---|---|
| The games set the MP3 chip's output with the MAS3507D volume matrix; `$80000` = 0 dB | MAS3507D data sheet 3.7.3, Tables 3-19..3-21 (supplied 2026-10-30, same as S6 of the 10-23 audit) |
| DDR Extreme plays songs at -12 dB (`dfd91`), 3rd Mix at -10 dB (`d785e`), 4th Mix at -8 dB; fades go to -64 dB (`ffeb5`) and 0 (mute) | SD-card logs `session-00006/7/8/9.log` (`CFG ... gain=`); ddr4m exe table 0x800df160 |
| The test menu's SOUND SCALE CHECK 2 (MP3) also plays at -12 dB in Extreme | `session-00009.log`, four check-2 runs, all `dfd91` |
| Games set OutputConfig `0x00030` = 16 bits/sample: nothing between the chip and its DAC changes the level | `docs/2026-07-01-ddrsbm-dio-i2c-transactions.md`; data sheet `$32f` bit table |
| The music leaves the Digital I/O board through its own DAC (AK4309B) and a cable into the main board's CD-DA IN | MAME `k573dio.cpp` board notes (CN16) |
| The cabinet takes ONE mixed stereo pair from the PCB box (RCA) and splits it into a full-range amp and a bass amp, each with its own knob | DDR operator manual GN845-UC, 8-2 wiring diagram (supplied 2026-10-30) |
| The main board's audio sheet shows the SM5877AM SPU DAC, LM358 and LA4705 but no resistors or capacitors | NaokiS28 `Schematics (KiCad)/GX700-PWB/Audio.kicad_sch` |
| MAME's `+6` in `gain_to_percentage` came in with no stated basis, in the same work-in-progress commit that took 0 dB for "mute" | MAME `ab8dbd3db0` (2019-05-16) |

So the MP3-to-SPU ratio at the speakers is unknown. Measured on the core (capture of
SCALE CHECK 1 and 2, full and -1 Global Volume, 2026-10-30): the MP3 tone peaks 5.2 dB
under the SPU tone (-13.2 vs -8.0 dBFS average peak over 16 notes), 4.0 dB under on the
first 100 ms; MiSTer Global Volume moved both by exactly 6.0 dB. With MAME's +6 dB the
peaks would be within 1 dB. A line-out recording of the same two checks from a real
Digital 573 would settle the ratio; none is available. Music Level is therefore a
preference, 0 dB = the 1:1 sum.

Above +6 dB the trim lowers the SPU instead of raising the music: Extreme's songs sit at
-12 dB in the chip, so +12 dB on the music alone puts full-scale masters at the rails
(the 2026-07-31 notes measured +1.2/+1.6 dBFS peaks at unity) and the sum would clip.

## What the games do with the SPU during a song

MAME 0.264 in the PC's WSL, headless, scripted with `local/mame/study.lua`: every SPU
KEYON (voice, sample address, volume, pitch) and every Digital I/O MP3 command logged,
SCALE/I2C decoded, one snapshot a second, a credit played by mashing the arrows. Runs:
`local/mame/study9` (ddrextrm), `study_ddr5m`, `study_ddrmax2`. ddr3mj could not be run
(its install needs the second cassette MAME does not model the swap of); its MP3 layout
comes from the core's own logs instead.

**Which MP3 is a stage song.** Every stage song was played from Digital I/O RAM address 0
and was 1.09-1.92 MB (core logs: Extreme 1,086,181-1,305,617; 3rd Mix 1,376,355-1,568,617;
MAME: Extreme 1,479,319, 5th 1,632,003, MAX2 1,919,581). Menu music, previews and jingles:
Extreme's at other addresses (60 KB previews, 349/379 KB menus); 3rd Mix's previews ARE at
0 but 287-288 KB, and its 849 KB file is at 0x2942a4; 5th's 706 KB menu file is at
0x43a040. Rule: start = 0 and length >= 0xC0000 (786,432) bytes.

**When the start and end sounds come** (seconds from the game's play command):

| | READY / HERE WE GO set | first mid-song sound | last mid-song sound | end set | MP3 ends |
|---|---|---|---|---|---|
| Extreme (Graduation) | 0.18, 0.40, 2.12, 2.77 | 25.3 | 95.0 (10.4 s left) | 101.8 crowd (3.6 s left) | 105.4 |
| MAX2 | 0.18, 0.37, 2.14, 2.69 | 24.7 | 84.7 (11.1 s left) | 92.4 crowd (3.4 s left) | 95.8 |
| 5th Mix | 0.28, 0.43, 2.56 | 27.8 | 91.8 (10.0 s left) | 96.05, 96.20 (5.7/5.6 s left) | 101.8 |

The games let the file play out: the stream ran to the end address at exactly 14,032 /
16,035 / 20,035 bytes per second (112 / 128 / 160 kbps CBR), with no stop command. The
one-a-second snapshots line the sets up with the screen in all three: READY at +0.4,
HERE WE GO at +2.1 (Extreme, MAX2) / +2.5 (5th -- it does say it there), and the end set
with the last arrows / the wipe, a second before CLEARED. Sample identity does not separate end from middle (MAX2
plays its HERE WE GO crowd again mid-song), so the rule is time-based.

## The rule (`rtl/s573_voice_duck.v`)

At each KEYON (SPU 0x188 / 0x18A), each keyed voice is marked "ducked" if a stage song
started more than 4 s ago and more than 8 s of it remain, otherwise "not ducked"; the mark
holds until that voice is keyed again. Remaining time = (MP3 end - streamer position) /
streamer bytes in the last second. In the core the streamer leads the speakers by the PCM
ring (~1.5 s), which only widens the end margin. The SPU (patch 0035) adds a ducked voice
to the dry mix and reverb send shifted 1 (-6 dB), 2 (-12 dB), or not at all (Off).

## Benches

* `sim/tb_s573_audio_trim.v` -- 0 is a bit-exact passthrough; each gain exact; saturation.
* `sim/tb_s573_voice_duck.v` -- replays every KON above from all three titles at their
  measured byte rates, plus Extreme's menu BGM, a 3rd Mix preview at 0, 3rd Mix's 849 KB
  file at 0x2942a4 and 5th's 706 KB menu file (none ducked), a song restart, and a voice
  on the high KEYON register. Mutants that drop the 4 s keep, the 8 s tail or the address
  check each fail it.
* `sim/spu_duck/` (GHDL 4.1 in WSL, the real patched `spu.vhd` with upstream's sim
  memory models) -- one noise voice at full volume, 200 samples per run: ducking another
  voice = identical output; mode 01 = 0.5000 of the reference RMS (worst sample 1.0 LSB
  off reference/2), 10 = 0.2500 (worst 1.5 LSB: one floor in the shift, one in the
  0x7FFE main-volume multiply), 11 = silence. Job 480, RESULT: PASS.

## Not covered

* 3rd/4th Mix and MAX were not run in MAME; the rule rests on 5th, MAX2 and Extreme plus
  the 3rd Mix MP3 layout from the core's logs. A coin chime during a song is ducked too.
* A song whose chart ends more than ~8 s before its file does will have its end cheer
  ducked; one whose announcer speaks inside the last 8 s will not be ducked there.
