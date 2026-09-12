# ddrs2k: "HARD-WARE ERROR -1N / CDROM INITIALIZE ERROR" -- SET CD SPEED (2026-09-12)

**Hardware run, first flash boot of DDR Solo 2000 (GC905 JAA) after a clean CD
install.** The installer (ge905ja cassette, boot device CD-ROM) ran to
`INFO 500 インストール完了` and asked for the GC905JAA cassette; Save Flash
was taken; `ddrs2k_console.mgl` (gc905ja cassette, boot device Flash ROM,
Solo cabinet, DEFAULT descramble) then died at game init with

    HARD-WARE ERROR -1N
    CDROM INITIALIZE ERROR
    PLEASE CALL ATTENDANT

## Root cause (read out of the game binary, not guessed)

`GAME.DAT` as extracted from 905jaa02 carries two PS-X EXEs: a loader at file
0x24 (0x80300000) and the game at file 0x50000 (0x80010000, 0xa6000 bytes).
`tools/s573_oracle/mipsdis.py` (new; MIPS-I disassembler + lui/addiu xref
finder, no external deps) on the game EXE:

* `"CDROM INITIALIZE ERROR"` (0x80010340) is printed from the system-init
  routine at 0x8001da80: `if (cd_init(0, errcb) == -1) error(...)`.
* `cd_init` = 0x8005f83c. Its fatal (-1) exits: driver alloc (0x8008cef4),
  IDENTIFY check (0x8008c008: word0 & 0xdf00 == 0x8500 -- we pass, ours is
  0x8500 exactly), **SET CD SPEED (0x8008d458, arg 0x161)**, then a poll
  loop on 0x8008bf30 that retries only on -10 (in flight) and returns -1 on
  any completed-with-error.
* 0x8008d458 builds the 12-byte packet `BB 00 01 61 00 ...` -- ATAPI
  SET CD SPEED, 0x0161 = 353 KB/s (2x).
* `rtl/atapi.v` implemented 00, 03, 12, 1b, 25, 28, 43, 55, 5a, a8, a1, ef,
  08 -- **not 0xBB**. Unknown opcodes take the default arm: CHECK CONDITION,
  sense 5. That completed-with-error is the -1, is the screen.

ddrsbm never issued it: its CD library is a year older. The ddrs2k library
("ATAPI CD-ROM access library", strings at 0x800139xx) also carries CDDA
support (READ SUB-CHANNEL 0x42, PAUSE/RESUME 0x4b, PLAY AUDIO(10) 0x45) but
the only function that builds those packets (0x80050d1c) has no caller and no
pointer to it anywhere in the EXE, and 905jaa02 is a single MODE1 track, so
they are dead code here and were left unimplemented on purpose.

Everything else this library asks for already matches the RTL's fixed
allocation lengths: READ TOC always 12 bytes (track 0, per-track, 0xAA),
MODE SENSE(10) page 0x0E 24 bytes, READ CAPACITY 8, REQUEST SENSE 16.

## Fix

`rtl/atapi.v`: 0xBB joins the TEST UNIT READY / START-STOP UNIT non-data
GOOD arm (DRDY|DSC, error 0, C/D|I/O, INTRQ). One speed is served and the
requested rate ignored -- same as MAME's ATAPI CD-ROM and a real CR-589's
observable behaviour here. `sim/tb_atapi.v` gained the exact packet the game
sends and checks status 0x50 / error 0x00 / ireason 0x03; under the old RTL
that case reads status 0x51 / error 0x50 (RED).

**Needs a bitstream rebuild** (Windows, `tools/build-573.ps1 -Crt`). Not yet
run through the simulator or Quartus at the time of writing -- the VM that
wrote this has neither. Test steps for the operator are in the session.

## Not the cause, checked and excluded

* The CD image mounted: the installer read the whole disc from the same
  `.mgl` item, and the error is not the "incorrect CD-ROM / replace" family.
* Flash restore: the game got as far as its own init (`system init` string
  precedes the error in the same table), i.e. the flash boot itself worked.
* Descramble scheme: not reached yet -- MP3 comes after CD init.
