# ddrextrm 30 fps: the PC profile's verdict, and the i-cache patch that caused it

**2026-09-27.** Follows `2026-09-18-ddrextrm-pcprof-ab-build.md`. The cabinet ran the
PC-profiler bitstream (`out/deploy-20260918`, rbf md5 `2713e2fb…`) on ddrextrm: one song
with a busy background video, played with **MDEC Timing = Accurate** and again with
**Fast (test)**. The log (`local/sdlog/s573mp3.log`, 518 profiled seconds) is read here;
the reading led to an instruction count, an RTL re-read, and a simulation. All numbers
below are from those artefacts, not from expectations.

## 1. What the log says

The same song appears twice (`CFG epoch=35` and `epoch=57`, `start=00000000
end=00169297`): profile seconds **264–350** (Accurate, MDEC busy per macroblock the higher
of the two) and **425–511** (Fast). `tools/pcprof_map.py local/sdlog/s573mp3.log --from A --to B`:

| window | FR (flips/s) | VSync spin (libgpu 0x8001b000) | **DecDCTvlc** (0x80073800) | kernel | DrawSync | 0x800bf000 (EXP1 flash/dio code) | MDEC busy | mb/s (raw counter) |
|---|---|---|---|---|---|---|---|---|
| song intro, no video (250–262) | **60** | 65.3 % | 0 | 5.3 % | 1.8 % | – | 0 | 0 |
| gameplay + video, Accurate (266–286) | **30** | 45.0 % | **25.7 %** | 7.1 % | 2.7 % | 2.9 % | 24.5 % | 1450 |
| gameplay + video, Fast (456–500) | **30** | 43.9 % | **25.4 %** | 6.8 % | 2.7 % | 4.3 % | 20.8 % | 1680 |
| the "busier arrows" seconds (288–293) | 38 | 37.1 % | 30.8 % | 8.1 % | 3.3 % | – | 39 % | 1900 |

Reading, in order:

* **The game is CPU-bound, by ~2 ms.** VSync spin = idle. Intro: 35 % busy = 5.8 ms of
  work per 16.7 ms frame → 60 fps. With video: 55 % busy = **18.4 ms per 33.3 ms frame**:
  every frame overruns one vblank and lands on the next → a hard 30. The seconds that
  reach 38–40 fps are the ones where DecDCTvlc got cheaper (simpler frames) — the
  cabinet observation "static background → smoother arrows" is exactly this.
* **The MDEC is not the limiter.** 21–25 % busy in both runs, and the Fast switch (the
  2,171-cycle wait removed) moved the MDEC's own numbers only; the CPU profile and FR
  did not move. The 09-18 note's suspicion of the MDEC wait is closed: it costs the
  MDEC time it has to spare.
* **The video runs at exactly game-fps ÷ 2, so "half speed" is the game's 30 fps.** The
  game does one `DecDCTvlc` *half-frame* per game frame (`DecDCTvlcSize((mdec_len+2)/2)`
  at `0x80071ea0..0x80071ec0`, continuation calls `DecDCTvlc(0,0)` at `0x80071ee4`), so
  a video frame needs two game frames: 15 fps at 30, 30 fps at 60. (The raw macroblock
  counter reads half of 15 × 209 because the MDEC pulses it for one **clk2x** cycle and
  the counter samples on clk1x — fixed below; the 38-fps seconds' 1900 ≈ 19 fps × 209 ÷ 2
  confirm the ratio.)
* **So the whole question is why DecDCTvlc takes 8.5 ms per game frame** (25.5 % of a
  second at 30 calls/s).

## 2. What DecDCTvlc should cost: run the game's routine on the game's data

`tools/mips_count.py` is a 200-line R3000 interpreter that loads the extracted
executable (`out/re/ddrextrm_game.bin`) as RAM and calls the game's own `DecDCTvlc`
(`0x80073804`) on real frames from the C36 disc (`local/re/JBAACF.SBS`, extracted from
`dumps/mame573/c36jaa02.chd` `/MOV/`; 353 such files, 80 frames × 8 KB each, 9.8–12 k
MDEC codes per frame), exactly as the game does (size limit, continuation call):

```
frame   codes     instr    loads   stores  calls  instr/code  loads/code  stores/code
0       10368    175814    14347    10380      2    17.0    1.38    1.00  per call: 87723 88083
1       10304    175288    14334    10316      2    17.0    1.39    1.00  per call: 87191 88089
2       10368    175845    14355    10380      2    17.0    1.38    1.00  per call: 87714 88123
```

One half-frame call is **~88 k instructions, 7.2 k loads, 5.2 k stores**. An R3000 issues
one instruction per cycle from its i-cache; the measured 8.5 ms is 288 k cycles →
**CPI 3.3** on a loop that has 0.14 memory operations per instruction. Even at 6 cycles
per load and 1 per store that is ~130 k cycles = 3.8 ms. Something is charging ~160 k
cycles per call that is not loads and not instructions.

## 3. The charge: psx_patches/0004 turns every cache-line crossing into a miss

`psx_patches/0004-s573-cpu-icache-redirect-fix.patch` (June, the color-bar crash) changed
`cpu.vhd`'s hit test from upstream's

```vhdl
cacheHitTest <= '1' when (unsigned(tag_q_b(19 downto 0)) = FetchAddr(31 downto 12)
                      and tag_q_b(20 + to_integer(unsigned(FetchAddr(3 downto 2)))) = '1') else '0';
```

to one that additionally requires `cacheLineFetched = FetchAddr(11 downto 4)`, where
`cacheLineFetched` is `FetchAddr(11 downto 4)` **registered on the previous clk1x edge**.
Its premise (patch header): "the i-cache tag/data read ports (tag_q_b, cache_q_b) are
synchronous (1-cycle latency)". The tag store is not: `itagram` is `mem.RamMLAB`
(`cpu.vhd:618`), and `RamMLAB` is an asynchronous read — `rdaddress_reg => "UNREGISTERED"`
in `psx/rtl/RamMLAB.vhd` (altdpram, MLAB), `q <= ram(to_integer(unsigned(rdaddress)))`
in the sim model — so `tag_q_b` already describes the *current* `FetchAddr`. Only the
data store (`dpram`, M10K) is registered, and upstream consumes it one cycle later through
`PCold0`, which is correct. The extra condition therefore never guards a stale read; what
it does is fail the hit test on **the first cycle of every new line**: every 4th
sequential instruction and every taken branch to another line goes through
`mem1_request` → memorymux → SDRAM, refilling a line that was already valid.

The June crash it was written for was real but had another cause: cached fetches from the
BIOS mirror (`0x9FC00000`) get a tag written (`tag_wren_a` on `mem_done`) but no data
(the SDRAM cache fill `cache_wr` runs only for RAM-region reads, `memorymux.vhd` sets
`ram_cache <= '0'` on the `READBIOS` path), so the next hit on that line returns stale
words. `psx_patches/0005` (BIOS fetches uncached, tags not written) is the fix for that;
0004 only changed the timing around it.

### Measured, not argued: `sim/system573/run_cpubench.sh`

`tools/cpubench_rom.py` builds a 4 KB probe ROM (copies three loops into RAM through KSEG1,
jumps to the cached alias `0x80010000`); the tb's new generic-gated `CPUBENCH` tap stamps
every taken branch with the clk1x cycle count (`bench_trace.log`); `tools/cpubench_report.py`
prints cycles per iteration. Full core, `TURBO=0`, NVC 1.22, both variants built from the
same tree with `RTL_DIR=` pointing at `psx/rtl` vs a copy with 0004 reverse-applied
(`local/psx_rtl_no0004`, `patch -R`, 4 hunks, offsets only):

| loop | instructions / iteration | line changes / iteration | **with 0004** | **without 0004** |
|---|---|---|---|---|
| A: 62 × `addiu` + counter + `bne` + delay slot, 16 full lines | 65 | 17 | **150** cycles | **65** cycles |
| B: the same branch inside one line | 4 | 0 | 4 | 4 |
| C: B plus one `lw` from RAM | 4 (+1 load) | 0 (fetch runs 1 word past the line) | 13 | 7 |

Steady-state median over 198 iterations, min/max within ±2. **+5 clk1x per line crossing**,
and the branch-shadow fetch after a load costs 6 more. Without the patch the core does
what an R3000 does: 1 instruction per cycle from cache, a RAM load ≈ 4 cycles.

Applied to the 88 k-instruction VLC call: ~22 k sequential crossings + branch crossings
at 5 cycles ≈ 150 k cycles, plus the load-shadow effect on 7 k loads ≈ 40 k — the
"missing" 160 k cycles of §2, to within the estimate's precision. Every other piece of
cached game code — the kernel's 7 %, the game's own 5 ms, `DrawSync`'s queueing — has
been paying the same tax since June, which is why the PSX core's *Turbo* setting (which
shortens the modelled waits, not an i-cache refill) changed nothing on 09-17.

## 4. Changes in this tree

* `psx_patches/0004…` → `psx_patches/retired/`; dropped from `tools/apply_psx_patches.sh`
  (comment left in its slot). `psx/rtl/cpu.vhd` regenerated from the pin + the remaining
  stack and checked byte-identical to the reverse-patched copy (job 057).
* `psx_patches/0030` (MDEC A/B + macroblock tap): `dbg573_mb` is now a **toggle** driven
  from `mb_toggle` (clk2x); `rtl/s573_prof_gpu.v` counts every level change
  (`mdecmb ^ mb_q`); `sim/tb_s573_prof_gpu.v` drives toggles. Fixes the ×2 undercount of §1.
* `sim/system573/tb_system573.vhd`: `CPUBENCH`/`BENCH_HALT` generics + tap (off by default).
  `sim/system573/run.sh`: `RTL_DIR`/`TAG` overrides for A/B builds. New
  `sim/system573/run_cpubench.sh`, `tools/cpubench_rom.py`, `tools/cpubench_report.py`,
  `tools/mips_count.py`.
* Regression: the full BIOS boot harness (`run.sh 300ms`, `TURBO=0`, FAST_BOOT
  shortcuts) with 0004 removed — result in §5.

## 5. Results

### BIOS boot regression without 0004 (job 055)

`RTL_DIR=local/psx_rtl_no0004 TAG=no0004 TURBO=0 sim/system573/run.sh 300ms` (the Konami
BIOS with the FAST_BOOT sim shortcuts, realistic memory timing, 29 min wall):

```
[x] reset  [x] ram_test  [x] watchdog  [x] bss_clear  [ ] copy_loop (NOP'd by FAST_BOOT)
[x] main_init  [x] gpustat_poll  [x] gpustat_done  [x] draw  [x] framebuffer (non-black)
last PC 0x803C8CA4 (the 573 EXE's frame loop); exc_trace: 20 syscalls + timer/VBLANK
interrupts, no AdEL/AdES/RI/bus-error exception in 300 ms.
```

The boot runs past the June crash point into the EXE's POST/frame loop with the cache
behaving as upstream. The with-0004 baseline (job 066, same harness settings, 24 min)
reaches the same set, and `tools/check_boot.py build_no0004 --compare build_with0004`
reports **COMPARE OK: preserved all 9 baseline milestones in order; same furthest point**.

### Stack consistency (jobs 060–064)

`tools/apply_psx_patches.sh --check`: 29/29 remaining patches apply to the pin;
`psx/rtl/cpu.vhd` = pin + stack, md5 `7c9f6685dcbc26358a8bf1cef5c2283c` (identical to the
`patch -R` copy the benchmark ran on). Icarus: `s573_prof_gpu s573_prof s573_prof_pc
s573_hps_ext` PASS with the toggle change. NVC: `psx_mister` elaborates clean.

### Build

`tools/build-573.ps1 -Crt` on this tree (job 065, 26 min) → `out/deploy-20260927/`: 36,848 ALM
(88 %), LABs 98 %, setup slack +0.980 ns, hold +0.069 ns, all corners non-negative; rbf md5
`4369a64f1e512e4495fb6673901fc472`, 4,038,308 bytes, header FF FF FF FF, entropy 7.05.
Deployed to the card by job 066b (`E:\_Console\Konami_System_573.rbf`, byte-compared;
previous kept as `Konami_System_573.prev-20260918.rbf`; old log → `s573mp3.20260918.log`). The profiler,
the `MDEC Timing` OSD item and the firmware stay as deployed on 09-18, so the same log
lines answer the question on the cabinet: expect `FRAMES=60/s` during the song's video
and the `80073800` (DecDCTvlc) share to drop from 25 % to ~10 %; `mdec_mb` should now read
~3100/s (15 fps × 209) with the toggle fix.

## 6. What this does not settle

* The absolute RAM load cost in the core (≈4 clk1x for a hit-free `lw`, loop C) versus the
  real console has not been checked against a documented figure; it did not need to be for
  this problem, and the profile's 13.5 % `cpu_stall` did not move between idle and loaded
  seconds. If a title is still short of 60 after this fix, that is the next measurement,
  with the same probe ROM (add a loop of dependent loads).
* The 573 EXP1 access timing (flash reads for the movie slots, 60 k/s, `0x800bf000` bin
  ≈4 % — the digital-board/flash helper code) is modelled by the PSX core's `ext_waitcnt`
  from the game's own delay-register writes; unverified against a real board, small.
