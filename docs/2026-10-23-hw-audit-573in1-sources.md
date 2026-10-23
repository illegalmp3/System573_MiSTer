# Hardware audit against non-MAME sources (573in1, NaokiS28 schematics, Naoki's video)

**Date:** 2026-10-23
**Branch:** `hw-audit-573in1` (on top of `5bcd741`, the public v0.1.1 tree)
**Status:** 3 RTL fixes + 1 portability fix, simulated: 67/67 suite benches green
**with the real game-dump fixtures** (pnchmn2, gtrfrk5m, ddrusa, ddr4m, ddr3ma).
**Not yet built or cabinet-tested.**

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

## New benches

| bench | replays | before -> after |
|---|---|---|
| `tb_573in1_ide` (in TESTS) | `ide.cpp` enumerate both devices, TEST UNIT READY, PIO READ | RED (phantom dev 1) -> GREEN |
| `tb_573in1_rtc` (in TESTS) | `io.cpp` setRTCTime/getRTCTime/isRTCBatteryLow across a midnight, month end and century | RED (date 03-14 -> 04-01) -> GREEN |
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

**O1. DIO CPLD status `0xf6` is a constant `0xB000` (copied from MAME).**
573in1 `loadDigitalIORawBitstream` writes `0xf4 = 0`, `0xf6 = 0x8000, 0xC000, 0xF000`,
waits 5 ms and requires INIT = 1, DONE = 0 (`(stat & 0x3000) == 0x1000`), streams the
bitstream on `0xf8` bit 15, waits 50 ms and requires INIT = DONE = 1. With the constant it
retries three times, logs "bitstream upload failed" and skips the board DS2401. Real
hardware: those bits are the XCS40XL INIT/DONE pins. Our `data/fpga.bit` parse: preamble
`0010` at bit 8, 24-bit length count 330,689, 330,696 data bits -- so DONE can be modelled
from the stream itself. **Missing:** Konami's exact control-write sequence. ddrsbm checks
`0xf6 & 0xc000 == 0x8000` around its programming path
(`docs/2026-07-01-ddrsbm-dio-i2c-transactions.md`) and under MAME streams the bitstream
on `0xf8` (`docs/2026-07-31-mame-oracle-gc-trap.md`), but MAME's own note says Konami
writes only `0x8000` to `0xf6` -- if that is the whole sequence, bit 14 (PROGRAM in
573in1's naming) never rises, and a DONE-low model would trap every DIO title. `tools/mame_dio_regs.lua` already logs `f4/f6/f8`; one run on a title that
uploads (ddrextrm) settles it.

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

**O3. `0x1f400000` bits 5/6/7 (amp enable / CD-DA-aux input enable / SPU DAC enable).**
573in1 names bit 6 `CDDA_ENABLE`; S3 says the digital board's MP3 audio enters through
that same CD-audio input. The core ignores all three (MP3 and SPU always audible).
Polarity of bit 6 is unconfirmed (our memory map calls it "mute"); trace a Konami title
before gating audio on it.

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

## Before a build

1. On the build PC with dumps present: `cd sim && make` (the three dump-fed benches --
   `s573_seccart`, `s573_seccart_dual`, `zs01` -- are the real-dump proof of F1 for
   pnchmn2 X76F041, ddr4m/ddr3ma dual cassettes and gtrfrk5m ZS01) and
   `make gate5_replay 573in1_cart`.
2. Cabinet regression set for F1/F2: hyperbbc or ddrs2k (X76F100 + BIOS identify),
   dsem (X76F041), ddrusa (ZS01), ddr4m and ddr3ma (dual cassette), plus one flash-boot
   and one CD-install boot (drive check, F2).
