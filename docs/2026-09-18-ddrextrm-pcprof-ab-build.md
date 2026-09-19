# ddrextrm 60 fps: the PC-profile + MDEC A/B build

**2026-09-18.** Follows `2026-09-18-ddrextrm-video-path-from-sources.md`. That note
established from the game code and the PSX core what the video path costs and
where the sources stop: the core's MDEC needs >16 ms per 304×176 15-bit frame
(2,171-cycle `IDCT_WAIT` from upstream `9530638`, a one-game compatibility
slowdown), which explains the half-speed videos; and nothing yet explains the
game's own drop to 30 fps, because the occupancy counters of run C cannot tell a
spin-wait from work. This build adds the instrument that can, and re-adds the
MDEC switch so both questions are answered by one bitstream.

## What is in the tree (on top of `ed00df8`)

| piece | files | status |
|---|---|---|
| frame-profile taps + counters (restored from `instr-mdec-a182001`) | `psx_patches/0029`, `rtl/s573_prof.v`, `rtl/s573_prof_gpu.v`, `rtl/system573_top.v` | unchanged from 09-17, already unit-tested (`tb_s573_prof*.v`) |
| MDEC 15-bit wait switch, OSD **"MDEC Timing: Accurate / Fast (test)"** `O[108]` (restored) | `psx_patches/0030`, `rtl/emu.sv` | default = upstream behaviour |
| **new: fetch-PC tap** | `psx_patches/0031-s573-cpu-pc-tap.patch` (`cpu.vhd`, `psx_top.vhd`, `psx_mister.vhd`) | observation only, 32 wires |
| **new: PC-sampling profiler** | `rtl/s573_prof_pc.v`, `sim/tb_s573_prof_pc.v` | one M10K (512 bins × 16 bit), ~40 flops |
| **new: mailbox command `CMD_573_PCPROF` (0x6E)** | `rtl/s573_hps_ext.v`, `sim/tb_s573_hps_ext.v` (P12 + new range top) | 21-word transaction, 32 per second |
| **new: HPS dump + mapper** | `support/s573/s573mp3.cpp` (`pcprof_dump`), `tools/pcprof_map.py` | two log lines per second |
| patch list | `tools/apply_psx_patches.sh` now lists 0029–0031; the full 0001–0031 stack was re-applied to the pinned core `67153439` here and produces byte-identical `mdec/psx_top/psx_mister/cpu.vhd` to the ones written into `psx/rtl/` | |

The psx working tree already carries 0029–0031 (the files were written directly),
so the Windows build script's patched-tree check passes without running the
applier.

## How the profiler works

`s573_prof_pc.v` samples the R3000's fetch PC every 1,024 clk1x (33,075/s) and
increments one of 512 cumulative 16-bit bins, each covering **2 KB of the first
MB of RAM** (the game executable loads at `0x80010000`, kernel below it). PCs in RAM
above 1 MB, in the BIOS ROM, or anywhere else go to three class counters. The bins
are never cleared: the HPS reads all 512 once a second and diffs against the
previous read (33,075 samples/s cannot wrap a 16-bit counter in a second), which is
the same cumulative-counter contract the other profile words use and keeps the
store to a single M10K with no sweep logic.

2 KB rather than 4 KB because of one boundary: in ddrextrm's libpress the blocking
`DecDCTin/outSync` spin loops sit at `0x80073380..0x800737c8` and `DecDCTvlc`
starts at `0x80073804`. The bin edge at `0x80073800` is exactly what separates
"the CPU is waiting for the MDEC" from "the CPU is expanding the bitstream" — the
distinction the whole question turns on.

`s573mp3.cpp` prints per second:

```
s573mp3: pcprof: samples=33075/s | ram<1M=97.9% ram>1M=0.0% bios=1.2% other=0.9% | top 80073800:31.2% 8001b000:22.0% ...
s573mp3: pcprof-hist:<512 × 4 hex digits>
```

and `tools/pcprof_map.py s573mp3.log --from A --to B` folds a window of those
lines onto the landmarks from the disassembly (kernel, libgpu VSync/DrawSync, the
movie kick state machine, libpress sync spins, `DecDCTvlc`).

## Before the build: the simulations

```sh
cd sim && make s573_prof_pc s573_hps_ext s573_prof s573_prof_gpu   # or the whole suite: make
```

`tb_s573_prof_pc` checks the cadence (including the first sample after reset), the
2 KB binning with the KUSEG/KSEG0/KSEG1 spellings, the three classes never touching
a bin, the mod-2¹⁶ wrap, the HPS read port under load, and reset semantics.
`tb_s573_hps_ext` gains P12 (a full PCPROF transaction against a registered RAM
model, with the class counters mutated mid-transaction to prove the snapshot) and
moves the "one past the range" boundary to 0x6F.

## The build

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\ricky\Documents\System573_MiSTer\tools\build-573.ps1 -Root C:\Users\ricky\Documents\System573_MiSTer -Crt
```

Expected cost over the 09-14 Tier-3 build (35,965 ALM / 98.7 % LABs): 0029+0030
were already fitted on 09-17 (their report was not captured); 0031 is wires; the
profiler is ~40 flops + 1 M10K; the mailbox grows by ~30 flops of mux. Verify the
`.rbf` after copying it to the card (starts with 0xFF, entropy ~7) — the 09-14 lesson.

## The firmware

`support/s573/s573mp3.cpp` changed (new `pcprof_dump`), so the Main binary needs
the usual cross-build (`tools/build-hps-mp3.sh`, gcc-arm 10.2 pin) and deploy to
`/media/fat/MiSTer`. A bitstream with the profiler and a firmware without it is
harmless (nothing polls 0x6E); the reverse prints nothing (the dump self-detects a
non-moving sample counter and stays quiet).

## The test, and what each outcome means

`s573mp3.debug` on the card (`hb=1`). ddrextrm, one song with a busy background
video, played twice: **run A** with `MDEC Timing = Accurate`, **run B** with `Fast
(test)`. Read the `gpu:` line (`FRAMES=`) and the `pcprof:` lines for the seconds
of gameplay; the video's speed is judged by eye (it is a two-times difference).

| pcprof during the 30-fps seconds | reading |
|---|---|
| `0x80073800` bin (DecDCTvlc) dominant, VSync bin small | the CPU is spending the frame expanding the bitstream: the R3000's RAM path in this core is slower than the real one for this load — next target is the memory timing (`memorymux.vhd`, SDRAM CL, ch4 arbitration), not the MDEC |
| `0x80073000` bin (in/outSync spins) large | the game IS blocking on the MDEC after all (a path the static reading missed) — the MDEC wait is the fix and run B should already show 60 |
| libgpu VSync bin large | the frame's work fits and the game is waiting for vblank: the 30 comes from something else (a missed vblank irq, double-buffer wait) — look at `vblank=` on the `gpu:` line |
| DrawSync bin large | the GPU upload of the 107 KB movie frame is the wall — cpu2vram throughput |
| kernel bins large | exception/interrupt overhead — look at what fires 33 k/s |

Run B's `FRAMES=` and the video speed are the MDEC verdict independently of the
profile: if B plays the video at full speed and A does not, the 2,171 wait is
confirmed as the video's problem regardless of what the game's frame rate does.

## Results (2026-09-18 evening, all through `tools/win/jobrunner.ps1`)

* WSL Ubuntu 24.04 provisioned by job (`wsl --install --no-launch`), Icarus 12,
  GHDL 4.1, NVC 1.22.1 from source; the firmware inputs fetched and the Main
  fork built (`out/MiSTer`, Main_MiSTer `f8dc68e` = Release 20260907, GLIBC_2.28).
* Simulation gate: `s573_prof_pc`, `s573_hps_ext` PASS; full suite 60/60 PASS.
  Two fixes came out of it: `bins` is a SystemVerilog keyword under
  `-g2005-sv` (renamed `hist`), and the histogram RAM is zeroed at power-up.
* NVC: the patched core (0029/0030/0031) analyzes and elaborates clean.
* Quartus build #1: 36,619 / 41,910 ALM (87 %), LABs 4,098 / 4,191 (98 %),
  profiler 58 ALM + 2 M10K (Quartus duplicated the RAM for the two read ports),
  35 min. **Timing FAILED** — see
  `2026-09-18-zs01-cipher-timing-and-the-silent-sta-check.md`; not deployed.
* Build #2 (ZS01 cipher pipelined, `rtl/zs01.v` two rounds per clock): 36,770 ALM
  (88 %), LABs 4,100 / 4,191 (98 %), 48 min. **Setup clean on every clock**
  (clk_1x +1.726 ns, worst +0.601 ns on clk_2x). One HOLD violation left:
  −0.256 ns, `savestates SS_DataRead[27]` (clk_1x) → `SS_DataRead_2x[27]`
  (clk_2x), slow 100 °C corner — inside the compiled-out savestate machinery.
* Build #3 with `OPTIMIZE_HOLD_TIMING = ALL PATHS`: **bit-identical .rbf** to #2
  (same md5) and the same −0.256 ns; the fitter could not pad that path.
* Resolution: the transfer is a static signal here (`SS_ENABLE=0`), so
  `Konami_System_573.sdc` now declares it a false path — and that file turned
  out never to have been listed in the `.qsf` (its old content was a duplicate
  `create_clock` that had never been read). Listed now; STA re-run on the
  build #3 database: **all corners non-negative** (setup +0.601, hold +0.070,
  recovery +17.8, removal +0.497). `tools/win/check-timing.ps1` rc=0.
* Deployed set: `out/deploy-20260918/` (rbf md5 `2713e2fb086d…`, `MiSTer`
  firmware, `s573mp3.debug`, README with the copy map and the A/B procedure).
