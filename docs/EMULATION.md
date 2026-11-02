# What the core emulates, and how

The living reference for **what each part of the System 573 is in this core**: a
model of the real chip at its pins or registers ("hardware model"), a
re-implementation of what a chip's firmware does ("behavioural"), something done on
the MiSTer's ARM side ("HPS"), or absent. Last checked against the sources on
2026-11-02 (`docs/2026-11-02-source-review.md`).

Sources, in the order this project trusts them:

1. hardware documentation: the psx-spx System 573 pages
   (`psx-spx/psx-spx.github.io`, `docs/arcade/konami/573/`, written from tests on real
   boards), the NaokiS28 *Konami-System-573-Documentation* schematics and data sheets
   (GX700-PWB main board, M48T58Y, MBM29F017A, HD6433640, GN845-PWB), the Micronas
   MAS3507D data sheet, Toshiba's TMPR3904F manual;
2. software that runs on real boards: Konami's own drivers read out of the game discs,
   spicyjpeg's 573in1;
3. MAME (`ksys573.cpp` and its devices), for whatever the first two do not cover.

## The board, part by part

| Part | Real hardware | In this core | Kind | Main sources |
|---|---|---|---|---|
| CPU, GTE, GPU, SPU, MDEC, DMA, timers, IRQ | Sony CXD8530CQ / CXD8561Q / CXD2925Q | the MiSTer PSX core (`psx/`), with the 573's 4 MB main RAM (patch 0022), 2 MB VRAM (0021), DMA5 to the IDE port (0023), NTSC only | hardware model | PSX_MiSTer; psx-spx "Differences vs. PS1" |
| EXP1 decode, bank latch, IDE reset, JVS flag clear (EXT-OUT writes ignored) | 74-series logic + XC9536 CPLD | `s573_bus.v`, `s573_flash.v`, `system573_top.v` | hardware model | psx-spx registers.md; GX700-PWB schematic |
| Konami 056879 I/O ASIC (0x1f400000-0f) | register ASIC | `s573_io.v` | hardware model | psx-spx builtin-io.md |
| ADC0834 (ANALOG connector) | serial ADC | `adc0834.v` (inputs read 0) | hardware model | ADC083x data sheet |
| M48T58 timekeeper + 8 KB NVRAM | ST M48T58 | `m48t58.v`, saved to the `.sav` | hardware model | M48T58Y data sheet, psx-spx |
| Watchdog | Konami 058232 (350-400 ms) | `watchdog.v`, **not connected to reset** (as with jumper S86 fitted) | present, disabled | psx-spx registers.md |
| Onboard flash, 16 MB | 8x MBM29F016A or LH28F016S | `s573_flash.v` + `flash_nor.v`, AMD command set, ID 0x04/0xAD, SDRAM-backed, saved to the `.sav` | hardware model (command level) | psx-spx games.md; MAME intelfsh |
| PCMCIA slots 1 and 2 | linear flash cards (Fujitsu 32 MB) | one 32 MB card, slot chosen per title | hardware model (command level) | psx-spx games.md, index.md; MAME linflash |
| IDE CD-ROM | Sony CR-589 or other ATAPI drive | `atapi.v` + `s573_cdimg.v` + `s573_cdtoc.v`: a drive answering from the mounted CD image (PIO, DMA5) | behavioural drive | ATAPI spec; psx-spx registers.md; MAME atapi/cr589 |
| CD-DA audio (drive's audio out to the board) | analog cable from the drive | **absent** | absent | psx-spx index.md |
| Security cassette: X76F041, X76F100 | Xicor EEPROMs | `x76f041.v`, `x76f100.v`, pin level | hardware model | psx-spx; Konami's driver (ddr4m); MAME x76f041/x76f100 |
| Security cassette: ZS01 | PIC16CE625 + firmware (not dumped) | `zs01.v`, pin level, packet protocol | behavioural | psx-spx "ZS01 protocol"; MAME zs01 |
| Cassette DS2401 | 1-wire serial number | `ds2401.v` on I6 / D4 | hardware model | DS2401; psx-spx |
| Cassette SDA wiring, IRDY/DRDY | 74LS125 / 74LS74 | `s573_seccart.v` (one SDA model for all cassettes) | hardware model (IRDY reads 1, see review) | GX700-PWB schematic; psx-spx; 573in1 |
| PunchMania cassette ADC0838, light-output cassettes | | not wired (`adc0838.v` exists, unused) | absent | psx-spx |
| JVS host MCU | Hitachi H8/3644 + firmware (OTP, not dumped) | `s573_jvs_mcu.v`: the MCU's documented protocol, register for register | behavioural | psx-spx builtin-io.md "MCU communication protocol", bios.md |
| Digital I/O board: CPLD (FPGA configuration) | XC9536 | `k573dio_cpld.v`: /PROGRAM, /INIT, DONE, the bitstream length count | hardware model | psx-spx expansion-io.md; 573in1; Konami's driver |
| Digital I/O board: FPGA registers | XCS40XL running Konami's bitstream | `k573dio.v`: Konami's DDR/Mambo register map re-implemented; the uploaded bitstream is accepted, not executed | behavioural | psx-spx expansion-io.md; MAME k573dio/k573fpga |
| Digital I/O board: 24 MB DRAM | 3x HY51V65164A | a 32 MB window in DDR3 (`s573_ddram_arb.v`) | hardware model (flat) | psx-spx |
| Digital I/O board: MP3 descrambler | logic in the FPGA bitstream | on the HPS (`support/s573/s573_descramble.c`); a fabric copy (`k573_mp3dec.v`) is kept for the benches | HPS | MAME k573fpga; psx-spx |
| Digital I/O board: MP3 decoder | Micronas MAS3507D (a DSP with mask ROM) | MP3 decoding on the HPS (minimp3, `support/s573/`); its I2C port in `mas3507d_i2c.v`; its output volume matrix in `s573_mas_gain.v` | HPS + partial model | MAS3507D data sheet; Konami's driver; MAME mas3507d |
| Digital I/O board: frame / sample counters (0xa8, 0xca-0xce) | count the MAS3507D's PI4 and LRCK pins | follow the HPS decoder and the PCM drain (MAME's semantics) | behavioural | MAME k573fpga; psx-spx (differs, see review) |
| Digital I/O board: DS2401, lamps | | `ds2401.v` on 0xee; lamps latched (no lamp output on a MiSTer) | hardware model | psx-spx |
| Digital I/O board: network (RS-485), RS-232 | FPGA logic | **absent** (only DDR Solo uses it, for linking) | absent | psx-spx "Network protocol" |
| DAC / analog mix of the board's audio | AK4309B, analog mixer | digital 1:1 sum of SPU and MP3 (`s573_audio_mix.v`); the board's analog ratio is not documented | behavioural | psx-spx; docs/2026-10-30-music-level-and-announcer.md |
| DDR stage I/O board | GN845-PWB(B): XC9536 CPLD (not dumped) | `gn845pwbb.v`, MAME's model of its handshake | behavioural | MAME ksys573 (psx-spx: protocol largely unknown) |
| White I/O memory card reader (JVS) | GE885-PWB(A): TMPR3904F CPU, XCS10XL FPGA, boot ROM 885a01 | the CPU runs Konami's boot ROM and uploaded program on the HPS (`support/s573/s573_wio*.c`); SNAC card byte exchange in the fabric (`s573_wio_port.v`) | CPU model on the HPS + pin model | TMPR3904F manual; psx-spx external-modules.md |
| Analog I/O board (lamps) | GX700-PWB(F) | absent (no analog-board titles supported) | absent | psx-spx |
| SIO0 (pad / memory card port) | broken out, unused by I/O boards | disconnected (patch 0026/0027) | as the board | psx-spx index.md |

Settings with no hardware counterpart, kept as options: **573 Chart Offset** (shifts
the sample counter the game reads, to compensate display/audio latency outside the
FPGA), **573 Music Level** (a listening preference, see
`docs/2026-10-30-music-level-and-announcer.md`), **573 MP3 Descramble** (on a board
the uploaded bitstream decides this; see plan item 2), the per-title control layout
and PCMCIA slot (on a board, the cabinet wiring).

## Replacing behavioural and HPS parts: what is possible

The FPGA is a Cyclone V 5CSEBA6 (41,910 ALMs, 4,191 LABs, 112 DSP blocks). The
card-reader build (job 419, the last fit recorded in STATUS.md) used 35,964 ALMs,
4,118 LABs (98 %) and 95 DSP blocks. About 70 LABs are left, so any item that costs more than a few hundred ALMs needs
area recovered first (the 2026-10-24 area pass recovered 3,099 ALMs).

Ranked by what it buys for the cost:

1. **Digital I/O register behaviour from psx-spx** -- small, most of the gain. The
   register differences listed in the review (feeder start/end word, 0xa0-0xa6
   readback, single DRAM pointer, 0xb0-0xbe reads, 0xba fetch enable, 0xe8 reset
   bits, key reload semantics, 0xaa bit meanings, the 28-bit LRCK counter and its
   0xcc/0xce rules) are all register logic: tens to a few hundred ALMs. They touch
   the music position the game reads, so each wants a bench replaying a game's
   driver and a playtest. No new chip is needed.
2. **Pick the descrambler from the uploaded bitstream** instead of the OSD option.
   The CPLD model already sees every bit the game sends; a CRC over the stream
   identifies the Solo Bass Mix vs 3rdMIX/Mambo bitstreams (psx-spx lists their
   SHA-1s), and also tells the register block which variant's quirks apply (0xca
   reads 0x7654 on Solo, key2/key3 unconnected). ~100 ALMs. Needs the two
   bitstreams extracted from game data to compute their CRCs.
3. **MP3 frame and sample counters at playback time.** Today they advance when the
   HPS decodes / the fabric drains PCM. Tying them to the drained output's frame
   boundaries (PI4) and sample clock (LRCK) is fabric logic on data the fabric
   already has; the "decode vs play" offset noted in STATUS.md goes away.
4. **Watchdog connected to reset** (350 ms, ~50 ms hold). Small, but only after the
   core can guarantee that nothing it adds (OSD pause, HPS flash/.sav traffic)
   stalls the game CPU for 350 ms -- the OSD pause would need to freeze the
   watchdog too.
5. **CD-DA audio** from the CD image into the mixer (the PCM ring and mixer exist).
   This is a missing feature rather than an HLE swap, and the prerequisite for the
   analog-board titles (DDR 1st/2nd Mix).
6. **MP3 decoding in the fabric.** Costed upstream at ~3,000-8,000 ALMs plus DSP
   (`docs/audits/2026-06-12-ddr-feasibility.md`); the design has neither. Even a
   fabric decoder would be a re-implementation, not a MAS3507D model (its firmware
   is a mask ROM). Not feasible on this device without removing something larger.
7. **Not possible without new dumps:** the JVS MCU (H8/3644 OTP firmware), the ZS01
   (PIC firmware), the GN845-PWB(B) stage board (XC9536 CPLD). Each is modelled from
   its documented or observed behaviour; a firmware or CPLD dump would allow a real
   model.
8. **Not worth replacing:** the CD drive (any drive model answers from an image),
   the White I/O reader CPU on the HPS (it already runs Konami's own code; moving a
   MIPS CPU into the fabric would cost thousands of ALMs for no visible change).
