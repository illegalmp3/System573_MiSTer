# How this working copy was set up (2026-09-09)

New project folder: `~/Documents/System573_MiSTer`. Separate from the older
`~/Documents/PSX_MiSTer` fork, which is a different line of 573 work and is not
touched by anything here.

## Provenance

* Working tree = the unmodified contents of the `System573_MiSTer-main.zip`
  download. Committed first, on its own, as `Import System573_MiSTer at its
  downloaded state`, so every later change is reviewable as a diff against it.
* `psx/` = the PlayStation core at the pin recorded in
  `tools/apply_psx_patches.sh` (`67153439fbb8e85e4108b9f0ff474d37aa6f7f5b`,
  2026-04-12). Cloned **offline** from the existing `~/Documents/PSX_MiSTer`
  clone, which already contained that commit — the sandbox that did this setup
  has no network, so it could not clone from GitHub.
* `psx/sys/` = the framework at the version that pin records. An earlier note
  here claimed this differed from what `~/Documents/PSX_MiSTer` carries; that was
  wrong, and the round-trip below is what disproved it. The two are the same
  file; the apparent mismatch was a patched copy being compared against a
  pristine one.

## Verified

`tools/apply_psx_patches.sh` — the repo's own tool — was run for real, not just
`--check`:

* **26 / 26 apply cleanly** (0009 is disabled in the script);
* `--revert` returns `psx/` to **byte-identical to the pin** (`git -C psx status`
  clean), so the stack is genuinely reversible and the vendored-pristine rule
  holds;
* re-applying gets all 26 back.

`psx/` is currently left **patched**, which is the state a build needs. The outer
repo therefore shows ` m psx` in `git status`; that is expected.

The 573 unit-test suite passes: **47 / 47 testbenches, `ALL TESTS PASSED`**, run
on macOS with Homebrew `iverilog` (2026-09-09), with the savestate change in the
tree.

## NOT verified

* **No simulation has been run.** `sim/Makefile` needs `iverilog`, which is on
  the macOS side via Homebrew. The sandbox that assembled this folder is a
  separate Linux VM with no Homebrew, no network and no root, so it cannot run
  the suite. Run it from Terminal:
  `cd ~/Documents/System573_MiSTer/sim && make`
* No Quartus fit, no hardware test.

## Housekeeping

`_incoming/` holds the original zip, the patch and the tarball used to build
this folder. It is git-ignored (via `.git/info/exclude`) and safe to delete.

Git identity is set repo-locally to Ricky / the iCloud address. `CLAUDE.md` in
this project says to commit as the Fabricore identity and push to
`fabricore-eng` — that is the upstream project's convention, so change
`git config user.name/user.email` before pushing anywhere public.
