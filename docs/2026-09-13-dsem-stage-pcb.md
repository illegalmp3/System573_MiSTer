# dsem: X76F041 cassette PASSES; "STAGE PCB INITIALIZE ERROR" -> GN845-PWB(B) (2026-09-13)

**Hardware:** Dancing Stage Euro Mix (GE936 EAA) installed from CD to onboard
flash with the ge936ea X76F041 cassette (the first X76F041 this core has met on
silicon) and the flash saved. That is the Tier-2 question answered for that
chip: the X76F041 model authenticates against a real title.

Booting the installed game (Flash ROM, Standard cabinet) then stops at

    HARD-WARE ERROR -1N / STAGE PCB INITIALIZE ERROR / PLEASE CALL ATTENDANT

## Cause

A standard 2-player DDR cabinet reads its dance stages through a GN845-PWB(B)
multiplexor PCB per stage, not straight off the JAMMA edge. The game programs
each PCB over two k573dio lamp-output lines (callback offsets 4/7 = 0xe0 bits
12/13 for stage 0, 12/15 = 0xe4 bits 12/13 for stage 1, all inverted) and reads
the reply on that player's JAMMA direction bits. At boot it clocks a 13-bit ID
(0x0c90, LSB first) into each PCB and expects a fixed 22-step reply pattern on
input bits 1/2 (9/10). Nothing in the core produced that reply -- the lamp
lines ended at an unconnected `lamp_out` -- so the reply was "all released" and
the game declared the stage PCB missing.

The Solo titles (ddrsbm, ddrs2k) wire the six panels straight to JAMMA
(ddrsolo_output_callback has no stage) which is why this never surfaced.

## Fix (RTL, needs a bitstream)

`rtl/gn845pwbb.v`: transliteration of MAME ddr_state::gn845pwbb_do_w /
gn845pwbb_clk_w / gn845pwbb_read (BSD-3): per-stage 13-bit shift register on the
inverted CLK's rising edge, IDLE->INIT on 0x0c90 with mask 0xf9f9, 21 further
steps taking each byte from `(~0x06 | mask_tab[bit]) & 0xff` indexed by EACH
stage's own bit counter, back to IDLE (mask 0xffff) on the 22nd. The 16-bit mask
is ANDed onto the JAMMA word {P1,P2} in system573_top before s573_io -- only
bits 1/2 and 9/10 can ever clear, exactly MAME's 0x0f0f custom field.

Gated by a new `stage_mux_en` top-level input = ~solo_cab (emu.sv): a Solo
title drives those lamp lines as real lamps and must not be able to trip the
matcher.

`sim/tb_gn845pwbb.v` replays the handshake and checks the mask after every clock
against a table produced by an independent Python model of the MAME code (the
table equality is asserted in the commit), plus en=0 never masks and a bogus ID
never arms. tb_system573_top / tb_drivecheck gained the new port (tied 0).

## Next

Bitstream rebuild (Windows, -Crt), then relaunch dsem.mgl with Boot Device =
Flash ROM -- no reinstall, the flash save is intact. If the stage check passes
the rest is the known ddrs2k audio behaviour. ddrusa (ZS01) is staged behind it.
