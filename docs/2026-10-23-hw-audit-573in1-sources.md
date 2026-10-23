# Hardware audit against non-MAME sources (573in1, NaokiS28 schematics, Naoki's video, psx-spx)

**Date:** 2026-10-23
**Branch:** `hw-audit-573in1` (on top of `5bcd741`, the public v0.1.1 tree)
**Status:** 5 RTL fixes + 1 portability fix, simulated: 68/68 suite benches green
**with the real game-dump fixtures** (pnchmn2, gtrfrk5m, ddrusa, ddr4m, ddr3ma) and
573in1's own Digital I/O bitstream. **Not yet built or cabinet-tested.**

Update 2 (same day, psx-spx /dev/ System 573 pages, S4): F5 (Digital I/O CPLD) and F6
(ZS01 has no CS and no exposed DS2401) added; O1 closed by F5; O3 rewritten (the
sources disagree on bit 7, so no audio gating). psx-spx independently confirms F1.

Update (same day, with the dumps): two bench expectations that had never run were
wrong and are corrected -- `tb_s573_seccart` expected pnchmn2 BCR2 = 0x00 (the dump
holds 0xff; fails identically on the pre-audit RTL), and `tb_zs01_rtr` expected the
id to read back with the SDA driver ENABLED and D0 = 0, which the 74LS125 makes
impossible (the game releases bit 6 first). And `sim/Makefile` ran
`sh gen_secdata.sh`; the script uses `set -o pipefail`, which dash (Ubuntu/WSL `sh`)
rejects, so on those hosts the fixtures were never generated. Now `bash`.

## Sources used

| # | Source | Version read | What it is good for |
|---|---|---|---|
| S1 | spicyjpeg/573in1 | `b57da08` (2025-04-13) | Register/bit definitions (`src/ps1/registers573.h`), drivers proven on real boards (`src/common/io.cpp`, `ide.cpp`, `rom.cpp`, `romdrivers.cpp`, `src/main/cart/cartio.cpp`), its own DIO FPGA design (`fpga/src/main.v`, `doc/fpga.md`, `data/fpga.bit`) |
| S2 | NaokiS28/Konami-System-573-Documentation | `3b981a9` (2025-11-19) | GX700-PWB KiCad schematics, M48T58Y datasheet, Konami flash-card schematic + MBM29F017A datasheet. **The author flags the security-cart sheet as unverified** -- every conclusion below that uses it is cross-checked against S1 or game code. |
| S3 | "Konami's System 573 - Everything you wanted to know about it!" (Naoki's Retro Corner, 2022-10-05) | author's English (UK) caption track | Watchdog part/timeout, IDE PIO-only, PCMCIA single-CE wiring, audio path of the I/O boards |
| S4 | psx-spx "Konami System 573" (`psx-spx.consoledev.net/dev/arcade/konami/573/`, repo `psx-spx/psx-spx.github.io` `b56e4c5`, 2026-10-23) | `registers.md`, `builtin-io.md`, `expansion-io.md`, `security-cartridges.md` | Hardware-tested register behaviour: DIO CPLD/FPGA map, cassette pinouts per variant, audio-control bits, watchdog |
| ref | MAME `cde9d51` (2026-10-23): `ksys573.cpp`, `k573dio.cpp`, `x76f041.cpp`, `atahle.cpp`, `linflash.cpp` | | Baseline the core was built from |

Schematic connectivity was extracted with a small KiCad-sheet netlister (wires, labels,
pin positions); every net quoted below is from that output, not read off a picture.

## Fixed

### F1. Cassette SDA: one electrical model for every cassette (`rtl/s573_seccart.v`)

**Schematic (S2, Ksys573 + Security-cart sheets):** bank latch 27G (`0x1f500000`) Q6 =
bit 6 -> 74LS14 24E (13->12) -> **/OE of 74LS125 gate 35H (pin 10)**. That gate's input
(pin 9) is cart latch 35K Q0 = **D0**, its output (pin 8) is **cart pin 28**, which is
also the net the ASIC reads back (`KCUS-93` -> `0x1f400006` bit 2). So the host level on
SDA is `bit6 ? D0 : released`.

**Real-hardware drivers that all agree with that, and only with that:**
* 573in1 `CartI2CDriver::_setSDA`: forces D0 = 0 and moves SDA with bit 6 alone, for
  X76F041, X76F100 **and** ZS01 cassettes.
* Konami X76 driver (ddrusa PSX.EXE, `docs/2026-09-14-ddrusa-zs01-sda-is-control-bit6.md`):
  data on D0, bit 6 set to drive, cleared before a read.
* Konami ZS01 driver (same doc): never writes D0 (stays 0), SDA by bit 6 alone.

**Core before:** X76 models took SDA = D0 and ignored bit 6; ZS01 took SDA = ~bit6 and
ignored D0 (both exactly MAME `k573cass.cpp`). Under 573in1's driver an X76 cassette
answered the reset-ID probe (that needs no host SDA) and then never saw a START, so every
read/write failed.

**Now:** `host_sda = io0_dir ? D0 : 1` feeds all four EEPROM models; read-back is
`device_sda & host_sda` (the wired line). For the ZS01 this is identical to the old
`~io0_dir` whenever D0 = 0, which is the only state the Konami ZS01 driver uses.

Bench updates (they modelled drivers that cannot work on the board): `tb_s573_seccart`
now drives with bit 6 set for byte transfers and releases it for the BIOS identify RTR
read; `tb_s573_seccart_dual` sets the enable in `x_select` and for its X76-only DUT.

### F2. IDE: the CR-589 is a lone device 0 (`rtl/atapi.v`)

573in1 `Device::enumerate` probes **both** IDE devices. Its own comment, and MAME
`atahle.cpp` (`m_single_device`), say a lone device 0 shadows the task-file registers
for device 1 but reads STATUS as 0, ignores COMMAND/DATA and does not drive INTRQ.
`atapi.v` ignored the DEV bit, so the device-1 probe found a phantom second CD-ROM.
Now, with device/head bit 4 set: status/alt-status read 0, command and data accesses
are ignored, the status read does not clear INTRQ, and INTRQ is masked.

### F3. M48T58: control bits are not part of the count (`rtl/m48t58.v`)

M48T58Y datasheet Table 5 (S2 `DataSheets/m48t58y.pdf`): DATE bit 7 = BLE, bit 6 = BL
(read-only); DAY bit 6 = FT, bit 5 = CEB, bit 4 = CB. 573in1 `setRTCTime` writes
`WEEKDAY | CB | CEB` and `DATE | BLE`. The model incremented the whole byte, so at the
next midnight `0xB1`-style values hit the "> max" branch: the date jumped to the 1st of
the next month and the weekday reset to 1. Now only the BCD fields count, control bits
are preserved, BL reads 0 (battery good; 573in1 `isRTCBatteryLow` reads it), and CB
toggles at the 99->00 rollover when CEB is set.

### F4. Portability: `rtl/s573_cdtoc.v` declared `pend_start/pend_audio` after first use

Icarus 13+ rejects that; six benches (system573_top, zs01_detect, drivecheck, cdboot,
atapi_inquiry, s573_cdtoc) did not compile. Declarations moved up; no logic change.

### F5. Digital I/O CPLD: real FPGA configuration status (`rtl/k573dio_cpld.v`, new)

Closes O1. psx-spx (S4, `expansion-io.md` "0x1f6400f6"): status bit 12 = /INIT, 13 =
DONE from the FPGA; control writes 12 = /INIT, 13 = DONE, 14 = /PROGRAM; **Konami's
driver writes `0x8000`, then `0xc000`, then `0xf000`** before streaming the 41,337-byte
image on `0xf8` bit 15 -- the same three writes 573in1 uses, which settles the doubt
raised by MAME's one-line note ("write 8000 to +f6.w"). Also from S4: **every register in
`0xf0-0xff` reads back the `0xf6` value** (incomplete CPLD decode), `0xf4` bit 15 is the
DAC reset (0 = reset), and the bitstream is 330,696 bits.

Core before: `0xf6` = constant `0xB000` (MAME), other `0xf0-0xfe` read 0. 573in1 needs
`(0xf6 & 0x3000) == 0x1000` before the upload, so it retried three times, logged
"bitstream upload failed" and never read the board DS2401.

Now: a small CPLD + FPGA-config model. `/PROGRAM` low (or reset) clears the FPGA;
/INIT reads high 64 clocks (~2 us) after `/PROGRAM` rises and the CPLD stops holding it
low (MAME shows /INIT = 1 at all times and every Konami title boots on it; 573in1 waits
5 ms -- 2 us satisfies both); DONE rises when the bit count reaches the length count
parsed from the stream itself (>= 4 ones, preamble `0010`, 24-bit count -- 573in1's
`fpga.bit`: 330,689, i.e. 7 bits before the end), or at 330,696 bits if no preamble is
seen. CPLD drive bits 12/13 are open-drain: 0 holds the line low. Status after a full
upload is `0xB000`, MAME's constant, so nothing Konami checks after programming changes.
"LSB first" in S4 is byte storage order only: both drivers reverse it in software, so
the serial stream at DIN is identical either way (bench case 2 proves the model
does not care). Board-ID bits stay bit 15 = 1, bit 14 = 0 (MAME's `0xB000`, 573in1
`isDigitalIOPresent`, ddrsbm `& 0xc000 == 0x8000`); S4's table has 14/15 swapped --
three code sources against one table, so the table is taken as the typo.

Same pass, from S4: FPGA magic `0x1234` now reads across `0x80-0x9f` and `0xd0-0xdf`
(S4: "the magic number at 0x1f640080 is mirrored throughout ..."), and `0xc6`/`0xc8`
read `0x7654`. `0xf4` bit 15 is latched to a `dac_en` port (reset 1) but **not yet used
to mute MP3 audio** -- see O9.

### F6. ZS01 cassette: no chip select, no DS2401 on D4/I6 (`rtl/s573_seccart.v`)

psx-spx `security-cartridges.md` "ZS01 cartridge variants": the ZS01 pins are `/DSR`,
D0 (SDA drive via IO0), D1 (SCL), D3 (reset), IO0 (SDA readout) -- **no D2**; and "All
cartridges are fitted with a DS2401, however it is connected to a GPIO pin on the
ZS01 rather than being directly exposed to the 573". 573in1 agrees on both:
`I2CDriver::resetZS01` -- "the reset pin is also active-low ... and CS is ignored" --
and `ZS01Driver::readCartID` reads the serial through ZS01 command address
`ZS01_ADDR_DS2401_ID`, never through D4. MAME `k573cass.cpp` (ZI device) wires D2 to
`write_cs` and D4 to the DS2401; the core had copied that.

Now the ZS01 model's CS is tied active whenever the ZS01 cassette is selected, and the
game cassette's DS2401 does not pull I6 when it is a ZS01 (zs01.v still serves the same
`.u6` serial internally). The install cassette (X76F041/X76F100) keeps its DS2401 on
D4/I6, per S4's X76F041 pin table. Konami's ZS01 driver never relies on either
(it leaves D2 low and reads the ID through the ZS01), so this only removes behaviour
real cassettes do not have.

Bench updates: `tb_s573_seccart_dual` A3 expected the ddr4m ZS01 game cassette's
serial on I6 (modelled on MAME); it now asserts no 1-Wire presence there and that the
install cassette's DS2401 still answers. `tb_573in1_cart` ran its cassette-DS2401 step
with the ZS01 selected, which 573in1 never does (`X76Driver::readCartID` only); it now
asserts silence on I6 for the ZS01 and reads the serial with an X76 cassette.
Related, not changed: S4 gives ZS01 address `0xfc` as the ZS01's own internal serial
and `0xfd` as the DS2401; `zs01.v` (like MAME) returns the DS2401 for both. No dump of
the internal serial exists and S4 says games do not use it.

## New benches

| bench | replays | before -> after |
|---|---|---|
| `tb_573in1_ide` (in TESTS) | `ide.cpp` enumerate both devices, TEST UNIT READY, PIO READ | RED (phantom dev 1) -> GREEN |
| `tb_573in1_rtc` (in TESTS) | `io.cpp` setRTCTime/getRTCTime/isRTCBatteryLow across a midnight, month end and century | RED (date 03-14 -> 04-01) -> GREEN |
| `tb_k573dio_cpld` (in TESTS) | 573in1 `loadDigitalIORawBitstream` with its real `data/fpga.bit` (MSB writer), the same stream as a Konami-style LSB-first image, a synthetic header stream, a no-preamble stream, CPLD DONE hold, back-to-back control writes, `0xf0-0xfe` mirror, `0xf4` | RED (status 0xB000 before upload) -> GREEN |
| `tb_573in1_cart` (standalone, `make 573in1_cart`) | `io.cpp` + `cartio.cpp`: ZS01-then-X76 detection, X76F100/X76F041 reads, cassette DS2401 | X76F100 read RED -> GREEN; **X76F041 read still RED** (O2) |

## Matches -- checked, no change needed

* Every EXP1 window address in `registers573.h` = `s573_bus.v`.
* `0x1f400000` bits 0-8, `0x1f400006` bits 0-12, JAMMA/extra-button maps, `0x1f40000c`
  bit 10 = TEST, `0x1f40000e` bit 10 = RAM layout strap, DIP active-low,
  cassette DS2401 on I6 (`0x1f400004` bit 14) driven low by D4.
* Bank register: bits 1:0 pick the onboard pair through 74LS139 29G section B
  (00 -> 31M/27M, 01 -> 31L/27L, 10 -> 31J/27J, 11 -> 31H/27H), bits 5:4 through section
  A pick onboard / slot B / slot A; bits 3:0 are card A22-A25. Same as MAME and the core.
* Flash JEDEC flow (`rom.cpp getJEDECID/getActualLength`, `romdrivers.cpp`): 0x555/0x2AA
  word commands, both lanes, DQ7 polling; core returns 0x0404/0xADAD = MBM29F016A, which
  573in1 accepts. Card mirroring for size detection works (pair = bank[2:0]).
* PCMCIA card detect polarity (0 = inserted) = `JAMMA_PCMCIA_CD1/2` inverted read.
* IDE register stride (16-bit), CS1 register 6, 0xEB14 signature after SRST, IDENTIFY
  PACKET word 0 (CD-ROM, 12-byte packets), word 255 checksum skip, SET FEATURES, PIO
  data with the byte count in the cylinder registers. S3 confirms the drive side is PIO only.
* EXP1 decode is fixed at `0x1f000000-0x1f7fffff`, so 573in1 moving `BIU_DEV0_ADDR` to
  `0x1f480000` (for its IDE DMA) does not move the 573 windows. Its BIU timing value is
  identical to the Konami BIOS's (`0x24173f47`).
* DIO `0xee` 1-Wire (write bit 12 = 1 pulls low, read bit 12) and lamp registers
  (`0xe0-0xe6`, `0xfa-0xfe`, bits 15:12) behave the same under Konami's and 573in1's
  bitstreams.

## Open -- deliberately NOT changed (need one more piece of evidence each)

**O1. (closed by F5.)** The missing piece -- Konami's control-write sequence -- is in
S4: `0x8000`, `0xc000`, `0xf000`, then the upload.

**O2. X76F041 re-addressed read (573in1 `X76F041Driver::readPrivateData`).**
Now settled by the Xicor X76F041 datasheet (supplied 2026-10-23), pages 6 and 9-11:
* Operational-modes table: first byte `001xxxxA` = read with the READ password,
  `011xxxxA` = read with the CONFIGURATION password, `100xxxxx` = configuration ops.
* Random/sequential read WITH a password (Fig. 8, 10, 12 -- the `0x60` config read is
  the same shape): command, address, 8-byte password, ACK-poll `0xC0`, then the chip
  outputs **8 bits of "secure read setup" to be ignored**; the host then issues a
  START and an address and reads data. "Once the first byte has been read, another
  start can be issued followed by a new 8-bit address" -- **no password again**,
  within the original 1K block only.
* Random read WITHOUT a password (Fig. 9): command, address, ACK, data at once;
  further START + address within the block.
That is exactly 573in1's sequence. `x76f041.v` (and MAME `x76f041.cpp`) has no setup
byte -- the first byte after the poll is `data[address]` -- and turns the repeated
START into a fresh `load_address()`, which for `0x60` demands the password again.
**Not changed yet**, deliberately: Konami's own X76F041 traffic (dsem, the ddr4m and
ddr3ma-class install cassettes) works on the core today under MAME's semantics, so
the sequence Konami actually sends must be read before the model is made
datasheet-exact. The Konami X76F041 driver is in the CD executables (it is not in the
700A01/700B01 BIOS: neither contains a single `0x1f6a` reference), so one CHD
(dsem or ddr4m) to extract `PSX.EXE` from, or the `hw_audit_tap.lua` MAME log of
dsem, settles it. `tb_573in1_cart` stays RED on this step until then.

**O3. `0x1f400000` bits 5/6/7 -- the sources disagree; nothing gated.**
S4 (`builtin-io.md`): 5 = built-in amp enable (RCA line outputs unaffected), 6 = external
(CD/DIO) audio input enable, measured as an attenuator rather than a hard mute, and
meaningless on GuitarFreaks-style cabinets that route MP3 to separate jacks; 7 = "SPU
DAC output enable (0 = muted)". But 573in1 -- same author -- writes bit 7 = 0 in
`io::init()` and never sets it (`MISC_OUT_SPU_ENABLE` has no user), while its UI and
audio test play SPU sound. Gating the SPU on bit 7 would silence 573in1 if S4's
polarity is wrong. Port comments in `s573_io.v` now state the bit meanings (the port
called `audio_mute` is bit 6, an ENABLE); MiSTer outputs are line level, so bit 5 never
applies. To settle bit 7: a scope or ear on a real 573 running 573in1's audio test
(SPU tone with bit 7 = 0), or a Konami title's write log.

**O4. Empty drive answers TEST UNIT READY with GOOD.** A real CR-589 with no disc
reports NOT READY. Only matters for 573in1 run with no CD; changing it touches the BIOS
drive-check path, so it wants a MAME trace of the BIOS with no disc first.

**O5. Banks 4-15 / 48-63.** Per 29G, onboard decode ignores bank bits 3:2, so banks
4-15 mirror 0-3; bits 5:4 = 11 select nothing. Core returns 0xFFFF for 4-15. No known
software uses them.

**O6. Konami flash card chips are 29F017 (S2 flash-card schematic); MBM29F017A Table 3
gives device code 0x3D.** Core and MAME report 0xAD (29F016A). Games accept both; leave.

**O7. Watchdog (S3): Konami 058232, must be strobed within 350 ms.** `watchdog.v` is not
wired to reset (correctly, for now) and its default timeout is 1,000,000 clk1x = 29.5 ms.
If it is ever wired, use ~350 ms.

**O8. Booting 573in1 on the core.** Its CD release is a 2048-byte-sector ISO; the core
mounts CHD or cue + raw 2352-byte bins, so the image needs converting
(`tools/chd_to_raw2352.py` already holds the MODE1/2048 -> 2352 recipe). These sources
do not show what stops it booting under MAME; none of O1-O7 is fatal to its startup.

**O9. DIO `0xf4` DAC reset not applied to MP3 audio.** S4: "Konami's code uses this
register to mute the DAC during FPGA and MAS3507D initialization." The latch exists
(`k573dio.dac_en`, reset 1) but is unconnected: the exact Konami write order (which
value it leaves behind) is not in any source here, and getting it wrong mutes every MP3
title. `tools/mame_dio_regs.lua` logs `f4` writes; one MAME run of a DIO title shows the
final value. 573in1 writes 0 and never re-enables (it plays no MP3).

**O10. psx-spx DIO details that differ from the core's MAME-derived model** (MP3 path
is HPS-side and not yet live, so none is changed in this pass; each matters for P4):
* MP3 feeder: "The first word fetched from DRAM is the one at the start address plus
  2; the word at the start address itself is never sent", and the word at the end
  address IS sent (fetch address ends at end + 4). `k573_mp3stream.v` sends
  `[mp3_start, mp3_end)`. With a per-word descrambler counter an extra/missing word
  shifts the key stream, so check this against a real title before P4 sign-off.
* DRAM: "There is a single DRAM address pointer, used for both reads and writes" --
  `0xb0/b2` and `0xb6/b8` both set it, only `0xb4` reads advance and prefetch, and every
  `0xb0-0xbf` read returns the current word. The core (like MAME) keeps two pointers.
  Konami's loaders always set the matching pointer before use, so no known title can
  tell; 573in1's bitstream is not used by the core.
* `0xca`/`0xcc`/`0xce` sample counter: 28-bit LRCK counter, `0xce` returns `0xcc` and
  clears bits 0-15 (3rdMIX), Solo Bass Mix reads `0xca` as `0x7654`; held at 0 while
  `0xe8` bit 13 is clear. The core models MAME's counter/diff pair and ignores `0xe8`.
* Before a bitstream is loaded the real FPGA registers (`0x80-0xef`) do not answer; the
  core always presents Konami's map. Every DIO title uploads first, so this is inert.

**O11. Watchdog (S4 agrees with S3): 350-400 ms, reset held ~50 ms; jumper S86
disables it.** Same conclusion as O7.

## psx-spx cross-check -- matches

* F1's electrical model is stated outright in S4 `registers.md` "0x1f500000": bit 6 is
  the `IO0` direction, "If set, IO0 will output the same logic level as D0".
* X76F041 / X76F100 / ZS01 response-to-reset IDs (`19 55 aa 55`, `19 00 aa 55` LSB
  first; `5a 53 00 01` MSB first) = the core's models and 573in1.
* X76F041 cassette pins (D0 SDA via IO0, D1 SCL, D2 /CS, D3 reset, D4/I6 DS2401) = core.
* ZS01 12-byte packets with CRC-16 poly 0x1021 = `zs01.v` (the ddrusa/gtrfrk5m dump
  benches exercise it). S4 gives the scrambler as the HOST-side algorithm; `zs01.v`
  implements MAME's device-side cipher, so the two were not compared line by line.
* DIO `0xee` (write bit 12 = 1 pulls the 1-Wire line low, read bit 12) and the lamp
  bank addresses `0xe0-0xe6`, `0xfa-0xfe` (bits 15:12) = core.
* IDE via DMA5 is the drive's PIO data port read as a burst (S4 `registers.md`), which
  is what the core's hardwired DMA5 -> `atapi.v` data-port path does.

## Before a build

1. On the build PC with dumps present: `cd sim && make` (the three dump-fed benches --
   `s573_seccart`, `s573_seccart_dual`, `zs01` -- are the real-dump proof of F1 for
   pnchmn2 X76F041, ddr4m/ddr3ma dual cassettes and gtrfrk5m ZS01) and
   `make gate5_replay 573in1_cart`. `tb_k573dio_cpld` uses 573in1's real `data/fpga.bit`
   when a 573in1 checkout sits next to this repo (or `S573IN1=<path>`); without it the
   synthetic-stream cases still run.
2. Cabinet regression set for F1/F2/F5/F6: hyperbbc or ddrs2k (X76F100 + BIOS identify),
   dsem (X76F041), ddrusa (ZS01), ddr4m and ddr3ma (dual cassette), plus one flash-boot
   and one CD-install boot (drive check, F2). F5: any DIO title boots to attract
   with MP3 (ddr3ma/ddr4m/ddrextrm), and 573in1's cartridge screen shows the Digital
   I/O board ID instead of "bitstream upload failed". F6: ddrusa / gtrfrk5m (ZS01)
   still pass the cassette check; ddr4m's dual cassette still installs.
