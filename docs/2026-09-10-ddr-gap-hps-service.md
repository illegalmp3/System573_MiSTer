# The DDR path has a hole this repo cannot fill: the HPS-side MP3 service

**Finding, 2026-09-10.** The download's status table lists

> MP3 decode (HPS-side service) — Main fork `support/s573/` — ✅ **plays on real hardware**

**That code is not in this repository.** There is no `support/` directory. Every
reference to it in `docs/` points at "the Main fork" — a fork of
`MiSTer-devel/Main_MiSTer` that was never published alongside this tree:

* `support/s573/s573mp3.cpp` — the service (docs 2026-07-03-p4b, 2026-08-02-*)
* `support/s573/s573mp3_core.c` — ring/epoch bookkeeping
* `support/s573/s573_descramble.c` — the descrambler's host-side half
* `lib/minimp3.h` — vendored decoder

## What that means for DDR

The fabric owns the descrambler, the streaming controller and the PCM ring, and
those *are* here and unit-tested. What is missing is the ARM-side decoder that
fills the ring. So on this tree a DDR title can boot and run, and it will be
**silent** — nothing decodes MP3 into ring B.

Reaching upstream's ddrsbm result therefore means writing that service, not just
sourcing dumps. It is not a black box, though — the docs left behind are unusually
good, and include the two bugs that cost upstream the most:

* `docs/2026-07-03-p4b-mp3-transport-design.md` — the full transport design,
  including the EXT_BUS pointer exchange and the step-by-step build order
* `docs/2026-08-02-mp3-stop-cfg-epoch-truncation.md` — `cfg_epoch` is compared as
  16 bits but `CMD_573_MP3CFG` word0 carries only `cfg_epoch[7:0]` by design, so
  past 255 they can never match and the config re-applies forever. One-line fix,
  and the write-up names it
* `docs/2026-08-02-mp3-stale-pcm-residue.md` — the ring write pointer masked to
  15 bits while the fabric compares all 16 including the wrap bit, plus the
  missing discard of already-decoded PCM on a new window

So it is reconstructable work with a known design and two landmines pre-cleared —
but it is a firmware project (fork Main, vendor minimp3, build ARM, deploy
`/media/fat/MiSTer`), not an afternoon.

## Consequence for planning

DDR is further out than the status table implies, and the gap is on the HPS side
rather than in the fabric. The cheaper next milestones do not depend on it:

1. **Fix the `.mgl` launchers** — all four are broken the same way; the OSD ritual
   works but is four steps and hides staging errors as apparent flash bugs.
2. **hypbbc2p, the CD-install path** — ATAPI, the installer writing flash, and a
   real security cassette. The repo already ships `games/System573/hypbbc2p.u1`,
   so only the disc image is missing. This is the last upstream claim that needs
   no firmware work.
3. **ddrsbm** — needs the disc, `ddrsbm.u1`/`.u6`, an *installed* NVRAM image, and
   the HPS service above. Music is the last piece, not the first.
