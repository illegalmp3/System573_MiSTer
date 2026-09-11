# ddrsbm boots, and the Select L/R song-wheel inputs work on hardware

**Verified 2026-09-11, DE10 + CRT, CRT-only bitstream.** *Dance Dance Revolution
Solo Bass Mix* boots to attract via `ddrsbm_console.mgl`, with **573 Cabinet → DDR
Solo** and **573 MP3 Descramble → DDR Solo Bass Mix** set in the OSD. The
**Select L / Select R song-wheel buttons respond.**

Artifacts (all hash-verified against MAME before staging):
`gq894ja.u1` crc `10b85f6b`, `gq894ja.u6` crc `ce84419e`,
`894jaa02.chd` CHD v5, internal sha1 `d6872078a87ee00280a627675540676fb8b10f60`.
The launcher's `ddrsbm_nvram_installed.bin` entry was dropped — that post-install
M48T58 image ships in no romset and, per the launcher's own notes, loading a blank
in its place would be actively worse than loading nothing.

## First-time-on-this-bench hardware coverage

* **The BEMANI Digital I/O board** (`rtl/k573dio.v` + the descrambler and
  streaming controller) — previously sim-only here.
* **The DDR Solo cabinet strap** (`O[100]`). Solo cabs have no P2; the PCB senses
  cab type through a grounded P2-START line and Solo titles refuse to run in a
  "standard" cab with `=SYSTEM UNIT ERROR=`.
* **The `gq894ja` cassette path** for a DDR title.

## The Select L/R claim, settled

Upstream's status table lists the DDR Solo song-wheel inputs as
*"🏗️ written + simulated, not in a shipped bitstream (no timing headroom)"*, and
`docs/audits/2026-06-12-resource-recovery-scope.md` is built around freeing room
for them.

**They were never gated.** `rtl/emu.sv:2351-2352` conditions them only on
`solo_cab` — the runtime OSD `573 Cabinet` option — and `rtl/s573_io.v:150,156`
wires both into IN3 bit 9 unconditionally. Confirmed from the source on 2026-09-10
and now **confirmed on hardware**: they respond in a bitstream whose build predates
every byte of the resource-recovery work.

That work still stands on its own terms (DSP off a ceiling held in every recorded
build, +0.006 → +1.196 ns, 4,551 ALM freed), but the goal it was argued from had
already been met. Recorded because I argued it repeatedly before checking.

## Upstream claim status

| Claim | State |
|---|---|
| GX700 self-test reached | reproduced 2026-09-10 |
| hyperbbc boots and runs with audio | reproduced 2026-09-10 |
| hypbbc2p CD-install boots and runs | reproduced 2026-09-11 |
| ddrsbm boots, plays a stage, **streams MP3 audio** | **boots** 2026-09-11; the MP3 half needs firmware absent from this repo |
