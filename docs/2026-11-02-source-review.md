# Source review of the whole core (2026-11-02)

**Branch:** `source-review` (on `6a8e367`, the v0.2.1 tree)
**Scope:** every 573-specific RTL module, the firmware's claims about the hardware,
and the public pages (README, `docs/` reference pages), checked against the hardware
documentation first and MAME last. Builds on the 2026-10-23 audit
(`docs/2026-10-23-hw-audit-573in1-sources.md`, F1-F9), whose fixes are all in this
tree and were re-checked here.
**State:** RTL changes below are simulated (benches listed); **not yet built or run
on the SuperStation One.**

## Sources

| # | Source | Version | Used for |
|---|---|---|---|
| S1 | psx-spx `docs/arcade/konami/573/*.md` (psx-spx/psx-spx.github.io, `master`) | `22c3ef7`, 2026-10-31 | registers, I/O boards, cassettes, JVS, BIOS, flash cards. Newer than the 10-23 audit's copy; the 573 commits since then are `b0c10cd`, `d74dfe5`, `6785683` (all 2026-10-25, readback from real boards) |
| S2 | NaokiS28 Konami-System-573-Documentation | `3b981a9`, 2025-11-19 | GX700-PWB schematics, `DataSheets/m48t58y.pdf`, MBM29F017A, GN845-PWB(B) schematic |
| S3 | spicyjpeg/573in1 | `b57da08`, 2025-04-13 | drivers proven on boards |
| S4 | MAS3507D data sheet, ddr4m discs (Konami's drivers) | as in the 10-23 audit | MP3 volume, cassette/DIO drivers |
| S5 | MAME `ksys573.cpp`, `k573dio`, `k573fpga`, `k573cass`, `zs01`, `mas3507d`, `linflash`, `intelfsh` (`dumps/mame573/`) | as supplied | where S1-S4 are silent |
| S6 | fabricore-eng/System573_MiSTer | `6b114d6`, 2026-08-02 | what the original author wrote, to tell their claims from this fork's |

## Changed in this pass

### R1. M48T58: month lengths and leap years (`rtl/m48t58.v`)

S2 `m48t58y.pdf`, "Clock operations": "Corrections for 28, 29 (leap year - valid
until 2100), 30, and 31 day months are made automatically." The model wrapped every
month at day 31 (its header said so: "intentionally simplified"), so 2027-02-28 was
followed by 02-29, 02-30, 02-31, and every 30-day month gained a 31st. A game that
stores dates in the RTC (play logs, bookkeeping) would see impossible dates.

Now `dom_max(month, year)` gives 28/29/30/31; leap year = BCD year divisible by 4.
Bench `tb_m48t58_calendar` (new, in TESTS): 16 month ends, including 2000, 2012,
2014, 2027, 2028. RED on the old model (02-28 -> 02-29 in a common year, 04-30 ->
04-31); GREEN now. `tb_m48t58`, `tb_573in1_rtc` unchanged.

### R2. Digital I/O: the readback values psx-spx measured on 2026-10-25 (`rtl/k573dio_cpld.v`, `rtl/k573dio.v`)

S1 `d74dfe5`: the CPLD status register's unused bits 0-11 **read 1**; the register
reads `0x9fff` with the FPGA cleared and `0xbfff` once configured, and settles the
board-ID bits as 15 = 1, 14 = 0 (which the core already had; the 10-23 audit had
called the old psx-spx table a typo). S1 `6785683`: after configuration
`0x1f6400e0-0x1f6400ee` read `0x1100` -- the value `0xee` returns with both 1-wire
buses idle; `0xee` bit 8 is a second 1-wire bus (an unpopulated DS2433 footprint),
write bit 8 = 1 pulls it low.

Core before: CPLD status `0xb000` / `0x9000` (MAME's constant), `0xe0-0xec` read 0,
`0xee` read only bit 12. Now: `0xbfff` / `0x9fff`; `0xee` reads bit 12 (DS2401) and
bit 8 (DS2433 bus, pulled up, low while the host pulls it), and `0xe0-0xec` read the
same value. Why this is safe: every driver in hand masks the bits it tests (Konami's
DIO driver: `& 0xc000`, `& 0x1000`, `& 0x3000`; 573in1: `& 0x3000`), and a real
board returns these values to all of them.

Benches: `tb_k573dio_cpld` and `tb_k573dio` now expect `0x9fff`/`0xbfff`/`0x8fff`,
and `tb_k573dio` reads `0xe0`, `0xe6`, `0xec`, `0xee` (= `0x1100`) and pulls the
DS2433 bus -- RED on the old RTL, GREEN now.

Not changed, though S1 now documents it: everything that feeds the music position
(listed under D1 below).

### R3. Cassette inputs as the I0-I7 bus (`rtl/s573_seccart.v`, `rtl/s573_io.v`)

S1 builtin-io.md: `0x1f400004` bits 8-15 **are** the cartridge's I0-I7 pins. The core
built that byte in `s573_io.v` from MAME's IN1 bit names ("Network?", "cassette ADC",
"read_line_ds2401") and took the DS2401 from `sec_in[0]`, a bus its port comment
called "I0-I7; I0 = DS2401". The DS2401 is on **I6** (S1 security-cartridges.md).
`sec_in` is now the real I7..I0 (I6 = DS2401, I4 = 1 as MAME's "Network?" = Off) and
`s573_io` passes it through. The register value is bit-for-bit unchanged; this removes
a naming contradiction, not a behaviour. The benches that tapped the bus
(`tb_573in1_cart`, `tb_s573_seccart`, `tb_s573_seccart_dual`) read `sec_in[6]`, and
`tb_s573_io` expects the byte passed through.

### R4. Watchdog timeout (`rtl/watchdog.v`, `rtl/system573_top.v`)

S1 registers.md: the Konami 058232's watchdog bites after 350-400 ms and holds reset
~50 ms. The core's default was 1,000,000 clocks (29.5 ms) with no source. Now 350 ms
(11,854,080 clocks at 33.8688 MHz). It stays **unconnected** to the core reset, as on
a board with jumper S86 fitted (see `docs/EMULATION.md`, plan item 4). No behaviour
change in the build.

### R5. Comments that contradicted the code or the sources

| File | Said | Now |
|---|---|---|
| `s573_seccart.v` header | MAME k573cass wiring: SDA on D0 for X76, on control bit 6 (active low) for ZS01; D2 = CS for all; DS2401 on I0 | the schematic/psx-spx pin table the body has implemented since 10-23 |
| `zs01.v` header | "same CS/RST/SCL/SDA lines"; ZS01 SDA on control bit 6; packet transform "in a single behavioural step"; 0xFC/0xFD "read the internal DS2401" | no CS (psx-spx); one SDA model; the sequential FSM it has been since 09-13; 0xFC = ZS01 serial, 0xFD = DS2401, both answered with the DS2401 (no dump of the other) |
| `k573dio.v` header | "Seven distinct Konami bitstreams"; register map "from MAME"; MP3 decode and network "stubs for now"; CPLD status 0xB000/0x9000 | six (psx-spx `b0c10cd`); each register's source and its psx-spx difference; what runs on the HPS and what is absent |
| `k573dio_cpld.v` | "the psx-spx table lists 14/15 the other way round" | psx-spx corrected it 2026-10-25; unused bits read 1 |
| `mas3507d_i2c.v` | every byte except 0x69 "DROPPED - there is no decoder behind this port yet" | the volume matrix is parsed (F9); the decoder is on the HPS |
| `s573_audio_mix.v` | "SPU ... currently drives AUDIO_L/R directly at emu.sv:1520"; enables "F7" | the two sources as wired; F8 |
| `adc0838.v` | on "the analog I/O board (and the XI security cassette)" | on the PunchMania cartridge (psx-spx); the analog I/O board has only lamp outputs; not used by the build |
| `crc16.v` | CRC "also shows up around the ATAPI / Digital-I/O data paths"; seed unconfirmed | no source says so; not instantiated (zs01.v has its own); psx-spx gives the seed |
| `x76f100.v` | the BIOS bit-bangs it "through the Konami ASIC I/O control/status register"; MAME = "the authoritative reference" | through the cartridge latch 0x1f6a0000; psx-spx's note that Konami seems never to have made X76F100 carts |
| `s573_flash.v` | "AUTHORITATIVE SOURCE = MAME" for the bank map | psx-spx bank table + the 29G decode in the schematic; banks 4-15 mirror on a board (core: 0xFFFF); stock 32 MB cards come as 29F016A or 29F017A |
| `system573_top.v` | EXP1 "driven by ps1_stub in a real build" | the PSX core's EXP1 port |
| `emu.sv` (573 block) | "For the first BIOS-boot bring-up ... refine once the boot screen is confirmed" | why the watchdog bite stays open |

### R6. Public and reference pages

* **README.md** rewritten: what the core is, what runs, how to install, what is
  emulated how (pointing to `docs/EMULATION.md`), and a link to Fabricore's README
  instead of carrying its bring-up history inline. Ricky's own note is kept as he
  wrote it.
* **docs/MEMORY_MAP.md** rewritten from psx-spx. It contradicted the code: it called
  `0x1f400000` bit 8 an "H8 response clock" and `0x1f400004` bits 4-7 an "H8
  response nibble" (psx-spx and `s573_io.v`: JVS MCU reset, status/error codes), and
  said "IO0 = SCL, D0 = SDA" for the X76 cassettes (D1 is SCL; IO0 is SDA).
* **docs/ARCHITECTURE.md** rewritten. It described `ps1_stub.v` and an `emu.sv`
  "placeholder" that are long gone, and the RTC "in the top 16 bytes" (8).
* **PLATFORM.md** moved to `docs/archive/PLATFORM-2026-06.md`: a June 2026 ledger of
  MAME constants (citing a process document and paths that are not in this
  repository); `docs/README.md` called it "reference, kept current". Its content is
  correct history; `docs/EMULATION.md` is the current reference.
* **CONTRIBUTING.md**: `sys/` is not a committed snapshot (the build uses
  `psx/sys/`), and `dumps/README.md` does not exist.
* **docs/STATUS.md**: open items brought up to date (this review's D-list).
* **Release notes v0.2.0** (GitHub, not in the tree) say "Tested on a cabinet with
  DDR Extreme"; the test machine is a SuperStation One. To correct on the release
  page.

## Checked and matching -- no change

* Every EXP1 window, `0x1f400000` bits 0-8, `0x1f400006` bits 0-12, the JAMMA and
  extra-button maps (`0x1f40000c` bit 11 = button 6, idle 1), `0x1f40000e` bit 10 =
  RAM layout (0 = new), the bank latch bits 0-6, `0x1f560000`, `0x1f5c0000`,
  `0x1f6a0000`, the DS2401 CRC (S1 polynomial 0x8c), the cassette IDs, the ZS01 CRC
  (init 0xffff, inverted) -- as the 10-23 audit found, re-read against S1 `22c3ef7`.
* JVS MCU (`s573_jvs_mcu.v`): status/error codes, JVSIRDY/JVSDRDY rules, reset
  behaviour, the BIOS test sequence -- S1 builtin-io.md / bios.md.
* DDR stage board lines: S1 games.md "DDR light mapping" puts stage data/clock on
  A4/A5 and B4/B5 = `0xe0` / `0xe4` bits 12/13, which is what `gn845pwbb.v` uses.
* Flash: ID 0x04/0xAD is a chip Konami's driver accepts (S1 games.md table); the
  stock 32 MB card exists with that chip (and with 0x3D). 16-bit-only access and no
  attribute space (S1 index.md) match the card model.
* PS1 differences (S1 index.md): 4 MB RAM, 2 MB VRAM, SIO0 unused, IRQ10/DMA5 for
  IDE, NTSC only (games.md "Missing support for PAL mode") -- all in `psx_patches/`.
* MAS3507D volume matrix (F9), audio enables (F8): unchanged by S1.

## Differences kept, with the reason (D-list)

D1. **Digital I/O MP3 feeder and counters** (S1 expansion-io.md, mostly the
2026-10-16 commits). The core follows MAME here because these registers carry the
music position the chart scrolls by, and the HPS decoder is what produces it:
* `0xa0/0xa2` read the start address (S1: the live fetch address); `0xa4/0xa6` read
  the end address (S1: the value of `0xae`);
* the feeder sends `[start, end)` (S1: first word from the data latch, then
  start + 2 ... end inclusive; the start word itself is never sent);
* any write to a start/end/key register re-seeds all keys (S1: a key write reloads
  only that key; the key state persists across stop/start and address writes;
  `0xe8` bit 15 clears it);
* `0xaa` bits are MAME's DEMAND / IDLE / PLAYING (S1: PI19 data request, PI8 error,
  PI4 frame sync, WRDY clock ready; reads `0x9000` after configuration);
* `0xa8` counts decoded frames (S1: PI4 rising edges); `0xca-0xce` are MAME's
  counter and diff (S1: a 28-bit LRCK counter; `0xcc` write clears it and holds it
  until the next PI4; `0xce` returns the low word and clears it; held at 0 while
  `0xe8` bit 13 is clear; on Solo it is 16 bits and `0xca` reads `0x7654`);
* two DRAM pointers (S1: one, set by either address pair), and only `0xb4` reads
  data (S1: all of `0xb0-0xbf` return the current word); `0xba` bit 15 (fetch
  enable) and the `0xe8` reset bits are not modelled.
Plan: `docs/EMULATION.md` items 1-3.

D2. **Watchdog not connected** (R4).

D3. **Cassette IRDY reads 1.** S1: set by a cartridge pulsing /IREQ, cleared when
the 573 reads I0-I7; no known cartridge pulses it, so a real board reads 0 after
the first read of `0x1f400004`. No title in hand is known to look; changing it
wants a trace of the BIOS cassette check first.

D4. **Flash banks 4-15 read 0xFFFF** (board: mirror banks 0-3). No software in hand
uses them (10-23 audit O5).

D5. **IDE reset is a pulse.** `0x1f560000` bit 0 = 0 resets the drive model once; on
a board the drive is held in reset while the bit is 0. Software always writes 0,
waits, writes 1, so the two are indistinguishable to it.

D6. **The descrambler scheme is an OSD option** (`573 MP3 Descramble`); on a board
the uploaded bitstream decides it. Plan item 2.

D7. **Behavioural models where the firmware is not dumped:** JVS MCU, ZS01, GN845
stage board. Plan item 7.

D8. **Open from the 10-23 audit, unchanged:** O4 (an empty drive answers TEST UNIT
READY with GOOD), O8 (booting 573in1 needs a 2352-byte image), O10 = D1.

## Before a build

1. `make -C sim` (all benches, including the new `m48t58_calendar`) and
   `make -C support/s573/tests test mutate`.
2. SuperStation One regression: one Digital I/O title to attract with music
   (ddrextrm or ddr4m: the CPLD status change, R2), one X76 cassette title (dsem or
   ddrs2k) and one ZS01 title (ddrusa) through the cassette check (R3), the test
   menu's clock screen (R1), and one install from CD.
