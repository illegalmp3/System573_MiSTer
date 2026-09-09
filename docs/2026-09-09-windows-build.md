# Building this core on the Windows PC

Quartus Prime Lite has no macOS build, so the bitstream is built on the Windows
machine with **Quartus Prime Lite 17.0.2** — the same constraint and the same
version pin described in `psx-cloud-build/WINDOWS.md`. 17.0.2 is not negotiable:
`sys.qip` picks its PLL IP by parsing the Quartus version number, and only
`pll_q13.qip` and `pll_q17.qip` exist.

This repo's `CLAUDE.md` and `tools/dell_*.sh` describe the upstream project's own
build infrastructure — a shared Linux box called `dell`, a build semaphore, a
group chat. **None of that exists here.** Ignore those instructions; they are the
original authors' workflow, not this working copy's.

## What was missing, and is now here

* **`Konami_System_573.qpf`** — the download shipped the `.qsf` but no project
  file, so `quartus_sh --flow compile` had nothing to open. Created, revision
  `Konami_System_573`, Quartus 17.0.
* **`tools/build-573.ps1`** — adapted from `psx-cloud-build/build-psx.ps1`, same
  reason for existing: `quartus_sh --flow compile` exits 0 on a design that
  misses timing, and a MiSTer bitstream that misses timing loads and then
  misbehaves in ways that look exactly like RTL bugs.

It adds three checks the PSX version has no reason to make:

1. **Refuses to build an unpatched `psx/`.** The vendored core is meaningless
   until `psx_patches/` are applied, and nothing on Windows runs the bash
   applier. It detects this by looking for `IIR_filter` in
   `psx/sys/audio_out.v` — patch 0025 removes it.
2. **Reports LAB occupancy.** This design's failure mode is localized routing
   congestion at ~99% LABs, not global resource exhaustion, so LAB% is the
   number that predicts a failed fit. It warns at ≥98%.
3. **Prints the `savestates` / `statemanager` entity rows** from the fitter
   report — the open question from `2026-09-09-savestate-lever-teardown.md` is
   whether `SS_ENABLE=0` lets Quartus prune them.

## The flow

Patches must be applied on the Mac first — the applier is bash, and the tree is
copied over already patched.

```sh
# on the Mac
cd ~/Documents/System573_MiSTer
tools/apply_psx_patches.sh          # idempotent; safe to re-run
cd sim && make                      # 47/47 before shipping a tree anywhere
```

Copy the whole folder to the Windows PC (it is ~173 MB, most of it `psx/`), then:

```powershell
powershell -ExecutionPolicy Bypass -File tools\build-573.ps1 -Root C:\dev\System573_MiSTer
```

Pass `-Quartus <path to quartus\bin64>` if Quartus is not at
`C:\intelFPGA_lite\17.0\quartus\bin64`.

Expect 20–40 minutes. The script fails loudly on negative slack rather than
handing back a bitstream that will waste a debugging session.

## Not yet done

Neither the `.qpf` nor the script has been run through Quartus — there is no
Quartus on the Mac and none in the sandbox that wrote them. The first Windows
run is the test. The most likely failure is a path or revision-name detail in
the `.qpf`/`.qsf` pair, which shows up in seconds rather than after the fit.
