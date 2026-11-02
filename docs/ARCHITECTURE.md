# Architecture

How the core is put together. What each part emulates, and how closely, is in
[`EMULATION.md`](EMULATION.md); the register map is in [`MEMORY_MAP.md`](MEMORY_MAP.md).

## The pieces

```
  MiSTer HPS (ARM, Linux)                      Cyclone V FPGA
  -----------------------                      ----------------------------------------------
  MiSTer_System573                             rtl/emu.sv  (the MiSTer "emu" top, from psx/PSX.sv)
   = stock Main + support/s573/                  |
   * MP3: read Digital I/O DRAM from DDR3,       +-- psx/ (MiSTer PSX core) + psx_patches/
     descramble, decode (minimp3),               |     CPU/GTE/GPU/SPU/MDEC/DMA, 4 MB RAM, 2 MB VRAM
     write PCM to a ring in DDR3                 |     EXP1 port (patch 0001) -> 0x1f000000-0x1f7fffff
   * White I/O reader: TMPR3904 CPU running      |
     Konami's boot ROM + uploaded program        +-- rtl/system573_top.v   (the 573 board)
   * CD image, .sav / cassette / NVRAM files     |     s573_bus      EXP1 decode
     (stock Main's mount and ioctl paths)        |     s573_io       Konami ASIC: inputs, ADC, audio enables
   * logs (logs/System573/)                      |     s573_flash    bank latch, onboard flash, PCMCIA card
        |                                        |     atapi + s573_cdimg + s573_cdtoc   CD-ROM drive
        |  SPI mailbox (s573_hps_ext.v)          |     s573_seccart  cassette: x76f041 / x76f100 / zs01 / ds2401
        +--------------------------------------->|     m48t58        RTC + NVRAM
        |  DDR3 (Digital I/O DRAM, PCM ring)     |     watchdog      (bite not wired)
        +--------------------------------------->|     s573_wio      JVS MCU (s573_jvs_mcu) + SNAC card port
                                                 |     k573dio       Digital I/O board registers, CPLD,
                                                 |                   MAS3507D I2C, MP3 feeder pacing
                                                 |     gn845pwbb     DDR stage board handshake
                                                 |
                                                 +-- audio: s573_mp3_pcm -> s573_mas_gain -> s573_audio_trim
                                                 |          -> s573_audio_mix (+ SPU) -> AUDIO_L/R
                                                 +-- persistence: s573_flash_saver, s573_nvram_*, s573_cass_nv,
                                                 |          s573_tk_nv  -> one .sav per title
                                                 +-- SDRAM (flash image), DDR3 arbiter (s573_ddram_arb)
```

## Buses and clocks

* The PSX core runs on clk_1x = 33.8688 MHz (and its 2x/3x); the 573 fabric runs on
  clk_1x and answers EXP1 with a registered read. Slow sources (SDRAM flash lines,
  Digital I/O DRAM) stall the CPU through the EXP1 wait added by patch 0006.
* 573 peripherals see 16-bit halfword accesses; byte offsets come from
  `s573_bus.v`.
* IDE: IRQ10 and DMA channel 5 (patch 0023), PIO only, as on the board.

## Where the data lives

| What | Where | Persisted |
|---|---|---|
| BIOS (700A01/700B01) | loaded through the PSX core's BIOS download (ioctl 0) | -- |
| onboard flash, 16 MB | SDRAM, line-buffered | `.sav` (whole image) |
| PCMCIA card, 32 MB | SDRAM | `.sav` |
| M48T58 NVRAM + clock | M10K | `.sav` |
| cassette EEPROMs | registers / M10K, loaded from the cassette files | ZS01 state in an extra `.sav` block (`s573_cass_nv.v`); X76 cassettes reload from their dumps |
| Digital I/O DRAM | DDR3 window | -- |
| CD image | the SD card / USB drive, streamed per sector by Main | -- |

Each launcher (`mgl/`) mounts the title's `.sav` before anything else, so a
previous title's save can never seed the next one
(`docs/2026-09-29-sav-mount-order.md`).

## Tests

* `sim/`: Icarus benches, one or more per module (`make -C sim`); dump-fed benches
  run when the MAME sets are in `dumps/mame573/`.
* `support/s573/tests/`: host tests of the HPS service (`make test mutate`).
* `sim/system573/`: the full-system NVC simulation of the PSX core + 573 fabric
  booting the BIOS (slow; used for bring-up).
