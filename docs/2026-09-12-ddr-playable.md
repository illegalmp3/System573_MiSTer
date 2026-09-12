# DDR Solo Bass Mix is playable — a full credit, three songs, on Ricky's MiSTer

**Date:** 2026-09-12 · **Firmware:** `976f5548` (played), `8bf5dcd1` (deployed after, with
the two follow-ups below) · **Bitstream:** the 2026-09-10 CRT build, unchanged

## The result

Booted via `ddrsbm_console.mgl`, attract with sound, song select, three songs played back to
back with arrows on screen and music through the speakers. Player's assessment: sync is
"99.9% there," arrows "just barely early." Before today this title booted silent and could
not start a stage.

Across the whole credit the fabric reported **`underrun=5`** — all five from the boot moment
before any song was armed. Zero starvation during playback.

## How it got here: five bugs, one boot each

The service was written yesterday from the RTL contract without a board. Today it met one.
Every bug below was found by the log rather than by reasoning, and each fix was measured on
the next boot. In order:

| # | symptom | what the log showed | fix |
|---|---|---|---|
| 1 | no log at all | three causes indistinguishable: gate miss, `open`, `mmap` — all logged into `/dev/null` because the log opened *after* them | open the log first; log the gate with the names it compared; `strerror` on init |
| 2 | silent, attract | `start=end=0`, `flags=000a` — the game never armed a window because the update had wiped `config/` and the Solo cabinet strap with it | restore OSD options (not a firmware bug) |
| 3 | 0.5 s of music, then READY, then CLEARED with 0 steps | `free=44`: the ring runs 1.486 s full, and credit was paid at *decode* time | credit frames and bytes as the fabric **drains** them (a playback queue) |
| 4 | identical to 3 | `cur` ran through a 1,517,482-byte window in ~2 s while 16 KB played: every failed decode pulled more | a pull bound — never more than 48 KB ahead of played audio |
| 5 | identical again | `lead=49152 stalls=7559`, deadlocked; raw bytes at the stall were `e7c6 e7c5 e7c4…` — the POST memory-test fill, **not the song**, proven against the disc | **rewind**: a pull that finds no frame in fresh bytes is undone exactly and retried next poll |

Bug 5 is the one that mattered. The game loads each song into DIO RAM *while it plays*.
Real DIO silicon fetches on demand and cannot outrun the loader; the service could, and did,
within 50 ms — then consumed the unloaded region as "no sync, skip," so the real bytes landed
behind a position nothing would ever re-read. The pull bound from bug 4 was correct and
insufficient: it held, forever, because credit only advances when decoded audio plays and
nothing further could decode. The rewind is exact because the descrambler is deterministic
and resumable — the property the decision-B spike proved — and the host test T18 models the
loader and checks the rewound stream is byte-identical to a one-shot descramble.

On the playable run `rewinds=53`, arriving in bursts of ~18 at each song start and then
stopping: the decoder outruns the loader for ~90 ms, backs off, and never rewinds again for
the rest of the song. `stalls=0` — the hard bound never had to engage.

## What is now proven on hardware

- The core-name gate matches `System573` and correctly misses MENU, SNES, N64, **PSX**,
  CD-i and NES — the PSX miss being the trap the original project lost a session to.
- `mmap` of `0x32000000` + 32 MiB succeeds. Link 2, marked *unknown — the blocker* on the
  status page since the design was written.
- **The byte-oracle: 65,536 of 65,536 bytes** of the dumped window identical to
  `D_03.DAT` at offset `0x40`. Visibility, the address contract and word alignment, in one
  measurement, with no keys. The key the game programmed (`0x6010`) matches the one
  recovered offline from that file.
- **Ring placement (must-fix #2, open since the design): clear.** The region's checksum
  never moved across dozens of probes while nothing was written.
- The SPI mailbox round-trips both ways; two core resets handled and acked.
- The fabric's ring reader, elastic buffer, 44100 drain and mixer deliver audio.

## Two follow-ups, fixed and deployed but not yet heard

**Song-select preview delay.** `flush DEFERRED (drain was on at the re-arm)` fired exactly
once — the scroll re-arms the next preview while the previous one still drains, and the
inherited rule deferred the flush in that case, so the old preview's 1.5 s tail played out
first. Upstream had measured that this case never occurs; it does, on that screen. The
deferral dodged a real race with the live reader (advancing ~110 beats per poll, so parking
one beat past a snapshot of it can land *behind* it and read as a full ring of replay). Now:
park **1024 zeroed beats** ahead instead — up to 46 ms of silence, no old tail.

**Arrows slightly early.** Credit was paid when the reader *fetched* a beat, but the beat then
sits in the fabric's 512-sample elastic buffer (~11.6 ms) before the DAC. Credit is now
lagged by that depth.

## Still open

- **Flash persistence.** The core reports "Flash Saved" (auto-saved on OSD open after the
  install), the slot bookmark `config/System573.s4` points at
  `../usb0/games/System573/ddrsbm.sav` (it said `usb1` on an earlier boot — enumeration
  moves), and no such file is ever created. Every cold boot re-runs the CD installer. Main's
  save-slot code is the next thing to read; the sources are here.
- ~1.5 s from "play" to first audio is inherent to the ring depth; `BEATS_LOG2=13` (0.37 s)
  is the RTL-side remedy if it matters.
- The early-stop case (a *failed* stage) is still unobserved.

## The eight nulls

Eight times across two days an empty reading nearly became a finding: Main's `stdout` to
`/dev/null`; a log marker that never landed; a MAME tap that never fired; the ABI comparison
of two empty strings; the service log opened after the things that fail; an unmounted card
read as "no log — the service never ran"; an `ls` on an empty mount point reporting
"reachable"; and "no `.sav` on the T7," published to the user, from a drive that was not
mounted. The instrument has to be verified before the null is believed — and the one that
made it into a message to the user was the one where the null agreed with what I expected.
