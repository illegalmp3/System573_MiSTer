# Memory card support: the GE885-PWB(A) "White I/O" reader

2026-10-23. Scope: DDR on Digital 573, as close to the documented hardware as the
sources allow. Every claim below names its source; where a value is inferred and
not documented it says so.

## 1. Is a binary uploaded to the reader at boot? Yes.

* psx-spx (`docs/arcade/konami/573/external-modules.md`, "PS1 controller and memory
  card adapter (GE885-PWB(A))"): TMPR3904 CPU, XCS10XL FPGA, 512 KB RAM, 512 KB boot
  ROM; "the ROM is only a small bootloader and the actual firmware is downloaded
  from the 573 into RAM". JVS ID `KONAMI CO.,LTD.;White I/O;Ver1.0;White I/O PCB`.
* The upload is in the game. Every DDR 4thMIX executable on both CHDs (a33aaa02,
  a33jaa02; three executables each) carries the same container (section 3).
* The boot ROM itself (`885a01.bin`, SHA-1 927f62f6..., in the ddr3ma/ddr4m sets)
  is 4,971 non-FFh bytes: JVS framing, ID/version answers and `70 00/01/02` (RAM
  read, RAM write, execute). It has no memory card code at all.

MAME's `k573mcr` does not run the uploaded program; it answers the commands with
its own HLE. This core now follows the uploaded program instead (section 6).

## 2. Sources and how they were read

| Source | Used for |
|---|---|
| psx-spx `builtin-io.md` (JVS MCU), `external-modules.md` (White I/O) | the 573's JVS MCU registers; the board |
| psx-spx `memory-card-read-write-commands.md`, `memory-card-data-format.md` | the PS1 card protocol, FLAG byte, ACK timing, formatted blank |
| `885a01.bin` | boot ROM; stored 16-bit byte-swapped, built "Thu Mar 25 14:05:44 JST 1999"; disassembled big-endian at 0xbfc00000 |
| ddr4m game exe (`exe_60000.bin`, load 0x80010000) | Konami's JVS driver, the reader driver, the upload container |
| the unpacked firmware (24,720 bytes, SHA-1 `1a585688e78ff513362ebf3356ecd76173bd0909`, CRC-32 `08844237`) | every command, status bit and card rule below; disassembled big-endian at 0x80000000 |
| MAME `k573mcr.cpp` | cross-check only; differences in section 5 |
| PSX_MiSTer (vendored `psx/`) | the SNAC pin mapping (emu.sv) |

Tools: `tools/s573_oracle/mipsdis.py` (+ big-endian wrapper and branch-likely
opcodes, which the TX39 firmware uses).

## 3. The upload

Container in the game exe (file offset 0xaeb38, RAM 0x800be338), a list of
`{addr BE32, size BE32, data}` records ending with a zero size (parser at game
0x800b2600; each record sent as `70 01` chunks, game 0x800b2714):

| Record | Size | Contents |
|---|---|---|
| 0x01c000 | 0xb0 | stub: LZSS-unpacks 0x80020000 -> 0x80000000, jumps to 0x80000010 with a0 = the JVS address |
| 0x020000 | 0x3144 | the firmware, LZSS |
| 0x018000 | 0x17e8 | the FPGA configuration, LZSS: 12 bytes of bus-controller setup + an XCS10XL bitstream (preamble `0010`, 95,744 bits) |

The game then sends `70 02 01 c0 00` (execute the first record, game 0x800b27b8),
waits 60 frames (0x800b2824) and sends `73` (0x800b2850). LZSS (stub 0x8001c020,
firmware 0x800051e0): flag byte LSB first, 1 = literal; otherwise
`offset = (b0 & 0xf0) << 4 | b1`, `length = (b0 & 0x0f) + 3`, offset 0 ends.

## 4. What the board does

### 4.1 Boot ROM (dispatcher 0xbfc010d4)

| Command | Answer |
|---|---|
| `F0 D9` | none; arms the TX3904 watchdog (0xbfc01ba4) = reboot |
| `F1 n` | only if no address yet and the downstream sense is high: takes n, drives its sense output low, `01` |
| `10` | `01` + the 47-byte ID (with its NUL) |
| `11` `12` `13` `14` | `01 11`, `01 20`, `01 10`, `01 00` |
| `2F` | resend the previous answer |
| `70 00 a24 n` | `01` + n bytes of RAM; `02` unless 1 <= n <= 0x80 and a+n <= 0x80000 |
| `70 01 a24 n data` | write; same limits; `01`/`02` |
| `70 02 a24` | only as the packet's sole command, 4-aligned, <= 0x7ffff: `01`, then runs it |
| other | packet status 2 |

### 4.2 Firmware

A small multitasking kernel (`mts.c`, `semaphore.c`): tasks for JVS (`jvs.c`,
`jvsio.c`), the FPGA loader, the dongle driver (`xicor.c`, `x76.c`) and the
cards (`mcard.c`). The JVS address comes over from the boot ROM in a0; it is not
re-assigned. Commands (dispatcher 0x80002ef4; one packet may hold several, each
adds its report byte):

| Command | Semantics (routine) |
|---|---|
| `F0 D9` | reboot (0x80003df0) unless a card op runs (status & 0x0600); never answered |
| `F1` | not answered (0x800030d8) |
| `10`..`14`, `2F`, `70 00`, `70 01` | as the boot ROM |
| `70 02 a24` | starts a task at a24 (0x80001c80); not used by DDR (HLE acks and logs) |
| `71` | `01 hi lo`: the 16-bit status (0x80001d88) |
| `73` | if (status & 0x0101) == 0x0001: (re)configure the FPGA, sets 0x0100, `01`; else `04` (0x80002918). Done: clears 0x0101 |
| `74 pf16 ram24 n16` | read n frames from card port pf>>15, frame pf&0x7fff into RAM (0x80002a58) |
| `75 ram24 pf16 n16` | write n frames (0x80002bdc) |
| `76` | clear the card error bits 0x001e; `04` while a card op runs (0x80002d60) |
| `72 0s` / `1s pw8` / `2s off16 ram24 n16` / `3s ram24 off16 n16` / `4s ram24` / `5s ram24` / `6s` / `7s pw8` | dongle slot s: probe, set password, read, write (8-byte aligned), config read, config write, mass op, change password (0x80001de4..0x8000269c) |
| other | packet status 2, processing stops (0x80003300) |

74/75 limits: n > 0, frame + n <= 0x400, ram + 128n <= 0x80000; busy if
status & 0x061f -> `04`. **On every busy refusal of 74, 75 and the parameterised
72 forms the firmware reports `04` without consuming the parameter bytes, which
it then parses as commands** (the index is advanced only after the busy check);
the HLE does the same. Overflow past 0xfe body bytes -> packet status 4.

Status word (0x80002e04 maps a card op's result through the table at
0x80005f10):

| Bit | Meaning |
|---|---|
| 0x0001 | FPGA not (re)configured yet; 1 after the firmware starts |
| 0x0002 / 0x0004 | read error / write error (op -2) - sticky until `76` |
| 0x0008 | no card answered (op -1) - sticky |
| 0x0010 | write op saw card FLAG = 04h (-3) - sticky |
| 0x0020 / 0x0040 | dongle: no device (-2) / password (-1) |
| 0x0100 | FPGA configuring |
| 0x0200 / 0x0400 | reading / writing |
| 0x0800..0x4000 | dongle busy kinds |
| 0x8000 | the op's first frame had FLAG != 08h (cleared and recomputed by every op) |

### 4.3 The card algorithm (mcard.c)

One frame, read (0x8000579c): select; `81` (no ACK -> -1); `52` -> FLAG, must be
00h/04h/08h; `00`->5Ah, `00`->5Dh, MSB->00h, LSB, `00` with the long ACK timeout
->5Ch, `00`->5Dh, `00`->MSB, `00`->LSB, 128 data bytes, the checksum byte (read,
**not compared**), `00` without ACK -> 47h. Any mismatch -> -2. FLAG 04h -> -3.
Remembers per port whether FLAG was not 08h. Write (0x800059f0) the same shape
with `57`, data out, checksum = MSB^LSB^data, then 5Ch 5Dh 47h. psx-spx: FLAG is
08h after power-up/insertion and bit 3 is cleared by a write - which is what
0x8000 reports.

Each frame is tried 5 times (0x80005c24 / 0x80005cec); -1 only if all five got no
ACK on the first byte, else -2. The read op (0x80005270) stops at the first
failing frame (-1 only for frame 0); the write op (0x80005370) then re-reads
frame 0 once. A transaction waits until 0x325a9 timer ticks have passed since the
last write.

### 4.4 Hardware interface (as used by the firmware)

FPGA register 0xb0000003: bit 0 CMD out / DAT in, bit 1 CLK out / ACK latch in,
bits 2/3 port selects; 0xb0000005 write clears the latch. Per bit: CLK low + CMD,
~66-iteration loop, sample DAT, CLK high, loop. ACK: latch already set -> error;
wait up to 0x28 (0x7d0 for the byte after which Sony cards ACK late, psx-spx
"31000 cycles"); seen -> wait 7, line still low -> error.
Dongles: X76F041 driver; the probe expects the answer-to-reset 0x98aa55aa
(0x800047c4) - 19h 55h AAh 55h bit-reversed, the X76F041's documented value.

### 4.5 NOT derived

The firmware's delay helper (0x800003f0) waits `n * 33 / 2` ticks of a 24-bit
counter and 0x80000434 builds milliseconds as `1000` units. That reads as a
16.5 MHz counter and 1 unit = 1 us, a 33 MHz CPU and ~125 kHz card clock - an
inference from the code's constants, not a measurement. The core uses those
values (`s573_wio_snac.v` parameters, `s573_whiteio.c` virtual timing:
72 us/byte, +915 us late ACK from psx-spx, 12.5 ms post-write wait, 20 ms FPGA
configure). The FPGA register meanings come only from how the firmware uses them.

## 5. DDR 4thMIX's use, and where MAME differs

The game's reader library (state machine 0x800af260, requests enqueued only by
0x800b1dfc) is only ever asked for request types 2, 3 and 4 (callers 0x800b0930,
0x800b0ac4, 0x800b1438, 0x800b1514, 0x800b1dd0). Types 5..11 - the dongle
states that send `72` - are linked in but unreachable: **ddr4m never uses the
security plate.** In normal use it sends `71 73 74 75 76 70 00 70 01`.

| MAME k573mcr | Firmware |
|---|---|
| `76 74`/`76 75` one command | `76` (clear errors) and `74`/`75` are separate commands; MAME's logs show the game putting both in one packet |
| `73` = execute | boot ROM: `70 02` executes; firmware: `73` configures the FPGA |
| `77` pads | not in this firmware (GuitarFreaks uploads its own) |
| status = AVAILABLE/READING/... | see 4.2; 0x8000 is "FLAG was not 08h" |
| first write after reset dropped | no such rule |
| 4 MB RAM | 512 KB, every limit checked against 0x80000 |
| `72` 00/10/20/40 with faked data | 00..70 per slot; no dongle fitted here (absent: 0x0020) |
| busy refusal consumes the parameters | does not (4.2) |

## 6. Implementation

Fabric (OSD `573 Card Reader`; **Off is the core as before**, bit-exact registers):

* `rtl/s573_jvs_mcu.v` - the 573's JVS MCU at its 573-side registers
  (0x1f400004 [7:4], 0x1f400006 [5:3], 0x1f40000a, 0x1f520000, 0x1f680000,
  0x1f400000 bit 8), packet sync/length/checksum checks, hand-off to the HPS with
  a sequence number. Idle = error 3 / status 0 = the 0xC the BIOS self-test reads.
  Buffers are registered-read RAMs (M10K).
* `rtl/s573_wio_snac.v` - SELECT / DESELECT / XFER primitives on the SNAC pins
  shaped like the firmware's helpers (4.4).
* `rtl/s573_hps_ext.v` - `CMD_573_WIO` (0x6F): request read, response commit,
  card primitive, flags (sense).

MiSTer_System573 (`support/s573/`):

* `s573_whiteio.c/.h` - boot ROM + ddr4m firmware semantics (4.1-4.3); the
  uploaded program is unpacked and identified by CRC (logged if unknown);
  virtual PS1 card per psx-spx.
* `s573wio.cpp` - mailbox glue, 1 ms cadence; Virtual cards are
  `saves/System573/memcard1.mcd` / `memcard2.mcd` (raw 128 KB, same as other
  PS1 tools; a formatted blank is created when missing, saved 0.5 s after the
  last write); OSD `573 Card 1/2` eject them; SNAC cards are real PS1 cards.

Tests: `support/s573/tests` (`make all`; `WIO_DDR4M_EXE=<exe>` replays the real
container: the unpacked program matches), `sim/tb_s573_jvs_mcu.v`,
`tb_s573_wio_snac.v`, `tb_s573_wio_path.v`, `tb_s573_io.v`, `tb_system573_top.v`.

## 7. Open

* Area: the design was ~99 % LABs; the fit is unknown until a Quartus build.
* Real-card timing on the SuperStation One SNAC ports: untested.
* Other mixes upload their own program (the HLE logs a CRC mismatch and keeps the
  ddr4m rules); dongle contents (GE885-JB) are not dumped.
