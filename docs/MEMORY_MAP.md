# System 573 memory map

A summary of the System 573's own registers as the psx-spx pages document them
(`psx-spx/psx-spx.github.io`, `docs/arcade/konami/573/`, read at `22c3ef7`,
2026-10-31), with what the core does where it differs. psx-spx is the reference;
read it for the full bit descriptions. Every standard PS1 register except the CD-ROM
drive's is present as on a PS1 (the PSX core).

DEV0 (`0x1f000000`) must be configured first: Konami writes `0x24173f47` to
`0x1f801008`. Afterwards all writes are 16 or 32 bits; 8-bit reads work.

## Windows

| Address | Function | Core |
|---|---|---|
| `0x1f000000-0x1f3fffff` | bank-switched flash / PCMCIA (4 MB window) | `s573_flash.v` |
| `0x1f400000-0x1f40000f` | Konami 056879 I/O ASIC | `s573_io.v` |
| `0x1f480000-0x1f48000f` | IDE bank 0 (`/CS0`) | `atapi.v` |
| `0x1f4c0000-0x1f4c000f` | IDE bank 1 (`/CS1`): `0x1f4c000c` alternate status / device control | `atapi.v` |
| `0x1f500000` | bank switch / cassette IO0 direction | `s573_flash.v` |
| `0x1f520000` | JVSIRDY clear (write) | `s573_jvs_mcu.v` |
| `0x1f560000` | IDE reset (bit 0, 0 = reset) | `atapi.v` (a pulse; the board holds it) |
| `0x1f5c0000` | watchdog clear (write) | `watchdog.v` (bite not wired) |
| `0x1f600000` | EXT-OUT latch, bits 0-7 | decoded, writes ignored (no output on a MiSTer) |
| `0x1f620000-0x1f623fff` | M48T58 (8 KB, low byte of each halfword) | `m48t58.v` |
| `0x1f640000-0x1f6400ff` | I/O board | `k573dio.v` (Digital I/O) |
| `0x1f680000` | data to the JVS MCU (write) | `s573_jvs_mcu.v` |
| `0x1f6a0000` | cassette D0-D7 latch (write; sets DRDY) | `s573_seccart.v` |

IRQ10 = IDE (through the CPLD), DMA5 = IDE data port read as a burst (manual sync,
PIO). IRQ2 and DMA3 are unused.

## Konami ASIC (`0x1f400000`)

`0x1f400000` (write):

| Bit | Function |
|---|---|
| 0 / 1 / 2 | ADC0834 DI / `/CS` / CLK |
| 3 / 4 | coin counter 1 / 2 |
| 5 | built-in amplifier enable (no effect on line outputs; not applied) |
| 6 | external audio input (CD-DA / Digital I/O) enable -- measured as an attenuator (not applied) |
| 7 | SPU DAC output enable, 0 = muted (applied once software has written the register) |
| 8 | JVS MCU reset, 0 = reset (a discrete flip-flop) |

`0x1f400004` (read):

| Bits | Function |
|---|---|
| 0-3 | DIP switches 1-4 (0 = on); DIP 4 set = try flash/PCMCIA first |
| 4-5 | JVS MCU status code (0 waiting, 1 busy, 2 transferring) |
| 6-7 | JVS MCU error code (1 checksum, 2 no sync byte, 3 no error) |
| 8-15 | cassette I0-I7 (I6 = DS2401 on X76 cassettes; the core reads I4 = 1, MAME's "Network?" = Off) |

`0x1f400006` (read): 0 ADC DO, 1 ADC SARS, 2 cassette IO0 (SDA), 3 JVS sense,
4 JVSIRDY, 5 JVSDRDY, 6 cassette IRDY (core: always 1), 7 cassette DRDY, 8-9 coin
switches (0 = coin), 10-11 PCMCIA card 1/2 detect (0 = present), 12 service (0 =
pressed).

`0x1f400008` (read): bits 0-7 player 2 (left, right, up, down, buttons 1-3, start),
bits 8-15 player 1 (same order), active low.

`0x1f40000a` (read): data word from the JVS MCU (valid while JVSIRDY).

`0x1f40000c` (read): 8 P1 button 4, 9 P1 button 5, 10 test, 11 P1 button 6.
`0x1f40000e` (read): 8 P2 button 4, 9 P2 button 5, 10 main-RAM layout (0 = new; the
core reads 0), 11 P2 button 6. All buttons active low. DDR Solo's Select L / R are
buttons 5.

## Bank switch (`0x1f500000`, write)

| Bits | Function |
|---|---|
| 0-5 | bank: 0-3 onboard flash pairs (31M/27M, 31L/27L, 31J/27J, 31H/27H), 16-31 PCMCIA slot 1, 32-47 slot 2 |
| 6 | cassette IO0 output enable: 1 = D0 drives SDA |
| 7 | unknown (goes into the CPLD) |

Banks 4-15 mirror 0-3 on a board (the onboard decode ignores bits 3:2); the core
returns `0xFFFF` there.

## Security cassette

D0-D7 at `0x1f6a0000`, I0-I7 at `0x1f400004` bits 8-15, IO0 at `0x1f400006` bit 2,
IO0's direction at `0x1f500000` bit 6.

| Pin | X76F041 / X76F100 cassettes | ZS01 cassettes |
|---|---|---|
| D0 | SDA, driven onto IO0 while bit 6 is set | same |
| D1 | SCL | SCL |
| D2 | `/CS` | -- (no chip select) |
| D3 | RST | reset |
| D4 / I6 | DS2401: D4 = 1 pulls the bus low, I6 reads it | -- (the DS2401 is read through the ZS01) |
| IO0 | SDA readout | SDA readout |
| `/DSR` (SIO1) | insertion detect (grounded) | same |

## M48T58 (`0x1f620000-0x1f623fff`)

Bytes 0-8183 (`0x1f620000-0x1f623fef`) are battery-backed RAM; the last eight are the
clock, BCD:

| Address | Register | Bits |
|---|---|---|
| `0x1f623ff0` | control | 0-4 calibration, 5 sign, 6 READ (freeze reads), 7 WRITE (set clock) |
| `0x1f623ff2` | seconds | 0-6, 7 ST (stop) |
| `0x1f623ff4` | minutes | 0-6 |
| `0x1f623ff6` | hours | 0-5 (24 h) |
| `0x1f623ff8` | day of week | 0-2 (Konami: 1 = Sunday), 4 CB century, 5 CEB, 6 FT |
| `0x1f623ffa` | date | 0-5, 6 BL (battery low, read-only), 7 BLE |
| `0x1f623ffc` | month | 0-4 |
| `0x1f623ffe` | year | 0-7 (00-99; Konami reads 70-99 as 19xx) |

Month lengths and leap years are handled by the chip (and by `m48t58.v` since
2026-11-02).

## Digital I/O board (`0x1f640000`)

FPGA registers (`0x80-0xef`) exist only once a bitstream is uploaded; the core
always presents Konami's DDR/Mambo map. CPLD registers (`0xf0-0xff`) always answer.
The differences listed for the core are in `docs/2026-11-02-source-review.md`, D1.

| Offset | Function | Core |
|---|---|---|
| `0x80-0x9f`, `0xd0-0xdf` | magic `0x1234` (partial decode); `0x90` network node ID, `0x92` network control | magic as psx-spx; network absent |
| `0xa0/0xa2`, `0xa4/0xa6` | MP3 start / end address (bits 16-24, 1-15) | reads return the written values |
| `0xa8` | w: key1; r: MP3 frame counter (PI4 edges) | counts HPS-decoded frames |
| `0xaa` | r: MAS3507D PI19 / PI8 / PI4 / WRDY (bits 12-15); w: `/POR`, `/PCS` | MAME's status bits |
| `0xac` | MAS3507D I2C (12 SDA, 13 SCL, open drain) | `mas3507d_i2c.v` |
| `0xae` | MP3 feeder: 12 r playing, 13 enable, 14 play, 15 frame counter enable | |
| `0xb0/0xb2`, `0xb6/0xb8` | DRAM address (one pointer on a board) | two pointers |
| `0xb4` | DRAM data, auto-increment | |
| `0xba` | bit 15 MP3 DRAM fetch enable | not modelled |
| `0xc0-0xc8` | network data / FIFO lengths / reset; `0xc6`, `0xc8` read `0x7654` | `0x7654` only |
| `0xca/0xcc/0xce` | DAC sample counter (LRCK) high / low (write clears) / delta | MAME's counter and diff |
| `0xe0/0xe2/0xe4/0xe6` | lamps A4-7, A0-3, B4-7, D0-3 (bits 12-15) | latched |
| `0xe0-0xec` read | `0x1100` | as the `0xee` value |
| `0xe8` | logic resets (12 I/O, 13 DAC clock / counter / network, 14 DRAM, 15 MP3 interface) | not modelled |
| `0xea` / `0xec` | key2 / key3 | |
| `0xee` | 1-wire: bit 12 DS2401, bit 8 DS2433 (unfitted); write 1 = pull low | both |
| `0xf4` | bit 15 audio DAC reset (0 = reset) | gates the MP3 output |
| `0xf6` | w: `/INIT`, DONE, `/PROGRAM` (Konami: `0x8000`, `0xc000`, `0xf000`); r: status `0x9fff` cleared / `0xbfff` configured | `k573dio_cpld.v` |
| `0xf8` | bitstream bit (bit 15), 330,696 bits | `k573dio_cpld.v` |
| `0xfa/0xfc/0xfe` | lamps C0-3, C4-7, B0-3 | latched |
| `0xf0-0xfe` read | all return the `0xf6` status | yes |

## IDE

Standard ATA/ATAPI task file, 16-bit accesses (only the low byte is meaningful on
registers other than data). The drive must be device 0 (primary); a lone device 0
reads STATUS 0 for device 1. After reset an ATAPI drive puts `0x14`/`0xeb` in the
cylinder registers. See psx-spx registers.md "IDE registers".
