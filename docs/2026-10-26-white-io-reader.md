# The DDR memory card reader (White I/O, GE885-PWB(A)) -- 2026-10-26

DDR cabinets from 3rd Mix on read and write PlayStation memory cards: player data,
edits, and (4th Mix on) a card the home version can read. This core now does that
the way the cabinet does, for card **files** and for **real cards on SNAC**. The
previous attempt (high-level emulation of the reader's commands, branch
`memcard-wip-20261025`) is not reused; it was removed on 2026-10-25 and this is a
fresh start from the sources.

## How a cabinet does it

```
573 CPU --(0x1f68/0x1f40 regs)--> H8/3644 JVS MCU --RS-485 115200 Bd--> GE885-PWB(A) --> 2 PS1 card slots
```

* The 573's JVS MCU (board location 18E) buffers a JVS packet the 573 writes, sends
  it, waits for the answer and lets the 573 read it (psx-spx "Konami System 573":
  registers 0x1f400000 bit 8, 0x1f400004 bits 4-7, 0x1f400006 bits 3-5,
  0x1f40000a, 0x1f520000, 0x1f680000; "MCU communication protocol"; "JVS interface").
* The reader, GE885-PWB(A) "White I/O" (psx-spx calls it the PS1 controller and memory
  card adapter): a Toshiba TMPR3904F (TX39 core, MIPS I) with 512 KB RAM, a 512 KB boot
  ROM (**885a01**, MAME `k573mcr.cpp`, CRC32 e22d093f, in MAME's ddr3m*/ddr4m*/... zips),
  a Xilinx XCS10XL FPGA and two PS1 card ports.
* The boot ROM only knows how to receive a program. Every card-capable DDR game
  uploads the same reader program (24,720 bytes unpacked, CRC32 08844237) plus the
  FPGA bitstream over JVS (`70 01` RAM writes, `70 02` run), then uses the program's
  commands: `71` status, `73` configure the FPGA, `74` read frames, `75` write
  frames, `76` clear errors. In ddrextrm the upload container is in GAME.DAT at
  0x144678 (records `{addr BE32, size BE32, data}`: 0x1c000 stub, 0x20000 program,
  LZSS; 0x18000 FPGA image, LZSS).

## How this core does it

The reader board is **emulated at the hardware level on the HPS** and the 573's JVS
MCU is **in the fabric**:

| piece | where | file |
|---|---|---|
| JVS MCU (573 side, register for register) | fabric | `rtl/s573_jvs_mcu.v` |
| SNAC card byte exchange (real cards) | fabric | `rtl/s573_wio_port.v` |
| the two above + the HPS command (CMD_573_WIO 0x6F) | fabric | `rtl/s573_wio.v`, `rtl/s573_hps_ext.v` |
| TX3904 CPU interpreter | HPS | `support/s573/s573_wio_cpu.c` |
| board: IRC, SIO, DMAC, timers + watchdog, PIO, CConR, FPGA config + registers, card ports | HPS | `support/s573/s573_wio.c` |
| PS1 memory card (byte level) | HPS | `support/s573/s573_wio_card.c` |
| service: board thread, Main poll, card files | HPS | `support/s573/s573wio.cpp` |

The board's CPU runs the real 885a01 and the real uploaded program; nothing about the
reader's commands is re-implemented. Time is the board's own 66 MHz cycle count, kept
in step with the wall clock; JVS bytes reach the board's SIO at 115200 Bd timing, and
the MCU's 200 us inter-packet gap (psx-spx) is kept.

**Real cards.** The program's card byte exchange (fw 0x8000560c: eight bits LSB first,
then wait for /ACK up to 40 us -- 2000 us after the byte that answers 5Ch, Sony's late
/ACK -- then 7 us, /ACK must be gone) cannot cross the HPS bus bit by bit. For a slot on
SNAC the CPU parks at the routine's entry (interrupts still taken), the fabric performs
the routine at the pins with the routine's own timing (counted from its instructions at
66 MHz: CLK low -> sample 2.11 us, -> CLK high 0.20 us, high 2.32 us, ~219 kHz), and
the CPU resumes with the result. The routine is recognised by a CRC of its bytes
(dde28caa); a different program gets bit-level emulation only. Selection, CLK/CMD idle
levels and the /ACK latch clear (fw 0x80005804, 0x80005a58) are forwarded in order.

**Card files.** Raw 128 KB images (psx-spx "Memory Card Images": .mcd/.mcr/.sav are
all the raw format). The image is read when it is mounted; every frame the game writes
is written back to the file (pwrite of that 128-byte frame, from a writer thread). A
read-only file keeps its writes in memory. psx-spx "Memory Card Data Format" is what
`wio_card_format` builds (tests only; the service never formats a user's file).

## Using it

OSD (CONF_STR):

* **573 Card Reader**: Auto (fitted for the DDR control profiles, as on a DDR cabinet),
  On, Off. Off is the core exactly as before -- the JVS bits read their old constants.
* **573 P1 Card** / **573 P2 Card**: File or SNAC. SNAC port 1 is player 1, port 2
  player 2 (reader port 0 is the cabinet's player 1 slot).
* **573 P1 Card File** / **573 P2 Card File** (slots S2/S3, remembered per core):
  browse `saves/System573/` for a .mcd/.mcr/.sav. No file = no card in that slot.
  `saves/System573/memcard1.mcd` and `memcard2.mcd` are blank formatted cards.

**Card In/Out** (2026-10-28): after saving, DDR tells the player to pull the card
out and waits for it. A card file has no hand to pull it, so each player has a
"Card In/Out" button (J1 position 17, joy bit 20; map it in Define System573
buttons). A press pulls that player's card out of the slot (the game sees no card)
and the next press pushes it back in -- as a fresh insertion, FLAG 08h, exactly like
re-inserting a real card. The file stays mounted; a newly chosen file goes in. An OSD
popup confirms each press ("P1 card removed" / "P1 card inserted"). The fabric flips
a bit per press (`s573_wio.v` card_sw, CMD_573_WIO word 1 bits 11:10, not cleared by a
core reset) and the service turns each flip into a pull or push. Found on the
cabinet 2026-10-28 (ddrextrm, a home DDR 5th Mix .sav): the old workaround -- the OSD
"573 Card Reader" Off and back -- power-cycles the reader board, which loses the
program the game uploaded at boot, and the game stops talking to it.

Main used to mount `saves/<core>/<CD name>.sav` into slot 2 whenever a CD was mounted
(support/psx/psx.cpp); the graft now skips that for this core so the player's chosen
card stays in (`tools/build-hps-mp3.sh` step 5).

The boot ROM: `885a01.bin` next to the CD image, or in the core's games folder
(`games/System573/885a01.bin`), as MAME stores it (CRC32 e22d093f). Without it the
service logs that and the reader stays absent.

## CMD_573_WIO (0x6F)

One op per SPI transaction. Word 0 (the command) answers the status
`{attached, osd_en, waiting, port_busy, port_done, port_result[1:0], 0, req_seq[7:0]}`;
word 1 carries `{op, arg}` and answers `{xfer_cnt[3:0], 00, port_result, rx_byte}`.
Ops: 01 ATTACH, 02 SENSE, 03 CARDREG, 04 LATCHCLR, 05 XFER (word 2 = /ACK timeout us),
06 GETREQ (word 2 = length, word 3 = req_seq, then the request two bytes per word),
07 PUTRESP (word 2 = length, word 3 = the req_seq it answers, then the response; the
word that completes it commits it). A core reset clears `attached`; the service sees
that and re-sends sense, card register and ATTACH. Full text: `rtl/s573_wio.v` header.

## Board facts used (from the code; no schematic or datasheet exists for the board)

* Clock fc = 66 MHz, three ways: SIO1 SBGR = 0x00090000 (fc/4, BRD 9 -> fc/576 = 115200 Bd);
  TX timeout n*0x5a0 ticks = one 10-bit frame at fc/576 in fc/4 ticks; delay(us) waits
  us*33/2 ticks of the FPGA counter and 1 ms = 16500 ticks -> counter = fc/4.
* RAM 512 KB at 0; ROM at 0x1fc00000 (885a01.bin is byte-swapped 16-bit). Boot: ROM
  checksum, RAM test, copy the program at ROM+0x1004 to 0x80070000.
* PIO0 b26 FPGA /PROGRAM, b25 CCLK, b24 DIN. PIO1 b28 RS-485 driver enable (low),
  b29 JVS sense out (1 after reset, 0 once addressed), b30 sense in from downstream
  (must be 1), b31 FPGA DONE. PIO2 LED post code.
* FPGA registers at 0xb0000000: +01 scratch; +03 W b0 CMD, b1 CLK, b2 /SEL port 0,
  b3 /SEL port 1 (pin levels), R b0 DAT, b1 /ACK latch, b2 /ACK now; +05 latch clear;
  +11/+13/+15/+17 24-bit counter at fc/4; +21 countdown irq ack; +23/+25/+27 24-bit
  countdown -> INT[7] (IRC source 6). Bitstream: preamble 0010, length count 95737.
* TX3904 peripherals: TMPR3904F user's manual Rev 2.0 (ManualsLib 1790307; IRC ch.11,
  SIO ch.12, DMAC ch.10, timers ch.13, CConR) and GDB's sim/mips dv-tx3904*.c for the
  behaviours the manual leaves open (SIO TDIS = TX FIFO empty in interrupt mode).
* JVS firmware status bits: 0001 FPGA not configured, 0002/0004 read/write error,
  0008 no card, 0010, 0100 configuring, 0200 reading, 0400 writing, 8000 = the first
  frame's FLAG was not 08h (set after a card has been written: psx-spx FLAG bit 3).

## Tests

* `sim/`: `tb_s573_jvs_mcu` (psx-spx's 700B01 self-test sequence 0C 0E 0A 0D x16 05 x16,
  a DDR transaction, stale responses, reader Off = legacy constants; RED with `+red`),
  `tb_s573_wio_port` (byte + /ACK, no card, last byte, latch errors, clock timing,
  the late /ACK against both timeouts; RED with `+red`), `tb_s573_wio` (every op,
  GETREQ/PUTRESP, a cut-short response, a card byte; RED with `+red`), `tb_s573_io`
  (the bits land where psx-spx says), `tb_s573_hps_ext` P11/P13 (0x6F claimed, every
  word reaches the reader with its answer; RED with the old range), `tb_system573_top`
  part 5 (01 71 through the 573's own registers).
* `support/s573/tests`: `make wio` -- `test_wio_board` runs the board alone through
  the game's sequence (reset x2 -> watchdog resets, address -> sense 0, ID, upload ->
  program CRC 08844237, FPGA configure, read/write/16-frame read, empty port), with a
  virtual card and with the SNAC stand-in; `test_wio_service` runs the whole service
  (Main poll thread, board thread, writer) against a model of the fabric: read from a
  card FILE, a game write found in the file on disk, the same read on SNAC, a core
  reset, an eject. `make wio-red`: with no reader fitted the service test must fail.

## Hardware test

See the end of the session report (STATUS.md "Open" carries the result once run). What
to look for in `logs/System573/<session>.log`: `s573wio: boot ROM ...`, `board powered
on`, `JVS -> 10 ID`, `uploaded program running: CRC-32 08844237`, `board status ...`,
`74 card read: player N frame ...`, `player N card: k frame(s) ... written`, and the
10-second line (`worst lag` = how far the board fell behind the wall clock).

## Emulation speed (2026-10-29)

Cabinet logs (sessions 1-5): the board fell up to ~1 s behind the wall clock twice
-- while the uploaded program configured the FPGA, and while it read 16-36 frames
from a card file -- and the game re-sent one `73`. Profiled on the host
(`WIO_PROFILE`), the time went to loops whose outcome is fixed: the FPGA counter
read inside delay(us) (0x800003b4, 218k calls), the FPGA bitstream bit routines
(0x80004f98/fb8, 191k calls), the /ACK wait and the card-command guard time
(0x80005714, 0x800057d0), and the card byte routine's bit loop for card files.
All in `support/s573/s573_wio.c`; no FPGA change:

* the interpreter reads, writes and fetches RAM directly and looks for loop
  shortcuts only at branches (bit-identical results, 1.8x faster on the host);
* delay(us), the /ACK wait and the guard time jump to just before the time that
  ends them, never past the next device event; the FPGA bitstream loop does each
  byte's 24 PIO writes directly in 270 cycles, the interpreter's own count, and
  leaves the registers as the loop does (checked against interpretation:
  identical cycles and registers at 0x80005130);
* a card file's byte exchange is done at routine level, as the SNAC path already
  was: the routine's algorithm with the card model, durations as interpreted
  (2354 cycles of bits; +/ACK delay +481; +timeout +11 with no /ACK).

All only for the known program (CRC 08844237). Host test, the whole DDR flow:
12.6 M instructions interpreted -> 3.07 M; the worst 100 ms of board time
3.6 M -> 0.37 M. `test_wio_board -slow` runs everything interpreted and passes the
same checks; the fast run checks the shortcuts actually applied. The 10-second log
line now also says how long the board thread ran and how fast it interpreted.

## Open

* Cabinet, 2026-10-28 (sessions 1-4): SNAC cards read and write; a home DDR 5th Mix
  .sav reads and the game's save lands in the file (frames 042, 043, 046, 072, 093,
  0b7). Worst lag ~1 s during the program upload + FPGA configuration (the board CPU
  bit-bangs 95,737 FPGA bits), 20-230 ms during play; the game resent one `73` and
  recovered. See "Emulation speed" for the fix (firmware only).
* JVS bus ownership: only the reader is on the bus. A cabinet with other JVS devices
  is not modelled.
* The fabric drives the SNAC pins only while a slot is set to SNAC.
