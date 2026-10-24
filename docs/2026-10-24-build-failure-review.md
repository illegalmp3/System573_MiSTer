# Why every HDMI build since 2026-10-20 missed timing, and the area fix (2026-10-24)

Scope: every Quartus run in `local/jobs/done` and `local/builds` since the HDMI build
that met timing (M6, job 326, 2026-10-18), plus tonight's hw-accurate seeds 7 and 5.
Rule applied: no more fits until synthesis shows real headroom.

## 1. What the builds show

| build | ALMs | LABs | worst | where |
|---|---|---|---|---|
| M6 (326), HDMI back | 38,903 | 4,181 | setup **+0.035**, hold +0.069 | met |
| release-rc1 (332) | 38,851 | | setup -0.046 | pll_hdmi (ascal) |
| rc1 seeds 3 / 6 (336) | | 4,182-4,183 | setup -0.245 / -0.304 | pll_hdmi |
| gfdm-r1 seeds 5, 1, 2, 4, 8 (376/378) | 39,005-39,100 | 4,182-4,191 | setup -0.111 .. -0.574; seed 1 **hold -0.093** | pll_hdmi; emu pll |
| gfdm-r2 seeds 5, 3 (379) | 39,022-39,123 | 4,188 | setup -0.149 / -0.221 | ascal o_vcpt_pre3 (job 381 triage) |
| gfdm-r3 seeds 5, 3 (391, +0033) | 39,074-39,077 | 4,186-4,191 | setup -0.083 / -0.040 | ascal o_vacpt -> o_adrs_pre (job 392 triage) |
| hw-accurate seed 7 (395) | 39,233 | 4,185 | **hold -0.598** | emu pll general[2] = clk_3x (SDRAM) |
| hw-accurate seed 5 (395) | 39,238 | | setup -0.083 | pll_hdmi |

Findings:

1. **The die is full.** Every fit is at 99.8-100 % of LABs. `build-573.ps1` has said
   "AT THE CONGESTION WALL" on each one. The 2026-09-10 CRT build measured what that
   costs: freeing 4,551 ALM moved *every* clock's slack up by 0.7-3.5 ns
   (docs/2026-09-10-crt-build-headroom.md). At this occupancy the timing report is
   measuring congestion, not logic depth.
2. **Fixing one ascal path moves the failure to the next one.** 0033 fixed
   o_vcpt_pre3 (-0.22 ns) and the miss moved to o_vacpt -> o_adrs_pre (-0.04/-0.08 ns).
   Pipelining more ascal paths cannot work at 100 % LABs.
3. **Hold misses appear whenever the router has no room** (gfdm-r1 seed 1 -0.093,
   2026-09-28 seed 3 -0.338 on sdram.sv, tonight -0.598 on clk_3x), even with
   OPTIMIZE_HOLD_TIMING "ALL PATHS".
4. **Some archived "results" are copies, not runs.** Seed loops copied
   output_files after seeds whose build script was missing (rc -196608). So
   gfdm-r1 seeds 8-12 (identical -0.241, 39,068), gfdm-r2 seeds 1/2/6/7 (identical
   -0.221/-0.163) and the gfdm-r3 summaries are the previous seed's files.
   `build-573.ps1` now deletes the old reports before each run.
5. Each feature added since M6 (DrumMania/Guitar Freaks profiles, the trailer, PCMCIA
   slot 1, the card reader fabric) cost ~100-200 ALM. That was enough to tip a design
   that only just met timing at +0.035 ns.

Area by entity, hw-accurate seed 5 fit (ALMs needed): ascal 1,976; psx 23,777 (cpu
3,476, gpu 5,962, gte 4,494, spu 4,780, dma 1,698, savestates 629, joypad 271);
system573_top 4,765; hps_io 1,073; s573_hps_ext 636; **pll_cfg 511**; OSD x2 1,028;
pll_hdmi_adj 510. The map report also shows **~2,900 LEs of savestate read-back
multiplexers** across cpu, spu, dma, memctrl, gpu, timer, sio, savestates.

## 2. What was removed, with the source for each

| change | source | expected |
|---|---|---|
| **PAL + fast-forward + pll_cfg**: pll2 becomes a fixed General PLL at the same 53.693175 MHz (`rtl/s573_pll2.v`); "System Type" leaves the OSD; isPal = 0; clk_vid false paths restated in Konami_System_573.sdc | psx-spx games.md "Missing support for PAL mode": only the NTSC GPU clock is wired, GP1(08h) 50 Hz crashes the board. Fast-forward has no 573 counterpart. | ~511 ALM |
| **Savestate read-back** off (`psx_patches/0034`): SS_DataRead constant, no save-path SS_rden. emu.sv ties save_state / load_state to 0. Reset sequencer untouched. | Savestates were already off (SS_ENABLE = 0, synthesis showed `savemode` stuck at GND), so the bus never carried data | most of ~2,900 LEs of mux |
| **SIO0 devices**: no pads, multitap, SNAC pad or memory cards (PadPortEnable1/2 = 0, memcard ports idle); Pad1/Pad2/SNAC MemCard/DS Mode/Multitap and the memory card mounts / saves / status leave the OSD | psx-spx 573/index.md: "The SIO0 bus for controllers and memory cards is unused ... no known I/O board uses it". The SIO0 controller (in the CPU ASIC) stays. | memcard x2 106, joypad_mem 99, plus emu logic |
| **PSX Debug page** (DDR3 FB view, VRAM viewer, sound off, SPU DMA timing, advance pause, sound IRQ trigger), **Cheats**, **Dithering** | Not 573 features. Dithering is tied to the hardware behaviour (the GPU dithers when the game sets GP0(E1h) bit 9). | small |
| **MISTER_DISABLE_ADAPTIVE** (qsf) | Upstream psx/PSX.qsf lists it as a resource saver. It removes ascal's luminance-adaptive filter math from the pll_hdmi domain, the domain that keeps failing. Adaptive filter files load as normal polyphase filters. | in ascal |
| 573 developer OSD diagnostics (Flash Debug overlay, Dbg Field, MDEC Timing test) behind `S573_DEVTOOLS` (off) | Developer tools; 18de8ea had already taken them off the release OSD | small |

Kept: every 573 option, aspect/scale/crop/deinterlace/480i sync, stereo mix, pause when
OSD open, YC/composite (the cabinet CRT), the profilers and STATUS counters behind the
s573mp3 log (observability for hardware reports).

Not taken (documented for later): the s573 profilers (~250 ALM, prof + prof_gpu +
prof_pc), and NUM_PARALLEL_PROCESSORS (set to 1 after the parallel router crashed on an
earlier machine; it changes build time, not area).

## 3. Measured: Analysis & Synthesis (job 398, 192 s)

| | hw-accurate (2026-10-23) | hw-area (this) | change |
|---|---|---|---|
| ALMs needed (synthesis estimate) | 39,010 | **35,911** | **-3,099** |
| combinational ALUTs | 56,861 | 52,849 | -4,012 |
| registers | 43,841 | 41,866 | -1,975 |
| DSP | 99 | 95 | -4 |
| block memory bits | 2,032,539 | 2,020,128 | -12,411 |
| undriven nets in rtl/ | 0 | 0 | |

By entity (ALUTs): pll_cfg -827 (gone), cpu -610, gte -476, spu -442, dma -360,
joypad -196 (joypad_mem -137), hps_io -185, savestates -175, gpu -135, memctrl -101,
ascal -64 ALUT / -452 registers (ADAPTIVE), timer -58. The fitted hw-accurate seeds
used 39,233-39,238 ALMs against the 39,010 estimate, so the fit should land near
36,100 ALMs (86 %), below the 36,637 of the 2026-09-10 CRT build that met timing
with +1.2 ns.

## 4. Verification before any fit

1. Verilog benches (`make -C sim`, gate5_replay), support tests: unchanged RTL there.
2. Full-system NVC boot (sim/system573, Konami BIOS, 300 ms, TURBO=0): psx/rtl with
   0001..0033 vs 0001..0034, same harness (SIO0 empty, as the core now is). 0034 must
   leave the boot cycle-identical: same milestones (`tools/check_boot.py --compare`) and
   identical io/exp1/pc traces.
3. `tools/build-573.ps1 -SynthOnly`: Analysis & Synthesis only (~10 min), ALM estimate
   against the 2026-10-23 map figure, and no undriven nets in rtl/.
4. One fit, one seed, only if (3) shows the recovery.

## 5. Result: one fit, seed 7 (job 400, 2026-10-24)

| | hw-accurate seed 7 (2026-10-23) | hw-area seed 7 |
|---|---|---|
| ALMs | 39,233 (94 %) | **35,795 (85 %)** |
| LABs | 4,185 | 4,154 |
| DSP | 99 | 95 |
| worst setup | +0.106 | **+0.084** (pll_hdmi) |
| worst hold | **-0.598** (clk_3x) | **+0.066** |
| design-wide TNS | -0.598 | 0.0 |

All corners non-negative, no undriven nets in rtl/, .rbf 3.9 MB
(local/builds/hw-area-fit). Per clock (setup / hold): clk_1x +3.088 / +0.066,
clk_2x +0.361 / +0.088, clk_3x +0.664 / +0.165, clk_vid +7.315 / +0.078,
pll_hdmi +0.084 / +0.119. clk_vid: VCO 429.49 MHz / 8 = 53.69 MHz, the same divider
pair the Reconfigurable pll2 used for NTSC (M 4+4, C0 4+4). savestates entity
465 ALM (was 629).
