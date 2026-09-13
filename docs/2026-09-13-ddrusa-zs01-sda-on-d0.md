# ddrusa: ZS01 SDA is on data-latch D0, not the control register (2026-09-13)

DDR USA (GKA44 UAA) stopped at INFO 121 "Cassette error (3). Cassette does not
match this game (G*A44UAA)". That message -- not "Security Chip error", not
"Cassette not installed" -- means the ZS01 answered enough to be identified but
the game code read back from it was wrong.

## The dump is right

gka44ua.u1 (padded 140 -> 4116 B for the size-based type inference) carries, in
its plaintext data area [28:139], `47 4b 41 34 34 .. 55 41` = "GKA44..UA" -- the
correct DDR USA code. So the failure is in READING it, not the data.

## What the game actually does (disasm of PSX.EXE)

The installer's ZS01 driver bit-bangs the security latch at 0x1f6a0000:
  * send-a-bit (0x80323b40):  `v = (latch & 0xfffe) | data_bit; *0x1f6a0000 = v`
    -- the command bit rides **D0**, MSB first, SCL on D1.
  * read-a-bit (0x80323ca0):  clears CONTROL reg 0x1f500000 **bit 6** to release
    the line, pulses SCL (D1), samples 0x1f400006 **bit 2**.
So on the 573 side the ZS01's SDA net is the wired-AND of the latch D0 and the
control-register bit-6 driver; the game drives data on D0 and only uses bit 6 to
let go before a read.

## The bug

`rtl/s573_seccart.v` drove `zs01_sda_i` from `~io0_dir` (control bit 6) ALONE and
left D0 disconnected for the ZS01 -- a too-literal reading of MAME k573cass
(`write_line_zs01_sda`, "D0 unconnected"). MAME is right that the ZI *cassette*
doesn't wire D0 to the chip, but the 573 mainboard ORs latch D0 onto the same
SDA net, which is what the game uses. With D0 ignored, every command bit the
game clocked in was lost; the ZS01 saw no valid packet and returned garbage, so
the ID compare failed.

The gtrfrk5m ZS01 regression in tb_s573_seccart passed because its synthetic
master drove `io0_dir` directly -- RTL and bench encoded the SAME wrong
assumption. The read-back path (sec_io0 = 0x1f400006 bit 2) was always correct.

## Fix

`zs01_sda_i = d_q[0] & ~io0_dir` -- open-drain wired-AND of both drivers. In
practice the game never pulls bit 6 low, so this reduces to D0. tb_s573_seccart
Part 3 now drives the ZS01 command bits on D0 (holding io0_3 released), matching
the game; it exercised the real gtrfrk5m dump and still must read addr0 back.
Needs a bitstream.
