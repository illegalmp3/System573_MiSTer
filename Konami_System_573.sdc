# =============================================================================
# Konami System 573 - core-specific timing constraints
#
# The clock definitions (CLK_50M, the PLL outputs, the HPS interfaces) come from
# psx/sys/sys_top.sdc and psx/PSX.sdc, listed in Konami_System_573.qsf. This file
# holds only what is specific to the 573 build. It was NOT listed in the .qsf
# until 2026-09-18 (its previous content -- a duplicate CLK_50M create_clock and
# derive_pll_clocks -- had therefore never been read, which is just as well).
# =============================================================================

# Savestates are compiled out of this core (rtl/emu.sv SS_ENABLE=0: the save/load
# requests are constants, so savestates.vhd only ever runs its reset sequencer and
# its read-data bus never carries live data). The clk_1x -> clk_2x re-registering
# of that bus (SS_DataRead -> SS_DataRead_2x) is the one hold violation left in the
# 2026-09-18 builds (-0.256 ns, slow 100C corner); it is a static signal here, so
# declare the transfer false rather than re-roll the placement for it.
# 2026-10-24: psx_patches/0034 drives SS_DataRead with a constant, so these registers
# no longer exist and the constraint is gone with them.

# clk_vid (2026-10-24). rtl/s573_pll2.v replaces the PSX core's Reconfigurable pll2
# with a General altera_pll at the same 53.693175 MHz (the 573 has no PAL mode and no
# fast-forward -- psx-spx games.md "Missing support for PAL mode"). derive_pll_clocks
# (sys_top.sdc) defines its output clock; its output counter is
# general[0].gpll~PLL_OUTPUT_COUNTER|divclk instead of the Reconfigurable PLL's
# cyclonev_pll|counter[0].output_counter|divclk, so psx/PSX.sdc's create_generated_clock
# and false paths for clk_vid no longer match a node. They are restated here, one for
# one, for the new node name.
set s573_clkvid {emu|pll2|pll2_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set_false_path -from {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} -to $s573_clkvid
set_false_path -from {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk} -to $s573_clkvid
set_false_path -from {FPGA_CLK1_50} -to $s573_clkvid
set_false_path -from {FPGA_CLK2_50} -to $s573_clkvid
set_false_path -from {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk} -to $s573_clkvid
set_false_path -from $s573_clkvid -to {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set_false_path -from $s573_clkvid -to {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}
set_false_path -from $s573_clkvid -to {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
set_false_path -from $s573_clkvid -to {sysmem|fpga_interfaces|clocks_resets|h2f_user0_clk}
set_false_path -from $s573_clkvid -to {FPGA_CLK1_50}
