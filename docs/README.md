# docs/

* **STATUS.md** -- the live status page. Start here.
* **EMULATION.md** -- what each part of the board is in the core (hardware model,
  behavioural, on the HPS, absent), the sources, and what could replace the
  behavioural parts. Kept current.
* **MEMORY_MAP.md** -- the 573's registers, from psx-spx, with the core's
  differences. Kept current.
* **ARCHITECTURE.md** -- how the core is put together. Kept current.
* **2026-09-09 and later** -- dated notes from the current setup (Windows build PC,
  SD-card testing). Each is the record of one finding: symptom, evidence, fix,
  bench. Source comments cite them by file name, so they stay where they are. The
  newest source review is `2026-11-02-source-review.md`.
* **2026-06 .. 2026-08, audits/, handoffs/** -- the upstream author's (Fabricore's)
  notes from before this tree changed hands: a different build host (`dell`), an
  ssh-reachable MiSTer, SignalTap, a shared hub under `~/Dev/tools`. The findings
  stand and source comments cite them; the workflow they describe does not exist
  here, and where a later note or EMULATION.md disagrees, the later one is right.
  Notes whose conclusions were later overturned carry a dated note under their title
  saying by what (added in the 2026-11-10 documentation review).
* **Plans that have been carried out or overtaken** -- EXECUTION_PLAN.md,
  FLASH_LOAD_PLAN.md, PHASE1_PSX.md, PHASE4_HARDWARE.md, DEPENDENCIES.md,
  MISTER_DEV_NOTES.md, RUNBOOK-savestate-gate.md, ROADMAP.md's phase list. Read
  for background, not for instructions.
* **archive/** -- superseded pages kept for their content (the 2026-09-09 status
  ledger, the June 2026 PLATFORM.md constants table).
