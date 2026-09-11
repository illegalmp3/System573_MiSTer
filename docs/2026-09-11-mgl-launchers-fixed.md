# The `.mgl` launchers work — bare filenames were the answer

**Verified 2026-09-11, DE10 + CRT.** `hyperbbc_console.mgl` launched from the
Console menu boots hyperbbc to attract with sound. One click, replacing the
four-step OSD load sequence.

## The correct path forms

From MiSTer's own MGL documentation, which is short and which I should have read
two attempts earlier:

| Element | Rule |
|---|---|
| `<rbf>` | *"Relative path to the core's RBF file from the SD root, excluding its file extension"* — resolves under `/media/fat` **only**. A core on USB cannot be referenced by an MGL. |
| `<file path>` | *"Path to game file relative to the core's games folder"* — documented examples are bare (`dummy.chd`). With `<setname>System573` the games folder is `games/System573`, searched **across storages**, so a bare filename works on SD and USB alike. |

That last property is why this form is better than the absolute paths the
launchers shipped with: it is storage-agnostic by construction.

## Three attempts, and what each got wrong

1. **Upstream's absolute `/media/fat/games/System573/…`** — works only if games are
   on the SD card. With games on a USB drive the paths do not exist, *no* file
   entry loads, and the core autoloads `games/PSX/boot.rom` instead: the consumer
   Sony BIOS, giving the PlayStation logo and startup sound.
2. **My first fix, `games/System573/…`** — relative to the games folder that means
   `games/System573/games/System573/…`. Broken differently. Symptom: **"Hardware
   unmatched"**, which is evidently Main's message for unresolvable file entries.
3. **Bare filenames** — correct, and confirmed on hardware.

I also mis-diagnosed the "Hardware unmatched" error as the `<rbf>` path, on the
theory that the core lived only on the USB drive. It did not:
`/Volumes/MiSTer_Data/_Console/Konami_System_573.rbf` was already in place. The
rbf was never the problem.

**Lesson, bluntly:** two of the three attempts reasoned from the code and the
symptom when the answer was one page of vendor documentation. Check the spec
before inferring the mechanism.

## Belt-and-braces kept

`games/System573/boot.rom` is a copy of the standard Konami BIOS (crc `11812ef8`).
If Main ever resolves this core's HomeDir from `<setname>`, that autoload finds the
Konami BIOS rather than the Sony one in `games/PSX`. Harmless either way, since
every launcher also loads the BIOS explicitly at index 0.
