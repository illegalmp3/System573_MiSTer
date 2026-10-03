# Review steps 2 and 3: firmware pass, track table to RAM, a late-frame counter -- 2026-10-02

Follows docs/2026-10-02-project-review.md. Hardware: pending for all of it.

## Step 2 -- firmware only (commit a031a31)

* **Pointer before drain enable.** The poll was PTRS -> decode -> CTRL, so DRAIN_EN
  reached the fabric a poll before the prefill was advertised: ~5 ms of starvation
  at every song and preview start, the underrun count that "moves only at stream
  starts". A second PTRS now follows the decode when the write pointer moved.
  sim/tb_s573_mp3_path.v has both orders: old counts underruns, new counts none.
* Decode cap 12 -> 3 frames per poll (measured ~480 us per frame).
* Logger thread created on core 0 (it inherited Main's pin to core 1); no stdout
  mirror. No s573mp3.debug -> no log file, no thread.
* PC-profile dump opt-in (`pcprof=1`): it was 579 of the heartbeat's ~615 SPI words.

## Step 3 -- one bitstream (job 218, seed 5) + matching firmware

**s573_cdtoc: the track table is a RAM.** Two write sites (the cdinfo commit and
`track_tbl[1] <= 0` at mount) made it 2,560 registers and a 128:1 mux. The mount's
"track 1 = data at LBA 0" is now a read-side flag cleared by the cdinfo commit of
track 1; the RAM is the plain one-write/one-registered-read template in its own
block. The first cut kept part-select reads inside the big always block and Quartus
still built registers (job 213 map report) -- job 215 (synthesis only) confirmed
`altsyncram:track_tbl_rtl_0` for the second. sim/tb_s573_cdtoc.v case [5] (track 1
override, remount, another track's commit, new cdinfo) passes on the OLD module too
(job 211), i.e. same observable behaviour.

| | before (job 204) | after (job 218) |
|---|---|---|
| ALMs | 37,635 | 36,652 |
| LABs | 4,169 / 4,191 | 4,150 / 4,191 |
| worst setup / hold slack | 0.673 / 0.074 | 0.794 / 0.073 |

**Flip-interval histogram.** s573_prof_gpu counts every buffer flip by the vblanks
since the previous flip (bins 0,1,2,3,4,5+; 8-bit cumulative), STATUS words 34..36,
logged once a second as

    s573mp3: flips: by vblanks since the previous flip 0=.. 1=.. 2=.. 3=.. 4=.. 5+=..

60 fps: everything in "1", a late frame is a "2". 30 fps: everything in "2", a late
frame is a "3". This is the instrument the per-second FRAMES/vblank counts could
not be. Bench: sim/tb_s573_prof_gpu.v (60 fps, one late frame, 30 fps, a hitch,
double flip, saturation, mod-256 wrap).

Suite: 65 tests green except s573_flash_erase, which aborts inside vvp in some runs
and passes in others (also on 09-29, job 192; it compiles none of the changed files).

## The build machine

Three Quartus runs in a row ended in an access violation:

| job | where | note |
|---|---|---|
| 213 | quartus_fit, router (`l_run_heap_expansion_algorithm`) | seed 4 |
| 216 | quartus_fit, router, same frame | seed 4, nothing touched during the run |
| 218 | quartus_sta (`BCM_TIMING_BLOCK_INFO::get_mode`) | seed 5; fit + assembler had finished |

Job 219 re-ran quartus_sta alone on job 218's database: clean on the first attempt,
all corners non-negative. Job 220 re-ran the assembler: identical .rbf
(md5 7f070d4c...). The qsf already records the same router fault from 2026-09-09.
Different executables faulting, and the same step passing on a re-run, points at
the machine or the Quartus 17.0 install more than at this netlist -- not
established. Until it is, a build that dies is re-run before it is diagnosed, and
only a bitstream whose STA completed is deployed.

Also: a bare `quartus_map` (job 215) made Quartus append the sys_pins.tcl pin
assignments to the .qsf. Restored from git before job 218; do synthesis-only checks
on a copy of the project, or restore the qsf afterwards.

## Deployed (SD card)

| file | md5 | previous kept as |
|---|---|---|
| _Console/Konami_System_573.rbf | 7f070d4c1fab40663a63407c2dd29b74 | Konami_System_573.prev-20261002b.rbf (the CD-fix build) |
| MiSTer | ccdac5edeec3e45b4acb1a339190e332 | MiSTer.prev-20261002b (step-2 firmware) |
| s573mp3.debug | hb=1 dump=0 mp3_frames=3 pcprof=0 | s573mp3.debug.prev-20261002a |

## Not done from the review's step 3

The cdimg S_STREAM ack qualifier and the ddram_arb reset count were found by
reading, with no evidence they fire: left alone. Instrumentation stays compiled in
while it is being used.

## Hardware result (2026-10-02, late session; log local/sdlog/s573mp3-20261002b-review-steps23.log)

ddr3mj and ddrextrm, three stages each plus a failed fourth, on rbf 7f070d4c /
firmware ccdac5ed. No music dropout, previews fine in both titles (the CD-reader
fix, commit 844d214, held: no `cd_fetch` run, no decode stall other than each
window's truncated tail).

Flip intervals over every gameplay song in the log:

| title | frames counted | on the nominal interval | off it |
|---|---|---|---|
| ddr3mj (30 fps, bin "2") | 10,914 | all mid-song frames | only in a song's first second and its last one or two (load / result transition) |
| ddrextrm (60 fps, bin "1") | 18,439 | all mid-song frames | 2 frames, both in a song's first second, plus one long gap at each start |

Not one late frame in the middle of a song in either title. The hitches seen in the
recorded footage were in the capture chain (RetroTINK + USB capture), and arrow
scrolling on the CRT looked fine to the player. CLOSED, no change.

`underrun=0` on all 1,131 heartbeats of both sessions, song starts included; before
the pointer-before-drain fix it rose at every stream start (8 by the first song of
the earlier log). That fix is confirmed.
