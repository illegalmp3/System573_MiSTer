# hypbbc2p: CD install runs and the installed game boots

**Verified 2026-09-11, DE10 + CRT, CRT-only bitstream** (`MISTER_DEBUG_NOHDMI`,
34,695 ALM / 89 DSP / +1.196 ns). Third upstream claim reproduced on this bench.

## What ran

Launched `hypbbc2p_console.mgl` from the Console menu (bare-filename paths, fixed
earlier today). Boot Device set to **CD-ROM** in the OSD. The BIOS ran the CD
installer, copied the disc into the onboard flash, and the game now runs from
flash with sound.

This is the first time this bench has exercised:

* **ATAPI / the CD-ROM path** — previously sim-only here;
* **the CD installer programming onboard flash** — 16 MB, from a blank 0xFF image;
* **a real security cassette** — `gx908ja.u1` (X76F100, crc `8900eaff`) clearing
  the BIOS boot-signature check, i.e. the `-11N` wall that a synthesized cassette
  cannot pass;
* **the in-game ROM check** against the freshly programmed flash;
* **flash boot after install.**

## The actual procedure (better than what the docs said)

The launcher's comment and the readiness doc both describe step 4 as "set Boot
Device → Flash ROM and reload". The game is more helpful than that: when the
install finishes it puts up an on-screen prompt saying the ROM flash is complete
and to **press Test to continue**. So:

1. Launch `hypbbc2p_console.mgl`
2. OSD → **573 Boot Device → CD-ROM**
3. Let the installer run to completion — it ends at the "flash complete, press
   Test" prompt
4. **At that prompt**, open the OSD, switch **573 Boot Device → Flash ROM**, exit
   the OSD, then **press Test**

The game then verifies the flash and loads. No reload or reboot needed — the
DIP-switch change is picked up live, which mirrors the real cabinet.

## The no-op flash erase was sufficient here

`docs/2026-06-07-testC-hypbbc2p-readiness.md` flagged an open risk: the flash
ERASE path is a no-op, provably fine for a single-pass program-into-blank but
suspect if an installer erases-then-verifies-0xFF a sector it has already
programmed. The stated probe was to run Test C and watch for the install
advancing and *then* stalling mid-progress.

**It did not stall.** The install ran to its own completion prompt and the in-game
ROM check passed against the result. So for this title the no-op erase is
sufficient, and there is no evidence here for spending ALM budget on a real
streamed-0xFF erase. That remains untested for titles that install differently
(gtrfrk2m's "check and erase 32mb" hack was the original circumstantial worry).

## Open: does the install persist?

The launcher mounts `saves/System573/hypbbc2p.sav` as a flash-save slot (slot 4),
relying on Main to auto-create it on first write-back — recorded as gate-0 "RISK
R4" and never verified. **Unknown whether that happened.**

The cheap test: reboot the MiSTer and launch the same `.mgl` with Boot Device
still on **Flash ROM**. If the game boots straight up, the 16 MB flash image was
saved and restored and R4 is resolved. If it wants installing again, the save-back
did not happen and the `.mgl` `type="s"` auto-create fallback in the readiness doc
is the thing to implement.
