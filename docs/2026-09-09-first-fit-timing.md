# First successful fit: timing met by 6 picoseconds

**Build:** 2026-09-09, Quartus 17.0.2 Lite on Windows, `NUM_PARALLEL_PROCESSORS 1`,
`SEED 3`. 33 minutes. `.rbf` produced, 4.0 MB.

## Multicorner summary (worst per clock, setup)

```
Worst-case Slack                                    Setup 0.006   Hold 0.008
  pll_hdmi|...|counter[0].output_counter|divclk      0.006        0.096
  emu|pll|general[1].gpll~PLL_OUTPUT_COUNTER|divclk  0.505        0.008
  emu|pll|general[2].gpll~PLL_OUTPUT_COUNTER|divclk  0.520        0.075
  emu|pll2|...|counter[0].output_counter|divclk      0.775        0.076
  emu|pll|general[0].gpll~PLL_OUTPUT_COUNTER|divclk  1.375        0.084
  sysmem|...|h2f_user0_clk                           2.110        0.087
  FPGA_CLK1_50 / CLK2_50 / spi_sck / pll_audio       5.4 - 25.6   ok
Design-wide TNS                                     0.0          0.0
```

Resources: 39,246 / 41,910 ALMs (**94%**), LABs 4,188 / 4,191 (**100%**),
DSP 112 / 112, block memory 39%.

## Read

**Timing is met and TNS is zero, so the bitstream is valid.** It is also
**fragile**: the binding path has **+0.006 ns** — six picoseconds — of setup
slack, and the worst hold is **+0.008 ns**.

**Correction to an earlier hope.** Before seeing this I suggested that a clean
fit at 94% ALM might mean the DDR Solo Select L/R inputs were no longer blocked
by timing. The opposite is true: upstream cited **+0.069 ns** as the reason those
inputs were held back, and this build is **an order of magnitude tighter than
that**. There is no margin to spend.

**The binding clock is the HDMI scaler, not the 573 fabric or the PSX core.**
`pll_hdmi` owns both the 0.006 ns setup path and the 1.122 ns minimum-pulse-width
worst case. That matches what the qsf already records: physical synthesis took
the ascal HDMI setup slack from −2.143 to −0.322 ns, and `SEED 3` was chosen to
chase "the last 0.322 ns". It evidently found it — by 6 ps. That is seed luck, not
structural margin, and a different seed can plausibly land negative.

## What this changes

**Audit lever #2 (ascal bicubic off) is now the top lever**, not merely "open". It
is the only candidate that attacks the clock that is actually binding: it removes
logic from the ascal/HDMI path itself, where every other lever would free ALMs
somewhere the critical path does not care about. Its DSP saving is irrelevant now
(DSP is not the constraint); its *path* saving is the point.

Ordering that follows from these numbers:

1. **Test the current bitstream on hardware.** It is valid. Do this before
   touching anything.
2. **Lever #2**, if Select L/R or any other logic is wanted. Verify in the fit
   report that the `bic_*` registers actually prune — the audit flagged that as
   speculative, since ascal gates bicubic with a runtime `IF` inside a process
   rather than an `IF ... GENERATE`.
3. **Seed characterisation** before trusting any margin claim. At 6 ps, a
   single build tells you nothing about whether a change helped; a small seed
   sweep is the only way to separate signal from placement noise.

Do **not** read "+0.006 ns" as "closed with room". Read it as "closed, and the
next thing added will open it again".
