// -----------------------------------------------------------------------------
// s573_pll2.v - the PSX core's video PLL (clk_vid) at its fixed NTSC frequency,
// without the run-time reconfiguration port.
//
// psx/rtl/pll2 is a "Reconfigurable" altera_pll so the PSX core could retune clk_vid
// for PAL and for fast-forward through pll_cfg (an altera_pll_reconfig controller,
// 511 ALMs in the 2026-10-23 fit). The System 573 has neither: psx-spx
// docs/arcade/konami/573/games.md "Missing support for PAL mode" -- only the NTSC
// clock input of the GPU is wired, and GP1(08h) 50 Hz mode crashes the board.
// pll2 always powered up in its NTSC configuration (output_clock_frequency0
// 53.693175 MHz, psx/rtl/pll2/pll2_0002.v; the cfg_block in emu.sv only wrote the
// PAL / fast-forward settings on a CHANGE), so this is the same output clock as a
// "General" altera_pll -- the form psx/rtl/pll/pll_0002.v (clk_1x/2x/3x) uses --
// with the same reference (50 MHz) and fractional VCO.
//
// Hierarchy names follow the IP wrapper (pll2_inst / altera_pll_i) so the clock is
// still emu|pll2|pll2_inst|altera_pll_i|...; a General PLL's output counter is
// named general[0].gpll~PLL_OUTPUT_COUNTER|divclk, so the clk_vid false paths that
// psx/PSX.sdc writes for the Reconfigurable PLL's cyclonev_pll|counter[0] node are
// restated for this node in Konami_System_573.sdc.
// -----------------------------------------------------------------------------
`timescale 1 ps / 1 ps
module s573_pll2 (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0
);
	s573_pll2_0002 pll2_inst (
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.locked   ()
	);
endmodule

module s573_pll2_0002 (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire locked
);
	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(1),
		.output_clock_frequency0("53.693175 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("0 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("0 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst     (rst),
		.outclk  ({outclk_0}),
		.locked  (locked),
		.fboutclk( ),
		.fbclk   (1'b0),
		.refclk  (refclk)
	);
endmodule
