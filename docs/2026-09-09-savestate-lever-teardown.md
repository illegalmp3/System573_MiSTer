# Lever #5 (savestate stub) — teardown, and why the audit's recipe would break boot

**Date:** 2026-09-09 · **Scope:** read-only analysis of the vendored `psx/` tree at the pin.
No RTL written. **Conclusion: do NOT build the audit's `0028` savestate stub as specified.**

---

## 0. What was verified (a real number, for once)

The vendored tree was reconstructed exactly as the project builds it:

```
git clone https://github.com/MiSTer-devel/PSX_MiSTer.git
git fetch --depth 1 origin 67153439fbb8e85e4108b9f0ff474d37aa6f7f5b   # PIN from tools/apply_psx_patches.sh
git checkout FETCH_HEAD && git submodule update --init --depth 1
```
then the 26 active patches applied in `apply_psx_patches.sh` order (0009 is commented out):

**26 / 26 applied cleanly. 0 failures.** So `psx_patches/` is still coherent against the pin, and
everything below is read off the actual post-patch source, not from memory of it.

---

## 1. The finding

`docs/audits/2026-06-12-resource-recovery-scope.md` lever #5 says:

> stub `isavestates`/`istatemanager` FSM+DDR3 only, drive `load_done`/`ss_reset`/
> `loading_savestate`/`savestate_busy` benign, `SS_wren`/`SS_rden`=0 …
> **KEEP the per-module `ss_in` array** — it is LOAD-BEARING for reset.

The instinct was right and the mechanism was wrong. `ss_in` is not a constant array — it is a
**register file, and `savestates.vhd` is the only thing that ever initialises it.** Driving
`ss_reset` "benign" is precisely the change that breaks boot.

### The chain, with citations (post-patch paths)

Every module follows one pattern. `rtl/irq.vhd:147-154`:

```vhdl
if (SS_reset = '1') then
   for i in ... loop  ss_in(i) <= (others => '0');  end loop;
   -- ...module-specific NON-ZERO defaults assigned here...
elsif (SS_wren = '1') then
   ss_in(to_integer(SS_Adr)) <= SS_DataWrite;
end if;
```

and on the ordinary reset (`rtl/irq.vhd:89-92`) the working registers are copied **from** it:

```vhdl
if (reset = '1') then
   I_STATUS <= unsigned(ss_in(0)(10 downto 0));
   I_MASK   <= unsigned(ss_in(1)(31 downto 0));
```

For `irq` the defaults are zero, so nothing is lost. **They are not zero everywhere.**
`rtl/cpu.vhd`, in its `SS_reset` branch:

```vhdl
ss_in(0)  <= x"BFC00000";  -- PC
ss_in(13) <= x"00000002";  -- cop0_PRID
```

and `rtl/gpu.vhd`:

```vhdl
ss_timing_in(0) <= x"0003FC10";  -- vDisplayRange
ss_timing_in(1) <= x"00C60260";  -- hDisplayRange
```

`SS_reset` is generated **inside `savestates.vhd`** (`:19`, `:214`, asserted from the FSM at
`:314`, `:329`, `:348`, `:581`). Tie it low and `ss_in` never leaves its VHDL initial value of
all-zeros — so at reset the **R3000 latches PC = 0x00000000 instead of 0xBFC00000** and the core
never fetches the BIOS. The GPU comes up with zero display ranges as a bonus.

That is almost certainly the real identity of the audit's remembered "change class that broke
boot before."

### `savestates.vhd` is the reset sequencer, not a bolt-on feature

Reading the FSM (`rtl/savestates.vhd:299-620`), a plain reset — `reset_in` falling edge, IDLE at
`:307` — does all of this:

1. sets `savetype_counter <= 12` and `resetMode <= '1'` (`:313-317`);
2. runs the pause/idle handshake (`WAITPAUSE` → `WAITIDLE`), waiting on `system_paused` and
   `SS_idle` before touching anything;
3. pulses `SS_reset`, loading every module's defaults into `ss_in`;
4. enters the **LOAD path in `resetMode`** and walks savetypes **12…16 only** — Scratchpad,
   CDROM, SPU RAM, VRAM, main RAM — writing zeros (`ddr3_RD <= not resetMode`, `:592`;
   `ddr3_DOUT_saved <= (others => '0')`, `:612`). Savetypes 0–11 (CPU, GPU, DMA, GTE, Joypad,
   MDEC, Memory, Timer, Sound, IRQ, SIO) are **skipped**, which is exactly why their `SS_reset`
   defaults survive to be copied into the registers;
5. reads DDR3 four times in `LOAD_RESETSSCHECK` (`:552-566`) purely to compute `validSStates`;
6. finally asserts `reset_out` → `reset_intern` (`:213`), the core's actual internal reset.

So "stub the FSM and the DDR3 traffic" is not a stub of a feature. It is a rewrite of the reset
controller plus the power-on memory clear. Steps 1–4 and 6 are all load-bearing; only step 5 is
savestate-specific. **Lever #5 as written is mis-scoped, and it should not be attempted for
~300–647 ALM.**

---

## 2. This changes the prediction for the emu.sv patch I sent earlier

In the previous note I predicted "near zero ALM change" from the savestate gate-off. **I now
think that was too pessimistic, and the fit report is worth reading closely.**

With `SS_ENABLE = 1'b0`, `ss_save`/`ss_load` are provably constant 0 at the `emu.sv` boundary
(`DBG_AUTOSS` is also a constant 0, so `ss_save_eff` folds too). Those feed `save_state` /
`load_state` into `psx_top` → `istatemanager` → `savestate_savestate` / `savestate_loadstate` →
the `save` / `load` inputs of the savestates FSM at `IDLE` (`:319`, `:325`).

Quartus flattens across the hierarchy, so with both constants tied off it should be able to prove
the `SAVE_*` states and the **non-reset** `LOAD_*` branches unreachable — the DDR3 write path, the
header/`SAVESIZEAMOUNT` logic, the SPU-RAM and VRAM save readers, and most of `statemanager` —
while leaving the `resetMode` path (entered from `reset_in`, not from `save`/`load`) fully intact.

**That is the safe version of lever #5, and it may already be in hand for free.** It is also the
right shape: let synthesis prune what it can prove dead, rather than hand-editing a reset
controller. The number to pull from the next fit report is the placed-ALM delta on
`isavestates` + `istatemanager` in the Fitter Resource Utilization by Entity table. Baseline from
the 2026-06-12 audit: **savestates ~647 ALM**, statemanager not separately broken out.

If the delta is large, lever #5 is done and cost nothing. If it is near zero, the reason is worth
knowing before anyone hand-writes a patch — most likely a residual non-constant input keeping the
FSM live.

---

## 3. Corrected lever ranking

DSP is at **104/112** after lever #1 and is no longer the binding constraint; **LAB occupancy at
99% is**, so ALM is what counts.

| Lever | ALM | Verdict now |
|---|---:|---|
| **#5 via constant-folding** (the emu.sv gate already sent) | up to ~647 | **Best. Free, zero new RTL, measured by one fit report.** |
| #5 as a hand-written `0028` stub | ~300–647 | **Rejected** — rewrites the reset sequencer, see §1 |
| #2 ascal bicubic off | ~300 (+DSP we no longer need) | Open, low risk, but the pruning is speculative — verify `bic_*` actually disappears |
| #6 mdec removal | ~714 + 9 DSP | Still gated on disassembling target titles for `0x1F801820/24` access |
| #7 gte removal | ~4,663 + 15 DSP | Still HIGH risk; needs per-game proof of zero COP2 |

**Recommended next action:** build the branch with the `emu.sv` savestate gate and read the
entity table. That single build tests the patch *and* settles lever #5 with no further RTL risk.
If it frees enough LABs, the DDR Solo Select L/R inputs — already written in `rtl/s573_io.v:143-155`,
matching MAME's `ddrsolo` map (`0x00000200` / `0x02000000`) — are the thing to spend it on.

---

## 4. Standing caveat

Nothing here was compiled, simulated, or fitted. The container's apt mirror and PyPI are refused
by egress policy, so there is still no `iverilog` on this side; GitHub *is* reachable, which is
the only reason the source above could be read at all. Every claim in §1 is a source citation you
can check in seconds; every claim in §2 is a prediction awaiting a fit report.
