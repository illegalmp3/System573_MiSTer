# CRT-only build: the die stops being full

**Build:** 2026-09-10, `tools/build-573.ps1 -Crt` (MISTER_DEBUG_NOHDMI), Quartus
17.0.2, serial routing, `SEED 3`. 1,403 s. `.rbf` 3.8 MB. **Untested on hardware
at time of writing.**

## Measured

| | HDMI (2026-09-09) | CRT (this) | Δ |
|---|---|---|---|
| ALMs | 39,246 / 41,910 (94%) | **34,695 (83%)** | −4,551 |
| LABs | 4,188 / 4,191 (**100%**) | **4,041 (96.4%)** | −147 |
| DSP | **112 / 112 (100%)** | **89 / 112 (79%)** | −23 |
| Registers | 46,136 | 39,535 | −6,601 |
| Block memory | 39% | 33% | −351 Kbit |
| Worst setup | **+0.006 ns** | **+1.196 ns** | ~200x |
| Worst hold | +0.008 ns | +0.021 ns | ~2.6x |
| Build time | 2,006 s | 1,403 s | −10 min |

`pll_hdmi` and `FPGA_CLK1_50` are gone from the multicorner table entirely.
Design-wide TNS remains 0.

## Two things I predicted wrong, both in the same direction

**Area: I said ~2,256 ALM, got 4,551.** My figure came from the June audit's
per-entity table, which lists `ascal` alone. `MISTER_DEBUG_NOHDMI` removes the
whole HDMI subsystem — the `pll_hdmi` PLL and its adjuster, the HDMI I2C config
block, the `vga_scaler_out` instance, the video-calc logic — not just the scaler.
The 351 Kbit is ascal's line buffers; the 23 DSP matches the estimate closely.

**Timing: I said worst setup would become `general[1]`'s old +0.505 ns, got
+1.196 ns.** The reason is more interesting than the number: *every* remaining
path improved, not just the ones ascal was on.

```
emu|pll general[1]   +0.505 -> +1.303
emu|pll general[2]   +0.520 -> +1.196
emu|pll2             +0.775 -> +1.436
emu|pll general[0]   +1.375 -> +2.269
h2f_user0_clk        +2.110 -> +5.599
```

At 4,188/4,191 LABs the congestion was taxing the whole design. Freeing 4,551 ALM
let the fitter place everything with room, and the slack came back across the
board. **The lesson to keep: at ~100% LAB occupancy, timing numbers are reporting
congestion as much as logic depth, and per-path reasoning about them is unsound.**

## Correction: the Select L/R inputs were never actually blocked

The headroom work above was justified — by me, repeatedly — as unblocking the DDR
Solo song-wheel inputs, on the strength of the README's "🏗️ written + simulated,
not in a shipped bitstream (no timing headroom)".

They are not gated. `rtl/emu.sv:2351-2352`:

```verilog
.btn5_p1 (~(solo_cab & sel_l)),   // "P1 Select L"
.btn5_p2 (~(solo_cab & sel_r)),   // "P1 Select R"
```

`solo_cab` is the OSD option `O[100],573 Cabinet,Standard,DDR Solo` — a runtime
switch, not a build-time constant. `rtl/s573_io.v:150,156` wires both into IN3
bit 9 unconditionally. So the feature is present in **every** bitstream built from
this tree, including the 2026-09-09 HDMI one, and is reachable by flipping the
cabinet option. The README's claim was about upstream's *shipped* bitstream; the
code landed in the repo anyway.

The recovery work still stands on its own terms — DSP is off a ceiling it has held
in every recorded build, and there is now room to add RTL without a fight — but
the goal it was argued from had already been met, and the argument was wrong.

## Not verified

This bitstream has not been on hardware. It is a new video configuration (no HDMI
path at all, `direct_video` forced on), so the plausible failures are the CRT not
locking, or the OSD compositing differently. `Konami_System_573_known_good.rbf`
is the fallback.
