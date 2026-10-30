# Project review: smoothness, optimization, cleanup -- 2026-10-02

Scope: rtl/, psx_patches/ + the patched psx/ tree, support/s573 (HPS service), the
Main hooks, tools/, sim/, docs/, mgl/, the build configuration, the last fit report
(job 204: 37,635 ALM, LABs 4,169/4,191) and the gameplay logs on the SD card.
Nothing was changed by this review. "Established" = read in the source or measured
in a log; "open" = needs a measurement before anything is built on it.

## 1. What the logs say about hitches

Per-second counters during songs (FRAMES = GP1(05) buffer flips, vblank = VBLANK irqs):

| log | title | song seconds | steady | off seconds |
|---|---|---|---|---|
| 2026-10-02 | ddr3mj | 124 | 30/60 in 113 | 3 at song start (17, 26, 29), rest are +-1 window jitter |
| 2026-09-29a | ddr3mj | 40 | 30/60 in 36 | 3 at song start |
| 2026-09-28j | ddrextrm | 113 | 60/60 in 100 | 4 at song start/end (14, 25, 27, 44); 2 s read 61 frames in 60 vblanks |

No sustained deficit. But a one-second counter cannot see a single late frame (a
29/31 pair is indistinguishable from the sampling window sliding), and the two
"61 in 60" seconds on ddrextrm are what a late flip followed by a catch-up looks
like. So: the core does not drop frames at any rate the existing instrument can
see, and the existing instrument cannot rule out the isolated hitch. Audio did not
underrun inside a song (underrun count flat, elastic buffer full at 512).

The recording itself: the GPU's video counter fixes the refresh at 59.82 Hz
(htotal 3413 / vtotal 263 at 53.693 MHz, psx/rtl/gpu_videoout_async.vhd). A
59.94 Hz capture/TV must repeat one frame about every 8 s, a 60.00 Hz one about
every 5.5 s. If the hitches in the footage are evenly spaced at one of those
intervals they are the capture chain, not the core. On the CRT the analog output
comes straight from that counter with no frame buffer, and the VBLANK the game
paces on is the same counter, so the two cannot slip against each other.

## 2. Findings that bear on smoothness and timing

**A. The game-visible music position starts one MP3 frame late (established; effect on judgments open).**
k573dio zeroes the 0xca/0xcc sample counter on the first frame-sync pulse. MAME
raises that pulse when a frame is DECODED, i.e. as its samples start to play
(mas3507d.cpp fill_buffer -> cb_mpeg_frame_sync(1), then append_buffer). The
service raises it when the frame has finished PLAYING (s573_core_advance_played),
lagged a further 256 beats, and delivered on a 5 ms poll boundary. So the counter
starts about 26 ms + 5.8 ms + 0..5 ms after the audio does, and the last term is
different for every song. This is the first place to look for the "late
Perfect/Great" sync report of 09-28 and for per-song variation. Needs a proper
source study and a bench before any change -- it moves every chart.

**B. Drain is enabled before the write pointer is delivered (established).**
Poll order is PTRS (sends the OLD pcm_wr) -> decode -> CTRL (DRAIN_EN). At a song
start the prefilled frames are not advertised until the next poll, so the reader
starts with one beat and starves ~5 ms. That is the "underrun moves only at stream
starts" the docs attribute to DDR3 latency. Fix: a second PTRS after decode.

**C. Diagnostics are on while playing (established).** With s573mp3.debug on the
card (hb=1 dump=1) Main is blocked ~1.8 ms once a second by the heartbeat; ~94 % of
that is the 579-word PC-profiler dump, which has no switch. The logger thread
inherits Main's pin to CPU 1 (main.cpp pins Main; upstream's own offload thread
pins itself to core 0 for this reason) and fsyncs to the same SD card. Without the
debug file the log is still opened and the thread still started, for every core
(the `first` block runs before the 573 gate). None of this can drop a video
frame -- the arrow clock is fabric-driven -- but it delays CD sectors and key
events by up to the stall.

**D. Decode burst cap (established).** 12 frames per poll at ~480 us each is up to
~6 ms of Main blocked after a re-arm or a watermark hold (the "~3 ms" comment is
stale). 2 frames per poll still fills 10x faster than real time. Do after B.

**E. Timing cost added relative to upstream PSX (established unless noted).**
* 0020 SDRAM CAS latency 3: +1 clk3x on every SDRAM read. Needed (CL2 is out of
  spec at 101.6 MHz). Whether it costs a whole clk1x per access is open; the
  cpubench sim answers it.
* 0006 + s573_flash: one 16-word line buffer; every miss is two serial ch4
  bursts at the lowest SDRAM priority. Measured ~0 % during ddrextrm gameplay.
* 0005 BIOS uncached: 25-26 clk1x per BIOS instruction. Only matters if gameplay
  executes ROM code; the profiler's bios class read 0.0 % in today's log.
* 0013+0019: the palette cache is invalidated on every VRAM upload. Their premise
  was withdrawn (audit 2026-06-10); candidate to revert after an A/B.
* MDEC: default "Accurate" is ~21 ms per movie frame vs ~14 ms "Fast" (OSD).
* Everything else in the patch set changes widths/addresses only.

**F. Latent wedges of the same class as today's CD bug (open, by inspection).**
* s573_ddram_arb zeroes its outstanding-read count on reset while the DDR3 port
  is not flushed; a beat returning after reset would wrap it and lock the DIO out.
* s573_cdimg S_STREAM still counts the shared sd_buff_wr strobe without its own
  ack and has no exit on a short transfer.
* The auto-save (s573_flash_saver) is armed by any accepted cassette write
  (emu.sv saver_activity). If a title writes its cassette in normal play, a full
  16/48 MB save starts ~9 s later with priority on SDRAM ch4. Check: an
  unexpected "Flash saved" toast during play.
* No timeout on the EXP1 read wait; the watchdog output is unconnected.

## 3. Area (the design sits at 99.5 % LABs)

| item | ALMs | action |
|---|---|---|
| s573_cdtoc | 1,054 (0 M10K) | track table is in registers; two write sites block RAM inference. ~1,000 ALMs back |
| s573_seccart | 2,312 | all four chip models at once (zs01 1,104); leave |
| savestates | 606 | not pruned with SS_ENABLE=0; known lever |
| s573_hps_ext | 539 | ~300 is the debug snapshot bank (words 3-30) |
| s573_prof / prof_gpu / prof_pc / sectrace / stage trace | ~330 | compile-time option |
| k573_mp3stream + its DIO read line | ~65 + mux | output is unused; a credit-paced counter replaces it |

Roughly 1,600-2,000 ALMs are recoverable without touching behaviour, cdtoc first.

## 4. Cleanup

* CLAUDE.md, README status, docs/STATUS.md and ROADMAP.md describe the upstream
  author's setup (dell build host, ssh mister, hub chat, Mac) and a June/September
  state. One live status doc; archive the June-August notes.
* tools/: ~20 scripts need infrastructure that does not exist here (dell_*,
  mister_*.sh, mame_* runners); stage_ddr4m.sh / stage_dsfdr.sh are superseded by
  stage_573.py. sim/Makefile calls a hub marker (ssh dell) after every test.
* psx_patches: 0012-0019 are eight patches that net to one (probes off, failed
  fixes off); 0002 targets a file no longer compiled; 0009 is disabled but present.
* files.qip omits four instantiated modules (found only via SEARCH_PATH); .qpf is
  gitignored but required by the build script; sim/Makefile.pcprof is a stale fork.
* mgl/_superseded (28 launcher pairs) can go; ddrusa/dsem can be generated like
  the rest. konam80s_console.mgl still loads blank flash/NVRAM on every launch.
* Service: dead constants, "STATUS words 36/37" comments (they are 32/33),
  decode_some's control flow lives outside the tested core and sim_loader.c
  carries a hand copy of it; the build script patches Main by exact string match.

## 5. Suggested order

1. No build: check the hitch spacing in the footage; play one session with
   s573mp3.debug removed; A/B "MDEC Timing = Fast" and "Turbo = Low" from the OSD.
2. Firmware only: B, D, logger pinned to CPU 0, diagnostics really off when off,
   profiler dump opt-in. Host tests first.
3. One bitstream: cdtoc to block RAM, instrumentation behind a define, the cdimg
   and ddram_arb guards with benches, plus a frame-interval histogram (vblanks
   between flips) so a single late frame becomes countable.
4. Its own piece of work: A, the sample-counter start, against MAME's
   mas3507d/k573fpga, in simulation, then on the SuperStation One with the chart offset.
5. Repo cleanup, in one commit series with no functional change.
