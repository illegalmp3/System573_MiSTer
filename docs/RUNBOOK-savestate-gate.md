# Runbook — savestate gate: apply, sim, build, and the one number that matters

Three stages. **Stage 1 costs you a minute and is worth doing on its own.** Stage 2 is the
~40-minute build. Stage 3 only happens if Stage 2 looks right.

Paste back exactly the blocks marked **↩︎ PASTE BACK**. Everything else is for you.

---

## Stage 1 — apply + sim (Mac, ~1 min)

`s573-disable-savestates.patch` is the file from this conversation; adjust the path if you
saved it elsewhere.

```sh
cd ~/…/System573_MiSTer                      # your Mac working copy
git status --short                           # expect clean; stash first if not
git checkout main && git pull --ff-only
git checkout -b claude/s573-savestate-gate

git apply --check ~/Downloads/s573-disable-savestates.patch && \
git apply        ~/Downloads/s573-disable-savestates.patch && echo "PATCH OK"

make -C sim 2>&1 | tail -25
```

**↩︎ PASTE BACK:** the `PATCH OK` line (or the `git apply --check` error) and the last 25 lines
of `make`. Expected: `ALL TESTS PASSED`. No 573 module is touched, so this proves absence of
collateral damage — it does not exercise the change itself.

If `git apply --check` fails, your `emu.sv` has moved since the zip you sent me. Paste the error
and I'll rebase the patch.

### Then commit (Fabricore identity, private remote — CLAUDE.md §4)

```sh
git add rtl/emu.sv
git commit -m "573: gate savestates off (SS_ENABLE=0) + stop the SS modifier eating inputs"
git push origin claude/s573-savestate-gate
```

---

## Stage 2 — build, and read the entity table

```sh
DELL_PROJECT=573 DELL_TARGET=Konami_System_573 DELL_REPO=System573_MiSTer \
  ~/Dev/tools/tools/dell_build.sh claude/s573-savestate-gate

# watch it
DELL_PROJECT=573 ~/Dev/tools/tools/dell_build.sh --status
```

When it finishes, three pulls. **The second one is the whole experiment.**

```sh
# (a) device totals — did LAB occupancy come off the wall?
ssh dell "grep -E 'Logic utilization|ALMs needed|Total LABs|Total DSP|Total block memory bits|Total registers' \
  ~/System573_MiSTer/output_files/Konami_System_573.fit.rpt | head -20"

# (b) THE NUMBER: did the savestate logic get pruned?
ssh dell "awk '/Fitter Resource Utilization by Entity/,/^; *Total/' \
  ~/System573_MiSTer/output_files/Konami_System_573.fit.rpt \
  | grep -iE 'savestate|statemanager' "

# (c) timing — the design was at +0.069 ns, so confirm nothing regressed
~/Dev/tools/tools/dell_timing.sh   # or tools/dell_timing.sh from the repo
```

**↩︎ PASTE BACK:** all three outputs verbatim.

### How I'll read (b)

Baseline from the 2026-06-12 audit: `savestates` ≈ **647 placed ALM**; `statemanager` wasn't
broken out separately.

- **Large drop, or the entities vanish** → lever #5 landed for free. `SS_ENABLE=0` let Quartus
  prove the SAVE path and the non-reset LOAD branches unreachable. Nothing further to write, and
  that headroom goes to the Select L/R inputs.
- **Near zero change** → something still holds the FSM live. That is a real finding, not a
  failure: it means a hand-written `0028` would also have to survive whatever that input is, and
  I want to identify it before anyone touches vendored reset logic.
- **Anything moves in `psx_top`/`cpu`/`gpu`** → stop and tell me. The gate should not reach them,
  and if it does, my reading of the constant-propagation path is wrong.

Timing note: freeing LABs should *help* or be neutral. If clk_2x slack goes **more** negative,
that's placement noise on a 97%-occupied die, not causation — worth one reseed before concluding.

---

## Stage 3 — hardware, only if Stage 2 is clean

De-confounded, per CLAUDE.md §3. Do not skip the uptime check.

```sh
cd ~/Dev/fabricore/tools && ./tools/dell_coord.sh devlock de10 acquire 573

scp dell:'~/System573_MiSTer/output_files/Konami_System_573.rbf' /tmp/ && \
  scp /tmp/Konami_System_573.rbf de10:/media/fat/_Console/

ssh de10 'reboot'          # warm reboot, then wait
ssh de10 'cat /proc/uptime'   # must read < ~60 s before you load anything
# then EXACTLY ONE load_core, and boot ddrsbm as usual
```

Two things to check, both by eye — this is the one place where looking is legitimate, because
the claim is about what the OSD *lists*:

1. The OSD no longer shows *Savestates to SDCard*, *Autoincrement Slot*, *Savestate Slot*,
   *Save state (Alt-F1)*, *Restore state (F1)*. Everything else in the menu is unchanged and in
   the same order — **if other entries moved or vanished, the conf string mis-parsed**; that's
   the failure mode to watch for, and it's recoverable by reverting one commit.
2. ddrsbm still boots to attract and a credited stage still plays with music.

For (2), use a frame_diff number against a known-good capture rather than calling it by eye —
same standard as every other boot claim on this project.

```sh
cd ~/Dev/fabricore/tools && ./tools/dell_coord.sh devlock de10 release 573
```

**↩︎ PASTE BACK:** whether the five entries are gone, whether anything else in the OSD changed,
and the ddrsbm result.

---

## If you'd rather do less

Stage 1 alone is genuinely useful — it tells me the patch applies to your current tree and breaks
nothing in sim. Stop there and I'll wait. The build is only worth spending if you were going to
build soon anyway; the savestate gate is a correctness fix that can ride along with whatever
lands next rather than justifying a build of its own.
