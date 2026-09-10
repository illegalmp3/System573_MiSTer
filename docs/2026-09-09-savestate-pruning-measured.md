# Lever #5 measured: partial. `savestates` still costs 843 ALM.

**Source:** `output_files/Konami_System_573.map.rpt` from the first Windows build
(2026-09-09). The Fitter crashed in the router, but Analysis & Synthesis
completed, so the synthesis numbers are real.

## The answer

I predicted that with `SS_ENABLE = 1'b0` Quartus would prove the save/load paths
unreachable and prune most of `savestates`, and called that "the best remaining
lever … free". **That was too optimistic.** Measured:

```
savestates:isavestates    843 (843) ALM    712 (712) registers
```

The module is still there. Lever #5 did **not** land for free.

## What the gate DID do

Constant propagation reached exactly as far as the analysis said it would. From
the removed-registers section:

| Signal | Fate |
|---|---|
| `savestate_ui\|ss_save` | Stuck at GND due to stuck port data_in |
| `statemanager\|request_savestate` / `request_loadstate` | Stuck at GND |
| `statemanager\|save_buffer` / `load_buffer` | Stuck at GND |
| `statemanager\|save_1` / `load_1` / `savestatepos` / `savestatecount` | Lost fanout |
| `savestates\|savemode` | Stuck at GND |
| `savestates\|state.SAVE_WAITSETTLE` | Stuck at GND |
| `savestates\|ssValid[0..3]` | Lost fanout |

So the *request* path is genuinely dead and most of `statemanager` went with it.
What survives is what the teardown predicted survives: **the reset machinery**.
`savestates.vhd` is the reset sequencer — the pause/idle handshake, the
`SS_reset` pulse that loads every module's defaults (including the CPU's
`x"BFC00000"` reset PC), and the `resetMode` walk of savetypes 12–16 that zeroes
scratchpad, CD-ROM, SPU RAM, VRAM and main RAM. None of that is reachable-dead,
so none of it prunes.

## The narrower lever this exposes

The report names the expensive survivors, and some are **save-path only**:

```
32:1  16 bits  336 LEs   savestates|SS_DataRead[15]
32:1  14 bits  294 LEs   savestates|SS_DataRead[26]
32:1   2 bits   42 LEs   savestates|SS_DataRead[31]
 9:1  32 bits  192 LEs   savestates|ddr3_DIN[24]
 9:1  32 bits  192 LEs   savestates|ddr3_DIN[60]
```

`SS_DataRead` is the return mux that gathers each module's state **when saving**.
In `resetMode` nothing is read back — the reset path only ever *writes* zeros. So
that mux is live only because `savestates.vhd` drives it unconditionally in the
clk1x process (`case savetype_counter is when 0 => SS_DataRead <= SS_DataRead_CPU;`
…), not because reset needs it.

Forcing it to zero when savestates are disabled would be a **much** narrower
change than the audit's lever #5: it touches neither `SS_reset`, nor `reset_out`,
nor the `resetMode` zeroing walk — the three things that must not move. Worth a
numbered `psx_patches/0028-*` **after** a fit completes, not before; ~670 LEs of
muxing is real but it is not worth risking the only path to a bitstream.

## Also confirmed

The conf string in the map report shows the five savestate OSD entries **gone**
and the rest of the menu intact and well-formed — so the `CONF_STR` edit parses.
`SS3E000000:400000` is still declared, as intended.

Synthesis totals for the record: **38,855 ALM needed (est.)**, 44,511 registers,
114 DSP (device has 112; the fitter packs multipliers down, as it did 124 → 112
on the upstream build).
