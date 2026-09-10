# hyperbbc boots and runs attract with sound

**Date:** 2026-09-10 · **Board:** DE10-Nano · **Bitstream:** the 2026-09-09 build
(94% ALM, timing met by 6 ps, `SS_ENABLE=0`).

Second upstream claim reproduced on this bench. *Hyper Bishi Bashi Champ* boots
from the onboard-flash image and plays its attract loop with audio.

## What it took

The `.mgl` launcher did **not** work: `mgl/hyperbbc_console.mgl` produced the
**consumer Sony PlayStation logo and startup sound** instead of the Konami BIOS —
i.e. its `index="0"` entry never took effect and a Sony `boot.rom` autoloaded in
its place. That is the failure mode the launcher's own comment warns about ("on
some Main versions … silent ENOENT … ZERO files load", recorded there as the
"2026-06-07 black+audio loop … the consumer Sony boot.rom autoload"). Unresolved;
see below.

Loading by hand from the OSD works, and this is the sequence that booted it:

1. load the core, reset
2. **Load 573 BIOS** → `573bios.bin` (`700a01.22g`, crc `11812ef8`)
3. **Load 573 NVRAM** → `hbbnvram.bin` (`876ea.22h`, crc `8e11d196`)
4. **Load 573 Flash** → `hbbflash.bin` (16 MB, built by `tools/pack_hyperbbc.py`)

Flash **last** is deliberate: every one of those downloads holds the CPU in reset
while it runs (`reset_or` includes `bios_download`/`nvram_download`/`flash_download`),
so the last one loaded is the one whose reset-release boots the machine — and that
wants to happen with the flash image already in place.

## What this establishes

* The **flash image is correct** — interleave, m/l/j/h bank order and the
  `PS-X EXE` signature at `0x24` all confirmed by the machine booting off it, not
  just by the pre-flight checks.
* The **flash window reads back correctly on hardware**, so the SDRAM wrap bug
  recorded at `emu.sv:FLASH_START` is not present in this build.
* `CDR BAD` is gone, as predicted: with a valid signature the BIOS boots from
  flash and never reaches the CD check.
* The **SPU audio path works** (attract has sound). Nothing earlier this session
  had tested audio.
* The **savestate-gated bitstream boots and runs a game** — the change is not
  merely non-fatal at POST.
* And the build chain assembled this week is end-to-end sound: a hand-written
  `.qpf`, `tools/build-573.ps1`, serial routing, `SEED 3`, 6 ps of slack.

## Still open

* **The `.mgl` launchers.** All four are suspect, not just hyperbbc's, since they
  share the mechanism. Needs the SD-card listing to find which `boot.rom`
  autoloads and from where. The OSD sequence above is the reliable path meanwhile.
* **The input half of the savestate change** — whether `joy_unmod[16]` still
  blanks all twenty joy bits. Testable now that a game runs: map a pad button to
  *Savestates* (J1 position 13, unmapped by default) and hold it while pressing
  Coin/Start.

---

## Input half of the savestate change: verified (2026-09-10)

With hyperbbc running, a pad button was mapped to *Savestates* (J1 position 13)
via Define Buttons, then **held down while tapping Coin and Start**. Both
continued to register.

That is the behaviour the fix intends. Before it, `emu.sv` read:

```verilog
assign joy = joy_unmod[16] ? 20'b0 : joy_unmod;
```

— all twenty joy bits zeroed while that button is held, unconditionally, so the
d-pad could select a savestate slot. With savestates gated off that was a pure
trap: hold a mapped button mid-song and every JAMMA input dies, silently, with
nothing in any log to explain it. It now reads:

```verilog
assign joy = (SS_ENABLE & joy_unmod[16]) ? 20'b0 : joy_unmod;
```

**Honest standard of evidence.** This is a *negative* observation — the
pathological behaviour is absent — not a red/green A/B. The bug was never
observed on this hardware; it was found by reading the RTL and fixed before any
bitstream shipped with savestates disabled. The pre-fix behaviour is not in doubt
(the expression above is unconditional and has no other gate), but no build in
this project ever demonstrated it on silicon, and this test could not have.

## The savestate change is now complete

All four things that were unverified when the patch was written are closed:

| | |
|---|---|
| Synthesises | yes — 26/26 patches, A&S clean |
| Closes timing | yes — met on all corners, +0.006 ns worst |
| OSD parses correctly | yes — five entries gone, neighbours before and after intact |
| Boots and runs a game | yes — hyperbbc attract with sound |
| Input blanking no longer fires | yes — Coin and Start survive the held modifier |
