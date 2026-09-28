# ddrextrm: NOTE 605 "RTC-RAMをクリアしました" on every boot — the timekeeper was never saved

**2026-09-28.** Ricky: every ddrextrm boot stops on a blue NOTE 605 screen — "RTC-RAM
cleared; when the demo starts press TEST, enter test mode and redo the settings; press
TEST to continue". His guess: the game's NVRAM is cleared each start. Correct.

## What the game means

The System 573 keeps operator settings, bookkeeping and coin counters in the M48T58
timekeeper's 8 KB battery-backed SRAM (`0x1f620000`, `ksys573.cpp:977`). MAME treats that
device as NVRAM, and its own driver header says the note is a first-run thing: *"Note 4:
Some games require you to press f2 to skip the rtc cleared note."* — f2 is TEST. It
appears once because MAME writes the timekeeper back to disk on exit.

## Why it came back every time here

The core's only save-back for the timekeeper was the ioctl **upload** path
(`s573_nvram_saver`, `.mra <nvram index="3">` → `config/nvram/*.nvm`, `rtl/emu.sv`
`nvram_dirty` → `ioctl_upload_req`). Main fires that from the arcade `.mra` path only. Every
573 title is launched from an `.mgl` (six items, all used), so the request was never
serviced: the game wrote its settings into the M10K, the power went, the next boot read
zeros, the game saw no valid signature and asked again. The clock also restarted at
2000-01-01 00:00 each time (`m48t58.v` reset values; hps_io's `RTC[64:0]` was unwired).

## Fix

Same shape as the ZS01 cassette fix of 2026-09-16 (ERROR 175): the state rides in the
slot-4 `.sav`, which the flash saver already restores at boot.

* **`rtl/s573_flash_saver.v`** — the single "extra block" becomes an **extra-block region**
  (`xtra_blocks[3:0]`, addresses `{block, word}` 13 bits) after the flash image(s), and a
  **partial save** (`part_trigger`/`part_skip`/`part_started`/`part_done`) that rewrites only
  the region from `n_base + part_skip` — no SDRAM traffic, `saving` stays high so the
  CPU-reset hold (`busy & ~saving`) never asserts, no toast. Lowest priority in `S_IDLE`: an
  armed LOAD always restores the file before anything is written over it. `part_trigger` is
  a level; only its rising edge latches `part_pending`, because the level drops a few cycles
  after `part_started` and would otherwise queue a second, redundant save.
* **`rtl/s573_tk_nv.v`** (new) — serves the region as 9 blocks: block 0 a header
  (`"573NVTKP"`, version 1, type 1 = M48T58, length 8192 LE), blocks 1..8 the image read off
  the m48t58 save port (write-priority shared, 1-cycle read, retried on `sav_rd_ok=0`). A LOAD
  applies blocks 1..8 through the m48t58 load port only when the header matched — a zero
  region (freshly grown file) or a legacy file leaves whatever the `.mgl` loaded (hyperbbc's
  `.22h`) alone; bytes 8184..8191 (the clock) are never restored. Dirty tracking: the game's
  EXP1 write strobe (`nvram_written & ~reset`) sets `dirty`; `save_req` after **3 s quiet** or
  **30 s dirty without a break** (a game that never stops writing its bookkeeping still gets
  saved); `save_started` clears it at the START of the save so a write racing the snapshot
  re-arms a later one.
* **`rtl/m48t58.v`** — `set_valid/set_stb/set_data[55:0]` from the host clock: applied at
  every reading while `rst` is high (the clock is right the moment the CPU starts, and it keeps
  ticking through the reset hold — the 1 Hz divider is now free-running) and **once** at the
  first reading after `rst` falls, unless the game is inside a WRITE freeze setting the clock
  itself. Never again until the next reset, so a clock the operator sets in the test menu
  stands for the session, as it would with a battery. Same as MAME (`timekpr.cpp
  device_start` loads the system time). Day-of-week 1..7 = MiSTer wday + 1 (MAME
  `weekday + 1`).
* **`rtl/emu.sv`** — hps_io `.RTC(hps_rtc)`: Main sends `UIO_RTC` at core start and once a
  minute (`user_io.cpp send_rtc`: sec, min, hour, date, month, year%100, wday, 0x40, BCD;
  bit 64 toggles per update) → snapshot on the toggle → `rtc_set_*` into `system573_top` →
  m48t58. Extra-block mux: region block 0 → `u_cass_nv` when a ZS01 is fitted (`cass_off`),
  the rest → `u_tk_nv`; `xtra_blocks = cass_off + 9`; `part_skip = cass_off`. m48t58 load
  port muxed between the ioctl index-3 loader and `u_tk_nv` (never concurrent:
  `nvram_download` now resets the saver, `u_cass_nv` and `u_tk_nv`, and re-arms
  `flash_load_taken` exactly like an index-2/4 download). Save read port: the `.mra` upload
  packer when `nvram_upload`, else `u_tk_nv`. `saver_save_blocks` counts the region.
* **`support/s573/s573mp3.cpp` + `tools/build-hps-mp3.sh` graft 4** — `s573_sav_cangrow(index)`:
  `user_io_file_mount()` sets `sd_image_cangrow[index] = (pre != 0)`, and an `.mgl` type="s"
  item mounts with `pre=0`, so a write one block past EOF was clamped to zero bytes and
  dropped (`user_io.cpp` SD write path). Now `|| s573_sav_cangrow(index)` — slot 4 on the 573
  core only. `FileWriteAdv` already refreshes `file->size` after an append, so a `.sav` made
  before the region existed grows by 9 KB on the first partial save; the existing
  `ddrextrm.sav` on the T7 needs nothing done to it. (Block *n* may be written when
  `lba <= size/1024`, i.e. exactly one block past EOF, which is what sequential growth does.)
* **`tools/stage_573.py`** — new saves are sized with the region; an older save at either
  legacy size is appended with written zeros.

## Verified

* `sim/tb_s573_tk_nv.v` (9 tests, real saver + tk_nv + m48t58, cassette block as a stub so
  the emu mux ordering is exercised): full save layout byte-exact (header, image, live clock
  bytes); power-cycle + LOAD restores 8184 bytes (`restored`, clock bytes skipped, no dirty);
  legacy and blank regions leave the timekeeper alone; partial save writes LBAs 6..14 only,
  zero SDRAM bursts, cassette block and flash untouched, dirty cleared, a game hammering the
  port during the save still yields a coherent image and its racing write reaches the next
  save; AGE path fires for a never-quiet game; host clock semantics (set in reset, once after,
  later readings ignored, game's own clock write stands); ERASE zeroes the region.
  **RED under `TK_NV_NO_RESTORE=1`** (3 errors), GREEN by default. Full Icarus suite green.
* Quartus job 130 (rbf `c48805d1…`, DO NOT USE — see below); job 137 is the shipped one (md5 in `out/deploy-20260928/README.md`); firmware `out/MiSTer` md5 `290b9848…`.

## Job 130 black screen (the first build of this)

Ricky: "ddrextrm no longer boots" — Main's "Region Unknown → USA", then black, OSD alive.
`emu.sv` drove every wire of the new extra-block mux except **`xtra_wr_ack`**; Quartus tied
the undriven net to 0 (`Warning (10030)`, one line among ~20,000), the boot LOAD reached the
cassette block, waited in `LO_X_WAIT` for an ack that never came, `busy` stayed high, and
`flash_loading = busy & ~saving` held the CPU in reset for good. The bench had the line; the
top level is not simulated, so nothing caught it before the card. Now `tools/build-573.ps1`
fails a build on any 10030 whose file is under `rtl/` (the same scan also turned up the
`dio_gain_*` hps_ext debug leg as implicit 1-bit nets since it was added — declared and
wired). Nothing on the T7 was touched: the LOAD never finished, so nothing was written back.
Rebuilt as job 137.

## Expected on the cabinet

NOTE 605 once more on the first boot with this core (the blank state, then whatever the
operator sets, is saved 3 s after the last write — no toast); never again after that. The
clock in the test menu shows the real date and time. Bookkeeping survives power cycles.

## Follow-up (not in this build)

`part_skip = 0` — let the partial save rewrite the cassette block too (the ZS01 dump port is
a pure read port, safe during play). Then a ZS01 title's legacy 48 MiB save with NO cassette
block (never extended by stage_573.py) would also grow contiguously; with `part_skip = 1`
the region starts one block past such a file's EOF and Main refuses the gap. ddrextrm's save
was extended on 2026-09-16, so this build already covers it.
