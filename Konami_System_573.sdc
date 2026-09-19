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
set_false_path -from [get_registers {*|savestates:isavestates|SS_DataRead[*]}] \
               -to   [get_registers {*|savestates:isavestates|SS_DataRead_2x[*]}]
