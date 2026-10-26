# Konami System 573 — MiSTer FPGA core

> **Built on Fabricore's System 573 core.** This repository continues the
> work-in-progress Konami System 573 MiSTer core by **Fabricore**:
> **<https://github.com/fabricore-eng/System573_MiSTer>**. Everything up to their
> `main` at `6b114d6` (2026-08-02) is their work, and their full commit history is
> kept here unchanged; the commits after it are this fork's. The board research,
> the 573 RTL, the PSX-core integration over EXP1, the HPS-side MP3 service and
> the first DDR title with music (*DDR Solo Bass Mix*) all come from that
> project. The bring-up history further down this README is theirs.
>
> **What this fork adds**, aimed at the Digital-I/O *Dance Dance Revolution*
> titles: the X76F041 and ZS01 security cassettes on hardware (single and dual
> cassette), the GN845 stage-multiplexor handshake, the 32 MB PCMCIA linear-flash
> card (3rd Mix through Extreme), CD-to-flash installs that persist across title
> switches, 60 fps gameplay with full-speed background video, MP3 streaming fixes
> (song previews, mid-song CD streaming, pause with the OSD), and single
> launchers per title. Current state, by title:
> [`docs/STATUS.md`](docs/STATUS.md).
>
> Like the original, this is GPL v2. No game, BIOS or security-cassette dumps are
> included; you supply your own.

A work-in-progress MiSTer FPGA core for the **Konami System 573**, the
PlayStation-based arcade board behind *Dance Dance Revolution* and the rest of
Konami's BEMANI line (as well as games like *GunMania* and *Hyper Bishi Bashi
Champ*).

## Quick non-AI generated note from me:

This would not exist without work done by human beings such as contributors to MAME (respect to 987123879113 in particular) and the contributors to the PSX_MiSTer core, and it must be mentioned that this core was built on what fabricore made publicly available. I am not a developer. I wanted to play DDR on a MiSTer console with a pad on a CRT, and here we are. This is Claude’s work, not mine. As of 10/18/2026, this core has only been tested with Digital System 573 DDR titles, and no testing has been done with other 573 bemani titles. Off the top of my head, features I wish to include are: (i) Memory Card support; (ii) Analog 573 support (DDR 1st Mix and 2nd Mix); (iii) automatic recognition of DDR solo vs standard DDR games; and (iv) support for other 573 bemani games. One last note: I used MAME non-merged ROMs to test this core.

## Installing and playing

What you need: a DE10-Nano with a 128 MB SDRAM board, the MiSTer SD card, and your
own MAME romsets + CHDs for the titles (`ddr3mj.zip` + its CHD, ...). No game, BIOS
or cassette data is in this repository or its downloads.

Everything below comes ready-made on the
[**Releases page**](https://github.com/illegalmp3/System573_MiSTer/releases), as
three downloads:

| download | what it is |
|---|---|
| `System573_MiSTer-v<version>.zip` | the core, the launchers and `MiSTer_System573` (the music decoder), laid out like the SD card (steps 1, 2 and 4) |
| `s573_stage.py` | the staging tool: builds the game files from your MAME romsets (step 3) |
| `System573_blank_saves.zip` | an empty save file for every title, for staging by hand (step 3) |

1. **Core:** copy `Konami_System_573.rbf` to `_Console/` on the SD card.
2. **Launchers:** copy the `.mgl` files from [`mgl/`](mgl/) to `_Arcade/`. Each one
   is named `<title> (<region>, <year>)` and loads one title;
   [`mgl/README.md`](mgl/README.md) maps them to MAME romsets. Launch a game from its
   launcher, not from the bare `.rbf`.
3. **Game files:** the staging tool, `s573_stage.py` (a release download; the same
   file as [`tools/s573_stage.py`](tools/s573_stage.py)), builds `games/System573/`
   from your MAME romsets. It is one file and needs only Python 3.8 or newer (on
   Windows, install Python from python.org or the Microsoft Store and use `python`
   or `py` in place of `python3`):

       python3 s573_stage.py <folder with your MAME roms> <SD card or USB drive>

   It writes everything a launcher loads -- BIOS, cassette image(s), disc, and an
   empty save file of the right size -- for every title it finds. ROMs are found by
   CRC32 and checked against MAME's SHA1 and discs by the SHA1 in the CHD header, so
   non-merged, split and merged sets all work and file names do not matter. An
   existing `.sav` is never replaced (it holds the game's install), and running it
   again only fills in what is missing. `--list` shows what it found without writing
   anything. Its title table is generated from MAME's `ksys573.cpp` and `mgl/` by
   `tools/gen_s573_titles.py`. (`tools/stage_573.py` is the developer version of
   the same staging, one romset at a time from `dumps/mame573/`.)

   **Blank saves:** every launcher needs its title's `.sav` in `games/System573/`
   before it starts, at the exact size the core expects. The staging tool creates
   them, and `python3 s573_stage.py --blank-saves <SD card or USB drive>` writes only
   them. `System573_blank_saves.zip` holds the same files for anyone staging by
   hand. **Don't extract it over a card that already has saves:** each `.sav` holds
   that game's install, and the blank one would replace it. Copy only the ones you
   are missing.
4. **Music: `MiSTer_System573` (required for the MP3 soundtracks).** The Digital-I/O
   DDR and Dancing Stage titles decode their MP3 music on the ARM side, in a service
   added to MiSTer's Main program (`support/s573/`, built by
   `tools/build-hps-mp3.sh`). It ships as a **separate** file, `MiSTer_System573`,
   that sits next to the stock `MiSTer` in the SD card's root -- the stock binary is
   **not** replaced. Two steps:

   * copy `MiSTer_System573` to the root of the SD card (where `MiSTer` and
     `MiSTer.ini` are);
   * add this section to `MiSTer.ini` (and to any `MiSTer_*.ini` you switch to):

         [System573]
         main=MiSTer_System573

   `python3 s573_stage.py --install-mp3 <SD card>` does both (it keeps a one-time
   `MiSTer.ini.bak573` backup, and running it again changes nothing).

   How it works: when a core starts, stock Main reads `main=` from the INI section
   that matches the core and, if it names another file that exists, restarts into
   it (`user_io.cpp`, `user_io_init`); every other core and the menu use the
   default, `MiSTer`, so Main switches back by itself. The section name has to be
   **`System573`**: Main matches sections against the core's *name*, which for
   this core is the launchers' `<setname>System573</setname>` -- not the `.rbf`
   file name, so `[Konami_System_573]` would never apply. (The `.rbf`'s own
   built-in name is `PSX`, which Main needs for its disc handling; that is also
   why a bare `.rbf` gets no music -- launch from a `.mgl`.) The MiSTer updater
   and `update_all` keep updating the stock `MiSTer` as usual; the Downloader only
   deletes "old file[s] from previous updates" (its `allow_delete` setting), and
   `MiSTer_System573` is not one of its files. Hyper Bishi Bashi Champ and Gacha Gachamp have no MP3 board and do not
   need it.

   **Nothing else on your setup needs updating.** Your own `MiSTer` and Linux
   stay as they are. The one requirement is that your stock `MiSTer` reads
   `main=`, which every stable release since **MiSTer_20240505** (May 2024) does
   (added in Main commit e61b111, 2024-03-25). `MiSTer_System573` is a complete
   Main of its own, built from a stable release's source (the release notes name
   which one) with Main's own pinned toolchain, so it needs nothing newer from
   Linux than stock Main has needed since late 2021 (glibc 2.29, libstdc++
   GLIBCXX 3.4.21). The launchers use only MGL features from 2022 (`setname`,
   `reset`). Without the `main=` line, or on a Main older than 20240505, the
   core still runs, just without music (keep *573 Card Reader* Off then: the
   reader lives in `MiSTer_System573`).

   Upgrading from v0.1.x, which replaced `/media/fat/MiSTer`: put the stock binary
   back (run the updater, or copy your `MiSTer.orig` over `MiSTer`), then do the
   two steps above.
5. **First boot of a CD title installs it to flash:** set OSD *573 Boot Device* =
   CD-ROM, launch, let the game install, and **wait for the "Flash saved" message**
   before switching off (the game asks you to power down before the save has run).
   Then set *573 Boot Device* = Flash ROM and launch again to play.

Video: one bitstream drives HDMI (scaled) and the analog port (RGB / YPbPr / S-Video /
composite, per `MiSTer.ini`) at the same time. Opening the OSD pauses the game and its
music together.

## What this board is

The System 573 is, at its core, a Sony PlayStation:

| Block        | Part                              | Notes                              |
|--------------|-----------------------------------|------------------------------------|
| CPU          | Sony CXD8530CQ (MIPS R3000A)      | 33.8688 MHz, same as retail PS1    |
| GPU          | Sony CXD8561Q                     | 2 MB VRAM (retail PS1 has 1 MB)    |
| SPU          | Sony CXD2925Q                     | 512 KB sound RAM                   |
| Main RAM     | 4 MB                              | retail PS1 has 2 MB                |
| BIOS         | 512 KB Konami BIOS                | boots from CD-ROM / flash          |

On top of the PS1 it adds 573-specific hardware on the EXP1 bus:

- **Konami ASIC I/O** (`0x1f400000`) — JAMMA inputs, coin counters, ADC & security
  cartridge bit-bang lines, audio control.
- **ATAPI CD-ROM** (`0x1f480000`) — game data, booted per title.
- **Bank-switched flash / PCMCIA** (`0x1f000000`, control at `0x1f500000`).
- **Security cartridge** (`0x1f6a0000` + status in the ASIC) — per-game DS2401
  silicon serial number plus an X76F041 / X76F100 / ZS01 secured EEPROM.
- **M48T58 timekeeper** (`0x1f620000`) — battery-backed NVRAM + RTC.
- **ADC0834** serial ADC (bit-banged through the ASIC control register).
- **Watchdog** (`0x1f5c0000`) — resets the board if not kicked.
- **Digital I/O board** (`0x1f640000`, DDR & later BEMANI) — FPGA + **MAS3507D**
  MP3 decoder streaming encrypted audio, plus light outputs and its own DS2401.

The full register map (transcribed from psx-spx) lives in
[`docs/MEMORY_MAP.md`](docs/MEMORY_MAP.md).

## Status — honest accounting

> **Current status lives in [`docs/STATUS.md`](docs/STATUS.md).** The account below was
> written in mid-2026 and is kept as the history of the bring-up; where the two
> disagree, STATUS.md is right.

**Latest milestone (2026-08-02): a DDR title boots, plays, and has working
streamed MP3 music on real hardware.** *Dance Dance Revolution Solo Bass Mix*
(`ddrsbm`) boots from restored onboard flash into attract, plays through a
credited stage, and streams its encrypted MP3 soundtrack — the BEMANI Digital
I/O board path end to end: board DRAM window → descrambler → MP3 decode → PCM
ring → mixed with the PSX SPU.

The decode itself runs on the **HPS (ARM) side, not in fabric**. An in-fabric
Huffman/IMDCT/synthesis decoder was costed at ~3,000–8,000 ALM plus DSP against a
device already at 100% DSP, and rejected on those numbers
([`docs/audits/2026-06-12-ddr-feasibility.md`](docs/audits/2026-06-12-ddr-feasibility.md)).
The fabric owns the descrambler, the streaming controller and the PCM ring; the
ARM owns the decoder.

Two audio defects were found and fixed on 2026-08-02, both firmware-side:

- **Music never stopped.** The service compared a full 16-bit config epoch against
  a field it filled from an 8-bit echo register, so past epoch 255 the two could
  never match, the config re-applied on every poll, and the game's stop was
  overwritten milliseconds later. Measured: 229/229 diverged heartbeats satisfied
  `adopted == fabric % 256`, divergence starting at the first heartbeat past 255.
- **~1.5 s of the previous song replayed at each song change.** Two causes: the
  ring's write pointer was masked to 15 bits while the fabric compares all 16
  including the wrap bit, and nothing discarded already-decoded PCM when a new
  window armed. Measured after the fix: 26 flushes across attract, 1.454–1.476 s
  discarded each, 0/747 epoch divergence, verified out to epoch 1412.

**Known limitation:** the Solo cabinet's song-wheel buttons (*Select L* / *Select
R* — a different register from the dance panels) are not yet wired, so menus
advance with START only. The fix is written and simulated but is deliberately not
in a shipped bitstream: the design sits at **97% ALM and 100% DSP**, and adding it
pushed an already-marginal MiSTer scaler path to −0.11 ns. It lands once resource
recovery buys headroom
([`docs/audits/2026-06-12-resource-recovery-scope.md`](docs/audits/2026-06-12-resource-recovery-scope.md)).

**Previous milestone (2026-06-12): two games boot and run on real hardware.**
Game #1 **hyperbbc** (flash-only) boots, runs, and has audio. Game #2
**hypbbc2p** (*Hyper Bishi Bashi Champ 2P*) — the first **CD-install** title —
now **boots and runs on real hardware** (de10): the authentic `gx908ja.u1`
security cassette clears the on-screen `-11N` BIOS signature wall, the CD/ATAPI
installer copies the disc to onboard flash (the **first hardware exercise of the
CD path**, previously sim-only), the flash programs, the in-game ROM check passes,
and the attract/demo loop runs. So the **security-cassette + CD-install path is
validated on hardware**. Note: hypbbc2p requires the real `gx908ja.u1` dump —
the BIOS reads a boot-time cassette **signature** (cassette block 1) that is
authentic-dump data, not synthesizable from game plaintext, so the real dump is a
required user-supplied artifact (treat it like a BIOS). The MAME-`BAD_DUMP`
`gx908ja.u1` (crc 8900eaff) is functionally complete and works.

The 573-specific hardware is **implemented and unit-tested**, the **PlayStation
core is integrated over EXP1**, the **Konami BIOS executes in full-system
simulation**, and — as of 2026-06-02 — **the core boots that BIOS and displays it
on real MiSTer hardware**: a built `.rbf` brings up the gchgchmp 573 BIOS; the color
bars (initially a CPU i-cache crash, fixed via `psx_patches/` 0004/0005) are now
passed and the BIOS reaches the GX700 power-on self-test (parked at CDR), with a
locked component signal on a CRT (Cyclone V, DE10-Nano-class; verified on a
SuperStation One). There's plenty
left — inputs, CD/security/flash, full game compatibility — but it is a real,
booting core now, not glue around a stub.

**Where it is right now (updated 2026-06-01):**

- **Phases 1 & 2 complete** (merged via reviewed PRs). The MiSTer PSX core
  (`psx/`, vendored as a pinned submodule) is wired to this fabric over the
  PlayStation **EXP1** bus, widened to a full 16-bit master with IRQ10. Those core
  edits live as isolated patches in `psx_patches/`, re-applied by
  `tools/apply_psx_patches.sh` — the submodule pin never moves.
- A **full-system simulation harness** (`sim/system573/`) boots the **Konami
  BIOS** on the integrated core under [**NVC**](https://www.nickg.me.uk/nvc/) (the
  PSX core is VHDL-2008, which Verilator cannot consume — see
  [`docs/PHASE1_PSX.md`](docs/PHASE1_PSX.md)). Verified: the CPU runs from the
  reset vector through the 4 MB RAM test, BSS clear, **main init (`0x1FC05504`)**
  and **GPU init** (the GPUSTAT poll resolves), kicking the 573 watchdog over EXP1
  throughout. `tools/check_boot.py` gates these milestones.
- **Phase 3 — BIOS self-tests on hardware:** the color bars turned out to be a CPU
  i-cache *crash* (wrong instruction word on the cached KSEG0 BIOS mirror), now fixed
  by `psx_patches/` 0004 (i-cache redirect) + 0005 (run BIOS fetches uncached). With
  the 18E (H8/3644) I/O-MCU self-test answered (`rtl/s573_io.v`, PR #16), the BIOS boots
  past the color bars to the GX700 power-on self-test on real hardware. The self-test
  is a sequential gate, now parked at CDR (CD-ROM), the next check. Sim speed was the
  Phase-3 frontier earlier but is no longer the blocker.
- **Phase 4 (hardware) — boots on real hardware:** `rtl/emu.sv` is the real MiSTer
  top — a clone of the proven `psx/PSX.sv` with the 573 EXP1 deltas — and the design
  builds a `.rbf` (Quartus Prime Lite 17.0.x on x86-64 Linux; the `raetro/quartus:17.0`
  Docker image works — Quartus 17.0 is required for this Cyclone V part) that **boots
  the Konami BIOS past the color bars (an i-cache crash now fixed) to the GX700
  power-on self-test, parked at the CDR check**. Getting
  there fixed the Quartus-hostile RTL (`synthesis translate_off`
  guards, M10K NVRAM, constant-folded flash) **and** two build-config defects found
  by an adversarial review — a mis-pinned bitstream (no pin-location files →
  `sys_pins.tcl`) and unmet timing (unsourced `psx/PSX.sdc`). clk_1x/clk_vid now
  meet; clk_2x is ~3 ns short at the worst corner (a polish item). See
  [`docs/PHASE4_HARDWARE.md`](docs/PHASE4_HARDWARE.md).

A complete System 573 core has to sit on top of a full PlayStation 1 (the kind of
effort that took the MiSTer PSX core years); this repo implements and
**unit-tests** the 573-specific glue around that PS1 and integrates a mature PS1
core underneath it.

| Module                         | File                  | State                  |
|--------------------------------|-----------------------|------------------------|
| DS2401 1-Wire serial number    | `rtl/ds2401.v`        | ✅ implemented + tested |
| ADC0834 serial ADC             | `rtl/adc0834.v`       | ✅ implemented + tested |
| ADC0838 8-channel serial ADC   | `rtl/adc0838.v`       | ✅ implemented + tested |
| M48T58 RTC + NVRAM             | `rtl/m48t58.v`        | ✅ implemented + tested |
| Watchdog timer                 | `rtl/watchdog.v`      | ✅ implemented + tested |
| Konami ASIC I/O register block | `rtl/s573_io.v`       | ✅ implemented + tested |
| EXP1 address decoder           | `rtl/s573_bus.v`      | ✅ implemented + tested |
| X76F100 security EEPROM        | `rtl/x76f100.v`       | ✅ implemented + tested |
| X76F041 security EEPROM        | `rtl/x76f041.v`       | ✅ implemented + tested |
| CRC-16/CCITT engine (ZS01)     | `rtl/crc16.v`         | ✅ implemented + tested |
| ZS01 (NS2K001) security PIC    | `rtl/zs01.v`          | ✅ implemented + tested |
| Digital I/O board registers    | `rtl/k573dio.v`       | ✅ lamps/RAM/keys/DS2401 |
| MP3 audio descrambler          | `rtl/k573_mp3dec.v`   | ✅ implemented + tested |
| MP3 streaming controller       | `rtl/k573_mp3stream.v`| ✅ implemented + tested |
| ATAPI task-file + PACKET + READ | `rtl/atapi.v`        | ✅ subset impl + tested |
| Bank-switched flash (NOR-backed) | `rtl/s573_flash.v`  | ✅ banking impl + tested |
| NOR flash command engine       | `rtl/flash_nor.v`     | ✅ implemented + tested |
| Security-cartridge bus glue    | `rtl/s573_seccart.v`  | ✅ implemented + tested |
| PS1 CPU/GPU/SPU subsystem      | `psx/` submodule      | ✅ integrated in sim (EXP1) |
| MiSTer top level               | `rtl/emu.sv`          | ✅ PSX.sv clone + 573 deltas; **boots BIOS on real hardware** |
| MP3 PCM ring (fabric reader)   | `rtl/s573_pcm_ring.v` | ✅ implemented + tested |
| MP3 PCM drain + gain           | `rtl/s573_mp3_pcm.v`  | ✅ implemented + tested |
| MAS3507D I²C + gain matrix     | `rtl/mas3507d_i2c.v`  | ✅ implemented + tested |
| SPU + MP3 saturating mixer     | `rtl/s573_audio_mix.v`| ✅ implemented + tested |
| MP3 decode (HPS-side service)  | Main fork `support/s573/` | ✅ **plays on real hardware** |
| DDR Solo song-wheel inputs     | `rtl/s573_io.v`       | 🏗️ written + simulated, not in a shipped bitstream (no timing headroom) |

✅ = real RTL with a passing testbench (or, for `psx/`, executing the BIOS in the
full-system NVC sim). 🏗️ = real RTL that synthesizes but isn't hardware-verified
yet. 📋 = docs only.

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the phases and
[`docs/EXECUTION_PLAN.md`](docs/EXECUTION_PLAN.md) for the detailed plan from here
to full game compatibility (PSX integration, hardware bring-up on MiSTer, and the
ordered file/dump manifest in [`dumps/README.md`](dumps/README.md)).

## Building / testing

The 573-specific RTL is plain Verilog-2005 and is verified with
[Icarus Verilog](https://steveicarus.github.io/iverilog/):

```sh
cd sim
make            # run every testbench, report PASS/FAIL
make ds2401     # run a single module's testbench
```

On Ubuntu, `iverilog` comes from `apt-get install -y iverilog`. A Claude Code
`SessionStart` hook (`.claude/hooks/session-start.sh`, wired up in
`.claude/settings.json`) installs the toolchain and runs the suite automatically
at the start of each web session.

### Full-system boot simulation (NVC)

The PlayStation core is VHDL-2008 (Verilator can't consume it), so the
full-system boot runs under [NVC](https://www.nickg.me.uk/nvc/):

```sh
brew install nvc                          # one-time
sim/system573/run.sh [STOP_TIME] [RAM8MB] # e.g. sim/system573/run.sh 5ms 1
REUSE=1 sim/system573/run.sh 20ms         # re-run a built design at a new stop-time
```

It applies `psx_patches/`, builds the core under NVC, loads the Konami
game-in-BIOS image, runs, and writes traces + a framebuffer dump to the
git-ignored `sim/system573/build/`. Convert the framebuffer to PNG with
`tools/gra2png.py`, and check how far the boot got with:

```sh
tools/check_boot.py sim/system573/build   # report which boot milestones were reached
```

See [`sim/system573/README.md`](sim/system573/README.md) for the harness details
and the current furthest-verified point.

FPGA synthesis targets the standard MiSTer framework: the `sys/` directory is
where the [MiSTer-devel `Template_MiSTer`](https://github.com/MiSTer-devel/Template_MiSTer)
`sys` submodule belongs, and `rtl/emu.sv` is the `emu` top level it instantiates.

## License

RTL in this repository is released under the **GNU GPL v2** to match the MiSTer
framework it is intended to plug into. Hardware register details are transcribed
from the community [psx-spx](https://psx-spx.consoledev.net/konamisystem573/)
documentation and the MAME `ksys573` driver.
