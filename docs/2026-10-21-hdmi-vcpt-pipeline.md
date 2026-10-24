# HDMI timing: ascal output line counter pipelined (2026-10-21)

The gfdm-r2 sources (MAS3507D gain, settings trailer / control layouts, PCMCIA slot 1,
debug OSD options kept) fitted at 39,0xx ALM (93 %) and missed pll_hdmi setup on both
seeds that ran: seed 5 -0.080 / -0.149 ns, seed 3 -0.163 / -0.221 ns (slow 100C / -40C).

`tools/hdmi_triage.tcl` on the seed-3 database (job 381, `local/re/hdmi_triage_r2s3.txt`):
every one of the 24 worst paths, both corners, is

    ascal:ascal|o_vcpt_pre3[1,3]  ->  ascal:ascal|o_vcpt_pre3[6,9,10]
    relationship 6.732 ns, skew -0.45, data delay 6.2 ns

the output sweep's vertical counter in `psx/sys/ascal.vhd` (OSWEEP): at the end of a line it
computes `o_vcpt_pre3+1`, compares it with `o_vtotal`, and picks 0 / `o_vsstart` / the
increment -- all inside the one cycle that also decodes `o_hcpt+1<o_htotal`. None of the new
573 logic is on the path; the fitter simply has less room around it at 93 %.

## Fix: psx_patches/0033-s573-ascal-vcpt-pipeline.patch

`o_vcpt_pre3_inc <= (o_vcpt_pre3+1) MOD 4096` and `o_vcpt_pre3_last <= (o_vcpt_pre3+1 >= o_vtotal)`
are registered on every o_clk (next to the existing `o_vcpt2 <= o_vcpt_pre3`, which ascal
already pipelines the same way for VRR), and the line-end branch uses them. `o_vcpt_pre3`
changes only at a line end and the next line end is at least `htotal` o_ce cycles later, so
the registered values are always current when used: the output is cycle-identical. The only
difference is that a change of `vtotal` takes effect one o_clk later (vtotal is already
crossed into o_clk with no synchroniser, the `<ASYNC>` comment in ascal).

Cost: 13 registers. Removed from the path: the 12-bit increment and the 13-bit compare.

## Equivalence: sim/ascal_equiv/run.sh (GHDL 4.1, WSL)

The pinned upstream `ascal.vhd` (entity renamed `ascal_ref`) and the patched file run side
by side with one stimulus: 32x24 input video, an avalon memory model per scaler, the
sys_top generics (MASK F7, PALETTE off, DOWNSCALE_NN, FRAC 8, N_DW 128, N_AW 28). Every
o_clk: o_r/g/b, o_hs/vs/de/vbl/brd, o_lltune, both avalon request buses and the internal
`o_vcpt_pre3` must be equal. Phases: o_ce every clock, every 2nd clock, pseudo-random;
vtotal / vsync / vdisp / htotal changed mid-line four times; VRR on with the input frame
faster, then slower, than the output, then VRR with random o_ce.

    psx/sys/ascal.vhd == pinned + 0033
    cycles 113894 frames 68 line steps 1910 vrr jumps 1393 mismatches 0
    PASS

`MUTATE=1` (end of frame one line early in the DUT) fails with 111,398 mismatching cycles,
so the bench sees a wrong counter. Sim-only edits, identical in both copies: three
`natural RANGE` counters that rely on wrap-around in the fitted logic (`o_off-1`,
`o_pshift-1`, `o_ihsize+o_off-2`) get an explicit MOD, because GHDL range-checks them.

`tools/apply_psx_patches.sh --check`: the stack 0001..0033 applies cleanly to the pin.
