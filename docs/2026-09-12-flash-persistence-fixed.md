# Flash persistence: the save file was never created, because nothing creates it

**Date:** 2026-09-12 · **Fix:** a file on the T7, no code, no rebuild

## Symptom

Every cold boot of *ddrsbm* re-ran the CD installer. "Flash saved" appeared on screen —
both from the OSD's *Save Flash* and from the auto-save after an install — and no
`ddrsbm.sav` ever appeared. `config/System573.s4` held a bookmark to
`../usb0/games/System573/ddrsbm.sav` (or `../usb1/…`; the T7's enumeration moves between
boots) and the path was always empty.

## Cause, from Main's source

`user_io_file_mount(name, index, pre, pre_size)` in `user_io.cpp`:

- file exists → mounted read-write;
- file missing and `pre != 0` → `"Will be created upon write"`, `type = 2`, and the
  first block-0 write does `FileOpenEx(..., O_CREAT | O_RDWR)`;
- file missing and `pre == 0` → **`"Eject image from %d slot"`**. Nothing is mounted. Every
  block the core sends afterwards is dropped.

The **only** caller that passes `pre=1` is `user_io_file_tx()` with `opensave` — the
console-ROM path that mounts `saves/<core>/<game>.sav` on **slot 0**. Our flash is slot 4,
mounted two ways — the `SC4` bookmark at core init and the `.mgl`'s
`<file type="s" index="4" path="ddrsbm.sav"/>` — and both go through `pre=0`.

So the slot was ejected, the core streamed 16 MB to nowhere, and the toast (which is the
*core's* "I finished sending") still fired. The RTL comment on the `SC4` line and three
launcher comments all asserted "auto-created (Main pre=1/type=2) on the first write-back."
That was never true of this path. All four are corrected.

## Fix

The file has to exist before launch. Rather than an empty file — which would restore blank
flash and cost one more installer run — the disc already contains the finished article:
`GQ894JAA.DAT` is the 16 MB image the installer copies into flash, and its md5 is
**`82243fe3121cb23e97fec37b9ed0b8ef` — identical** to the golden installed `ddrsbm.sav` this
project verified against MAME in July. It is now `games/System573/ddrsbm.sav` on the T7,
with a copy kept in `out/ddrsbm.sav.golden-installed`.

Expected on the next boot: no installer, straight to attract; the slot mounts read-write;
future saves land in this file.

The `.mgl` keeps its explicit slot-4 entry on purpose: the bookmark records whichever
`usbN` the drive was last time, and when that flips, the bookmark mount fails and the
`.mgl` item — resolved by bare name across storages — is what finds the file.
