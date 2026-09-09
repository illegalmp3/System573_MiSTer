# Savestate gate-off + a recount of the resource-recovery levers

**Date:** 2026-09-09 · **Scope:** one `rtl/emu.sv` change (573-local, nothing vendored) plus a
correction to the 2026-06-12 recovery audit. **Not built, not simulated, not run on hardware —
see §4 before believing anything here.**

---

## 1. What was changed and why

The handoff's open item — *"`emu.sv:804` deliberately ENABLES [savestates] for flash-loaded
games, so the OSD advertises a feature that will freeze on restore. Either finish it or gate it
off"* — is now gated off.

**The claim, with a number.** Savestate hooks in 573 RTL:

```
grep -rn "SS_wren|SS_rden|SS_Adr|SS_DataWrite|savestate" rtl/*.v   ->  2 hits
```

Both hits are *comments* in `rtl/s573_ddram_arb.v:7-8` describing the DDR address map. Zero
signals. `rtl/system573_top.v` has no savestate port at all. So the 573 half of the machine is
not captured, and separately the MP3 config epoch, descrambler position and PCM ring pointers
live in the HPS-side `s573mp3` service — outside any FPGA-side capture by construction.

**Four edits** (`s573-disable-savestates.patch`):

1. **`localparam SS_ENABLE = 1'b0`** declared just above `CONF_STR`, with the reasoning inline.
2. **`.allow_ss (cart_loaded & SS_ENABLE)`** on the `savestate_ui` instance. This is the actual
   gate: it kills the OSD save/load, the Alt-F1/F1 PS2 path, and the joypad slot UI in one place.
3. **The five savestate OSD entries commented out.** They are absolute status bits
   (`O[36]`, `O[68]`, `O[38:37]`, `RH`, `RI`) — not positional — so removing them shifts nothing
   else in the conf string. Left in place as comments so re-enabling is a verbatim un-comment.
4. **`assign joy = (SS_ENABLE & joy_unmod[16]) ? 20'b0 : joy_unmod;`** — this one was not in the
   handoff and is the reason the change is worth more than tidiness.

### The joy-blanking bug (edit 4)

`joy_unmod[16]` is the **"Savestates" modifier** — J1 position 13, a button a user can and will
map. Upstream blanks **all twenty joy bits** while it is held, so the d-pad can select a slot.
That behaviour was unconditional. With savestates dead, holding a mapped button silently drops
**every JAMMA input** — on a dance title, mid-song, with no OSD feedback and nothing in a log to
explain it. Tying the blanking to `SS_ENABLE` removes the trap.

I did **not** touch the `J1` name list: `emu.sv:535-541` says rename-only, never insert or
reorder, because MiSTer stores the input map as a positional array. Position 13 keeps the name
"Savestates" and is now simply an unmapped button. Renaming it is legal per that comment but is
a separate, cosmetic call.

**Deliberately left alone:** the core line still declares the savestate DDR region
(`"PSX;SS3E000000:400000;"`). That is Main's allocation hint, every core-side consumer of it is
now gated, and changing it is a Main-facing behavioural change that wants a hardware A/B rather
than a guess from here.

---

## 2. The recovery audit is stale — a corrected lever menu

`docs/audits/2026-06-12-resource-recovery-scope.md` still reads as the plan of record, and its
"Recommended execution order" is **spent**. Levers 1, 3 and 4 landed as patches:

| Audit lever | Claimed | Status |
|---|---|---|
| #1 audio IIR → passthrough | ~436 ALM, **8 DSP** | **DONE** — `psx_patches/0025-s573-audio-iir-passthrough.patch` |
| #3 joypad_pad + lightgun strip | ~575 ALM | **DONE** — `0026-s573-strip-psx-joypad-pad-lightgun.patch` |
| #4 memcard2 + SNAC | ~80 ALM | **DONE** — `0027-s573-strip-memcard2-snac.patch` |
| #2 ascal bicubic off | ~300 ALM, 10–14 DSP *(speculative)* | **open** |
| #5 savestate partial stub | 300–647 ALM | **open — and see §3** |
| #6 mdec removal | ~714 ALM, 9 DSP | **open, gated on disasm proof** |
| #7 gte removal | ~4,663 ALM, 15 DSP | **open, HIGH risk** |

That matters because the design now sits at **97% ALM / 100% DSP / +0.069 ns**, which is *after*
those three levers — so roughly 1,100 ALM and 8 DSP of recovery has already been consumed by
what shipped since June. The audit's headline arithmetic ("#1+#3 free ~1,000 ALM, ≈6× the
persistence delta") has already been spent and should not be quoted as available headroom again.

---

## 3. This change makes lever #5 cheaper than the audit priced it

The audit rated the savestate stub **MED–HIGH** risk, and the risk it named was real but
specific: *"KEEP the per-module `ss_in` array — it is LOAD-BEARING for reset (`reg<=ss_in(...)`
on reset, e.g. `irq.vhd:91`). Deleting `ss_in` is the change class that broke boot before."*

Two things have changed:

- **The user-visible feature is now gone.** The audit's stated cost of lever #5 was "loses the
  savestate menu + the garble-capture workaround." The menu is already gone as of this patch, and
  the CLUT garble investigation it served is resolved (`psx_patches/0019-s573-clut-cache-restore`).
  So lever #5 now costs **nothing anyone can observe**.
- **The remaining risk is one well-understood invariant**, not an open-ended regression: stub the
  `isavestates`/`istatemanager` FSM and its DDR3 traffic, drive `load_done` / `ss_reset` /
  `loading_savestate` / `savestate_busy` benign and `SS_wren`/`SS_rden` low — and leave every
  `ss_in` constant array exactly where it is, because those are reset values, not savestate state.

That makes **#5 the best remaining lever**: ~300–647 ALM at what is now effectively a
zero-feature cost, versus #2 (speculative pruning that may free nothing) and #6/#7 (both blocked
on per-game disassembly proof that no target title touches MDEC or COP2). It is also pure ALM,
which is what the congestion hotspot actually needs — DSP is at 104/112 after lever #1, so DSP is
no longer the binding constraint; **LAB occupancy is**.

If the goal is landing the Solo Select L/R inputs, #5 is the lever to build next, as a numbered
`psx_patches/0028-*.patch` under the vendored-pristine rule.

---

## 4. What is NOT verified — read this before committing

**Nothing here was compiled, simulated, or run.** This container's apt mirror and PyPI are both
refused by egress policy (403), so `iverilog` could not be installed and neither could a
standalone Verilog parser. Per CLAUDE.md non-negotiable #2, treat every claim above as a
hypothesis with a stated argument, not a verdict.

The only mechanical check I could run is a delimiter-balance diff of `emu.sv` before and after:
braces/brackets identical, parens `1124 → 1125` (the one new ternary), `begin`/`end` both 154
unchanged. That is a typo check, not a syntax check.

**To promote any of this to a fact, on your machine:**

1. `git apply --check s573-disable-savestates.patch` then apply on a topic branch.
2. `make -C sim` → expect `ALL TESTS PASSED` (unchanged — no 573 module is touched, so this
   proves absence of collateral damage, not that the change works).
3. Build via the hub launcher only:
   `DELL_PROJECT=573 DELL_TARGET=Konami_System_573 DELL_REPO=System573_MiSTer ~/Dev/tools/tools/dell_build.sh <branch>`
4. **The number that matters** is in the fit report, and it is the one thing I most want to see:
   whether removing the joy-blanking mux and gating `allow_ss` lets the fitter prune any of the
   `savestate_ui` / slot-select logic. I would expect **near zero ALM change** — the gate is a
   constant, so Quartus should constant-fold the mux, but `savestate_ui` itself stays
   instantiated and its DDR path is inside vendored `psx/`. If the ALM count moves more than a
   few dozen either way, that is interesting and worth reading before trusting it.
5. De-confounded HW check (warm reboot, `/proc/uptime` < 60 s, exactly one `load_core`): confirm
   ddrsbm still boots to attract, and that the OSD no longer lists the savestate entries.

A regression here would most likely show up as a **conf-string parse failure** — if Main
mis-parses `CONF_STR`, the OSD comes up empty or wrong rather than the core failing to boot. That
is the first thing to look at if the OSD looks strange.
