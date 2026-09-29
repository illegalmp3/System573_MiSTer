# The flash saver captured every slot's SD stream — a save during the attract loop wrote CD sectors into the .sav (PCCARD2)

**2026-09-28.** Ricky, after the timekeeper-persistence build: a manual OSD "Save Flash"
while ddrextrm ran, then a power cycle → PCCARD2 error and the game demands a reinstall.
Reproduced deliberately (tests 1–3 below). Root cause is in `s573_flash_saver` and predates
today's work; the timekeeper feature only made him take a manual save at the one moment
that exposes it.

## Evidence (the .sav itself, `local/t7/`)

`ddrextrm-20260928h-good.sav` (taken after two clean boots) vs `…i-test3.sav` (after the
manual save + power cycle):

* flash region (16 MB): identical. Cassette block, timekeeper header and image: identical.
* card region: **907 whole 1 KB blocks differ**, all in card MB 27–31, spaced every ~4
  blocks (gap histogram: 4 ×770, 9 ×85, 3 ×36, 5 ×14). Every one of them is wrong in all 64
  of its 16-byte bursts. None of the 907 replacement blocks occurs anywhere in the good
  48 MB image (so not an address slip in the SDRAM read-back), and the same replacement
  blocks appear at *different* LBAs in the earlier failure's file (`…g.sav`, e.g. its block
  34735 == test3's 44663). Content looks like MP3 data.

## Mechanism

`s573_flash_saver` stages each block in `buf_mem`, then raises `sd_wr` and waits for
Main. Its capture port was

    else if (sd_buff_wr) buf_mem[sd_buff_addr] <= sd_buff_dout;

`sd_buff_wr / sd_buff_addr / sd_buff_dout` are hps_io's streaming bus for **every** slot;
only `sd_ack` is per slot (`hps_io.sv`: `sd_ack <= disk[VD:0]` on a 0x17/0x18 command).
In the attract loop the game reads the CD continuously (slot 1, 2352-byte sectors = 1176
words). Whenever Main delivered a sector to slot 1 between our fill of a block and its
0x18 read of it, the 1176 words wrapped over the 512-word buffer and Main wrote a CD
sector to the .sav at our LBA. Blocks are ~1.3 ms apart, CD sectors arrive at roughly a
quarter of that rate → every ~4th block. The same hole covered the LOAD capture (moot: the
CPU is in reset) and the new partial timekeeper saves (a settings save could have been
silently replaced by a CD sector).

Why it never showed before: the install-complete auto-save fires ~9 s after the last
flash write, when the game sits on its "install complete" screen and the CD is idle; the
OSD-open auto-save happens with the OSD open. A 48 MB manual save with the attract loop
running is the case that isn't covered.

## Fix

`else if (sd_buff_wr && sd_ack)` — one gate; `sd_ack` is our slot's. `sim/tb_s573_tk_nv.v`
now streams a 1176-word foreign sector (`sd_ack[4]=0`) before **every** SD service it
performs (writes and reads); RED under `SAVER_UNGATED_BUFF_WR=1` (19 failures), GREEN by
default.

## The three boots that isolated it

1. Known-good flash+card (09-17 backup) + current cassette block + zero timekeeper region →
   NOTE 605 once, game runs. Power cycle → clean boot, no NOTE 605, no PCCARD2.
   (Persistence itself is sound.)
2. Test-mode edit (song unlock code) with no manual save → power cycle → clean boot, unlock
   kept. (The partial save works; the edit is not the trigger.)
3. Manual OSD "Save Flash" in the attract loop → power cycle → PCCARD2. No "Flash saved"
   toast in 60 s either (see below).

## Also fixed in the same build

* **"Flash saved" toast lost.** `emu.sv` re-asserted `psx_info_req` every cycle while
  `saving_memcard` was high; hps_io latches `info` on the *rising edge* of `info_req`, so
  every other toast in that window was dropped. Now edge-triggered.
* **Host clock 1970.** This MiSTer has no RTC battery and no network; Main reports 1970
  (`tm_year % 100 = 0x70`). A reading with year ≥ 0x70 is ignored, and when no usable
  reading has arrived the LOAD also restores the saved clock bytes 8185..8191
  (`s573_tk_nv restore_clock`, `m48t58` load-port clock writes), so the game's clock resumes
  from the last save. The timekeeper no longer resets its clock on a core reset (battery-
  backed on the real part; power-up value stays 2000-01-01).
* Partial saves rewrite the cassette block too (`part_skip = 0`): the ZS01 dump port is a
  pure read, and a ZS01 title's legacy 48 MiB save without the cassette block now grows
  contiguously.

## Closed on the cabinet (job 148)

Boot with the restored save: clean. Test-mode edit → manual OSD "Save Flash" in the
attract loop → power cycle → clean boot, edit kept (the exact case that failed on 137).
Then: edit A → Save Flash → edit B → power cycle → both kept, so the saver is idle again
after a full save (no tail stall), and this time the "Flash saved" toast was seen. The
earlier "no toast" reports were the `saving_memcard` level mask above and/or a 2 s toast
missed while watching the drive light. Reference save: `out/sav-backup/ddrextrm.sav.20260928-tknv-good`.
