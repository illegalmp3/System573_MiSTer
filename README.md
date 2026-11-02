# Konami System 573 for MiSTer

A MiSTer FPGA core for the **Konami System 573**, the PlayStation-based arcade board
behind *Dance Dance Revolution*, *Dancing Stage* and the rest of Konami's early BEMANI
games. It is aimed at the **Digital I/O DDR titles** (DDR Solo Bass Mix through DDR
Extreme), and they are what it has been tested with.

**Status: work in progress.** Most Digital I/O DDR titles install, boot and play full
credits with music. Other 573 games are untested or unsupported (see below). Latest
download: the [Releases page](https://github.com/illegalmp3/System573_MiSTer/releases).

## Where this core comes from

This repository is a fork of **[Fabricore's System 573 core](https://github.com/fabricore-eng/System573_MiSTer)**.
Everything up to their `main` at `6b114d6` (2026-08-02) is their work and their commit
history is kept here unchanged: the board research, the 573 RTL, the integration of the
MiSTer PSX core over the PlayStation's EXP1 bus, the HPS-side MP3 service and the first
DDR title with music (*DDR Solo Bass Mix*). Their README, with the bring-up history up
to that point, is
[here](https://github.com/fabricore-eng/System573_MiSTer/blob/6b114d6/README.md).
This README replaces it for this fork.

This fork added: the X76F041 and ZS01 security cassettes and two-cassette titles, the
DDR stage I/O board handshake, the 32 MB PCMCIA flash card (3rd Mix through Extreme),
CD-to-flash installs that persist, 60 fps gameplay with full-speed background video,
MP3 streaming fixes, HDMI output, DDR's memory card reader, single launchers per title,
and a review of the whole core against the hardware documentation
([`docs/2026-11-02-source-review.md`](docs/2026-11-02-source-review.md)).

## A note from the maintainer

10/29 update: My apologies, this update took longer than I expected to release. I’m happy to say that you no longer need to replace your MiSTer executable to run this core (that was really stupid, thanks Tourniquet) and I can confirm virtual and SNAC memory cards work with DDR Extreme. I’d also like to send a thank you to Naoki Saito for sending me down a useful path of finding additional sources to improve this core, and a shout out to the psx-spx website which contains a fascinating section on System 573 (and which also has a list of contributors and links you should check out). Thank you to every person documenting System 573. There are still things to be fixed and features I’d like to see added to this core. Off the top of my head, Dancing Stage featuring Dreams Come True doesn’t load to gameplay, so I’m gonna look into that. I’d also like to add SNAC support for DDR pads, but I don’t own a PSX pad, so I may need other people who’d be willing to test that for me. Once I feel like DDR games are well-represented on this core, I’ll be ready to move on to Guitar Freaks and drummania.

This would not exist without work done by human beings such as contributors to MAME (respect to 987123879113 in particular) and the contributors to the PSX_MiSTer core, and it must be mentioned that this core was built on what fabricore made publicly available. I am not a developer. I wanted to play DDR on a MiSTer console with a pad on a CRT, and here we are. This is Claude’s work, not mine. As of 10/18/2026, this core has only been tested with Digital System 573 DDR titles, and no testing has been done with other 573 bemani titles. Off the top of my head, features I wish to include are: (i) Memory Card support; (ii) Analog 573 support (DDR 1st Mix and 2nd Mix); (iii) automatic recognition of DDR solo vs standard DDR games; and (iv) support for other 573 bemani games. One last note: I used MAME non-merged ROMs to test this core.

## What runs

Tested on one machine, a SuperStation One (DE10-Nano, 128 MB SDRAM), on a CRT and
over HDMI. "Credit" means a full credit of songs played with music. The up-to-date
list is [`docs/STATUS.md`](docs/STATUS.md).

| Title | MAME set | State |
|---|---|---|
| DDR Solo Bass Mix | `ddrsbm` | credit |
| DDR Solo 2000 | `ddrs2k` | credit (attract demo cuts off early) |
| DDR 3rd Mix (Japan) | `ddr3mj` | credit |
| DDR 3rd Mix (Asia) | `ddr3ma` | installs and boots |
| DDR 4th Mix | `ddr4m` | credit |
| DDR 4th Mix (Japan), 4th Mix Plus | `ddr4mj`, `ddr4mp` | boot, songs not yet reported |
| DDR 5th Mix | `ddr5m` | runs |
| DDRMAX, DDRMAX2 | `ddrmax`, `ddrmax2` | credit |
| DDR Extreme | `ddrextrm` | credit; memory cards (files and SNAC) |
| DDR USA | `ddrusa` | credit |
| Dancing Stage Euro Mix | `dsem` | credit |
| Dancing Stage featuring Disney's Rave | `dsfdr` | credit |
| Dancing Stage featuring Dreams Come True | `dsfdct` | does not reach gameplay |
| Hyper Bishi Bashi Champ, 2 Player | `hyperbbc`, `hypbbc2p` | boot (no MP3 board) |
| DDR 3rd Mix Korea / Plus, 4th Mix Solo / Plus Solo, Euro Mix 2 | | staged, not yet reported |
| DrumMania 2nd-9th Mix, Guitar Freaks 5th Mix | | launchers in [`mgl/`](mgl/) for testing, not in the release |

Not supported: the analog-I/O-board titles (DDR 1st/2nd Mix and others) -- they play
their music as CD audio, which the core does not have yet -- and anything needing
hardware listed as absent below.

## Installing

You need a DE10-Nano with a 128 MB SDRAM board, and your own MAME romsets and CHDs
for the titles. No game, BIOS, cassette or boot ROM data is in this repository or its
downloads. The [Releases page](https://github.com/illegalmp3/System573_MiSTer/releases)
has three downloads: the core zip (laid out like the SD card), `s573_stage.py`, and
`System573_blank_saves.zip`.

1. **Core:** copy `_Console/Konami_System_573.rbf` to `_Console/` on the SD card.
2. **Launchers:** copy the `.mgl` files to `_Arcade/`. Each is named
   `<title> (<region>, <year>)` and loads one title ([`mgl/README.md`](mgl/README.md)
   maps them to MAME sets). Start games from a launcher, not from the bare `.rbf`.
3. **Game files:** `s573_stage.py` (Python 3.8 or newer, nothing else) builds
   `games/System573/` from your romsets:

       python3 s573_stage.py <folder with your MAME roms> <SD card or USB drive>

   It writes the BIOS, cassette image(s), disc and an empty save file for every title
   it finds, plus `885a01.bin` (the memory card reader's boot ROM) for the DDR titles
   that use the reader. Files are found by checksum, so non-merged, split and merged
   sets all work. It never replaces an existing `.sav` (that holds the game's
   install). `--list` shows what it found without writing. `System573_blank_saves.zip`
   has the same empty saves for staging by hand -- don't extract it over saves you
   already have.
4. **Music (`MiSTer_System573`):** the Digital I/O titles' MP3 music is decoded on the
   MiSTer's ARM side, by a separate Main binary that sits next to your stock `MiSTer`
   (which is not replaced). Copy `MiSTer_System573` to the root of the SD card and add
   to `MiSTer.ini` (and any `MiSTer_*.ini` you use):

       [System573]
       main=MiSTer_System573

   `python3 s573_stage.py --install-mp3 <SD card>` does both, with a one-time
   `MiSTer.ini.bak573` backup. Needs a stock Main from MiSTer_20240505 or later (the
   first with `main=`). The section must be named `System573`, the launchers' set
   name. Without it the core runs, silently. Hyper Bishi Bashi Champ and Gacha Gachamp
   do not need it.
5. **First boot of a CD title installs it to flash:** set OSD **573 Boot Device** =
   CD-ROM, launch, let the game install, and **wait for the "Flash saved" message**
   before switching off. Then set **573 Boot Device** = Flash ROM and launch again.

Upgrading from v0.1.x (which replaced `/media/fat/MiSTer`): put the stock `MiSTer`
back (run the updater), then do step 4.

## OSD options

| Option | What it does |
|---|---|
| 573 Boot Device | Flash ROM or CD-ROM (DIP switch 4 on the board) |
| 573 Cassette | two-cassette titles: Auto (follows Boot Device), Game, Install |
| 573 Controls | Auto (from the staged title), DDR, DDR Solo, DrumMania, Guitar Freaks |
| 573 PCMCIA Card | Auto, 32 MB in slot 2, 32 MB in slot 1 |
| 573 Card Reader, P1/P2 Card, P1/P2 Card File | DDR memory card reader: Auto/On/Off; card file or SNAC per player |
| 573 MP3 Descramble | Default for every title except DDR Solo Bass Mix, which needs "DDR Solo Bass Mix" (on a board, the game's own FPGA bitstream decides this) |
| 573 Chart Offset | -16 .. +15 ms: moves the arrows against the music, for display or audio latency outside the FPGA |
| 573 Music Level | 0 .. +6 dB on the music only; a listening preference, not a hardware setting |
| Save to SDCard, Save Flash, Erase Flash Save, Auto Save Install | when the flash install is written back to the `.sav` |
| Card In/Out (a button) | pulls a player's card file out / back in when the game asks |

Opening the OSD pauses the game and its music together. HDMI and the analog output
(RGB, YPbPr, S-Video, composite, per `MiSTer.ini`) run at the same time.

### Memory cards (DDR)

The Japanese and Asian DDR cabinets from 3rd Mix on have a memory card reader (the
"White I/O", GE885-PWB(A)) on the JVS port. The core runs it the way the cabinet does:
the 573's JVS MCU is in the fabric as psx-spx documents it, and the reader board's own
CPU runs Konami's boot ROM and the program the game uploads to it, on the ARM side.
Card files are raw 128 KB images (`.mcd`, `.mcr`, `.sav`) in `saves/System573/`; real
cards work on SNAC (port 1 = player 1). Titles: the sets whose MAME machine has the
reader -- 3rd Mix (Japan, Asia, Korea, Plus), 4th Mix (Japan, Asia, Plus, Solo, Plus
Solo), 5th Mix, DDRMAX, DDRMAX2, Extreme. Details:
[`docs/2026-10-26-white-io-reader.md`](docs/2026-10-26-white-io-reader.md).

### Music level

Each game sets its own music volume on the MP3 decoder chip (DDR 4th Mix -8 dB, 3rd Mix
-10 dB, Extreme -12 dB) and the core applies it as the chip's data sheet defines it.
How loud the music then is next to the announcer on a real cabinet depends on analog
mixing that no available source documents, and it has not been compared with a real
cabinet; hence the Music Level option.
[`docs/2026-10-30-music-level-and-announcer.md`](docs/2026-10-30-music-level-and-announcer.md).

### Bug reports and logs

Put a file named `s573mp3.debug` in the SD card's root (the release has a template)
and `MiSTer_System573` keeps one log per session in `logs/System573/`
(`sessions.txt` lists which game each one was). Send the log with a description.

## What the board is, and what the core emulates

The System 573 is a PlayStation (MIPS R3000A CPU, GPU, SPU) with 4 MB of main RAM and
2 MB of VRAM, plus Konami hardware: an ATAPI CD-ROM drive on IDE, 16 MB of onboard
flash and two PCMCIA slots for linear flash cards, an M48T58 clock with 8 KB of
battery-backed RAM, a security cassette slot (X76F041 / X76F100 / ZS01 EEPROMs, a
DS2401 serial number), a JVS port, a watchdog, and an I/O board on top. The Digital
I/O board adds an FPGA, 24 MB of DRAM and a MAS3507D MP3 decoder that plays the
games' encrypted MP3 music.

The core is the MiSTer PSX core plus the 573 hardware in Verilog. Most of the 573's
parts are modelled at their pins or registers; a few are re-creations of what an
undumped chip's firmware does (the JVS MCU, the ZS01, the DDR stage board), and two
jobs run on the MiSTer's ARM: decoding the MP3 music (the FPGA is too full for an MP3
decoder) and the memory card reader's CPU. CD audio, the board network and the
analog I/O board are not there yet. The part-by-part table, its sources and the plan
for replacing the high-level parts are in [`docs/EMULATION.md`](docs/EMULATION.md);
the registers are in [`docs/MEMORY_MAP.md`](docs/MEMORY_MAP.md).

Sources, in the order the project trusts them: the
psx-spx System 573 documentation ([site](https://psx-spx.consoledev.net/konamisystem573/);
the newest text is in the repository's
[`docs/arcade/konami/573/`](https://github.com/psx-spx/psx-spx.github.io/tree/master/docs/arcade/konami/573),
written from tests on real boards), Naoki Saito's
[schematics and data sheets](https://github.com/NaokiS28/Konami-System-573-Documentation),
the chips' data sheets, code that runs on real boards (Konami's own drivers,
[573in1](https://github.com/spicyjpeg/573in1)), then MAME's `ksys573` driver.

## Building and testing

* Bitstream: Quartus Prime Lite 17.0.x. `tools/build-573.ps1` (Windows) applies
  `psx_patches/` to the pinned `psx/` submodule and builds `Konami_System_573.rbf`.
  The design fills about 98 % of the FPGA.
* `MiSTer_System573`: `tools/build-hps-mp3.sh all` (Main_MiSTer + `support/s573/`).
* Simulation: `make -C sim` (Icarus Verilog, one or more benches per module) and
  `make -C support/s573/tests test mutate` (the ARM-side service).

[`CONTRIBUTING.md`](CONTRIBUTING.md) has the patch workflow;
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) shows how the pieces fit.

## License

GPL v2 for the core (as the MiSTer framework and the PSX core); `MiSTer_System573` is
Main_MiSTer, GPL v3. Register details come from the psx-spx documentation and the MAME
`ksys573` driver; credit to their authors, to Fabricore, and to the PSX_MiSTer
contributors.
