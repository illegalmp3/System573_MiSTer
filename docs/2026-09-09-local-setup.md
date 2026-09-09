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
* `psx/sys/` = the framework at the version that pin's submodule records
  (`audio_out.v` md5 `6273db37ff2abc3d18920ca30736e23f`). This is **not** what
  `~/Documents/PSX_MiSTer` carries at the same commit, so it was replaced
  deliberately. Consequence: `git -C psx status` reports ` M sys/audio_out.v`
  permanently. That is expected, not drift.

## Verified

`tools/apply_psx_patches.sh --check` — the repo's own coherence tool —
reports **26 / 26 patches apply cleanly** against `psx/` (0009 is disabled in
the script). That is the acceptance test for the vendored tree being correct.

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
