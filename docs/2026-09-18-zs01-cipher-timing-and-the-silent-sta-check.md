# The ZS01 cipher was failing timing, and the build script could not see it

**2026-09-18.** Found while building the pcprof/MDEC A/B bitstream
(`2026-09-18-ddrextrm-pcprof-ab-build.md`).

## What the report said

`build-573.ps1` printed *"all corners non-negative"*. The multicorner summary in
`output_files/Konami_System_573.sta.rpt` said otherwise:

```
; Worst-case Slack   ; -1.714 (setup) ; 0.087 (hold) ; ...
;  emu|pll|...general[0]...divclk (clk_1x 33.87 MHz) ; -1.714 ; TNS -310.932
```

`tools/timing_triage.tcl` (run under `quartus_sta`, slow −40 °C corner) lists
283 failing setup endpoints — **every one inside `rtl/zs01.v`**: `pidx`/`rbuf`/
`wbuf` → `wbuf`/`rbuf`/`pprev`. The ATAPI, EXP1 and system573_top paths close
with +8 to +17 ns; the new profiler and mailbox logic are not on any failing path.

## Why the script missed it

```powershell
$neg = Select-String -Path $sta -Pattern '^\s*;\s*-\d'
```

looks for a report line that *begins* with a negative number. No row of a
TimeQuest summary does (the clock name comes first), so the check has passed
unconditionally since it was written on 09-09. Every "timing clean" claim made
from this script's output between then and now is unverified — including the
09-14 Tier-3 build's. The 09-09 CRT figure (+1.196 ns) came from reading the
report directly and stands.

Fixed: the script now walks the *Multicorner Timing Analysis Summary* table and
fails on a negative number in any column; `tools/win/check-timing.ps1` applies
the same rule to an existing report (verified: it fails this build, rc=1).

## Why the cipher failed

`zs01.v` evaluated the packet cipher's **seven dependent rounds in one clock**
(`dec_rounds` / `enc_byte`: subtract + barrel-rotate, seven times, behind a 12:1
byte mux and in front of a write-back mux). Seven dependent 8-bit stages plus
routing is ~30 ns; the clk_1x period is 29.5 ns.

Fix: two rounds per clock, four clocks per byte, running value in `tacc`
(`dec_round2` / `enc_round2`; the last round is folded into the write-back
cycle). Same arithmetic, same order, same chaining — only register boundaries
moved. A packet now costs ~150 clocks (~4.4 µs) instead of ~60. The real ZS01
is a PIC that takes hundreds of microseconds per packet and the host waits
for it; the engine's sticky `overrun` flag (an SCL edge arriving mid-packet)
still guards that assumption and is visible in the HPS log (`ovr`).

Verified before the rebuild: `zs01 zs01_golden zs01_rtr zs01_detect zs01_cmd
s573_seccart s573_cass_nv sectrace_arm system573_top` all PASS — `zs01_golden`
replays the real ddrusa cassette vectors and requires bit-exact responses.

## Note for the record

The previous ZS01 bitstreams (09-14 onward) authenticated cassettes on the
bench despite this. Slack is −0.39 ns at the slow 100 °C corner and −1.71 ns at
slow −40 °C; a DE10 at room temperature sits between, and the paths are only
exercised during the cassette handshake. That is luck, not margin, and it is
the kind of luck the project's own build script exists to refuse.
