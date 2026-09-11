# System 573 core — status

**Updated 2026-09-09.** A browsable version of this is published as a Claude
artifact ("System 573 Core Status"); this file is the copy that travels with the
code and should be updated with it.

| | |
|---|---|
| Unit tests | **47 / 47 PASS** (macOS, Homebrew iverilog) |
| psx patch stack | **26 / 26** apply · revert · re-apply |
| Commits | 4 |
| Quartus runs | 2 — **bitstream produced** |
| Fit (CRT build) | 34,695/41,910 ALM (83%), LABs 4,041/4,191 (96.4%), DSP **89/112** |
| Timing | met, TNS 0, worst setup **+1.196 ns** (was +0.006 with HDMI) |
| Hardware runs | 7 — **ddrsbm boots with Select L/R working**; hypbbc2p installs from CD; hyperbbc on both bitstreams |

## Two trees, one board

Two separate 573 efforts exist on the Mac. Conflating them wastes a day.

* **`~/Documents/System573_MiSTer`** — *this project, active.* A downloaded core
  set up fresh on 9 Sep. Top level `rtl/emu.sv`; PlayStation core vendored as a
  submodule at pin `67153439` (2026-04-12) with a 26-patch stack.
* **`~/Documents/PSX_MiSTer`** — *earlier fork, parked and untouched.* 573 work
  done inside a PlayStation core fork on `s573-vram-widening`, blocks in
  `rtl/k573/`, removals as generics (`HAS_CDROM`, `HAS_PADS`). Reports 90% ALM
  with timing met.

## Evidence ledger

The project's first rule is that a claim needs a number. Applied to everything
currently believed about this core:

### Verified here (this machine, this week)

* 573 unit suite passes with the savestate change in the tree — **47/47**.
* The vendored patch stack applies to the pinned core — **26/26** (0009 disabled).
* `apply_psx_patches.sh --revert` returns `psx/` **byte-identical to the pin**
  (`git -C psx status` clean); re-applying restores all 26. The
  vendored-pristine rule genuinely holds.
* No 573 module has savestate hooks: 2 matches, both comments in the DDR address
  map; `system573_top` has no savestate port.
* The savestate OSD entries are absolute status bits (`O[36]`, `O[68]`,
  `O[38:37]`, `RH`, `RI`), so removing them shifts nothing else in `CONF_STR`.
* **Confirmed on hardware (2026-09-09, DE10).** The core loads from
  `_Console/Konami_System_573.rbf` and the OSD shows **no savestate entries at
  all**, while `Save Memory Cards` — a different feature on `RD`, two lines away
  in the conf string — is still present. That pairing is the signature we wanted:
  the five intended entries went and the string still parses. `Memcard Status:
  saved` is a *conditionally shown* (`HB-`) line, so the menumask-gated entries
  around the edit survived too. And **`System Type` — the entry immediately after
  the commented-out block — is present with all four options**, which is the
  tightest available check that the parser stepped over the edit cleanly rather
  than losing everything after it. Black screen beyond the OSD is expected with
  no BIOS staged.

### Claimed upstream (the download's README)

**Three of four reproduced.** *"hypbbc2p (first CD-install title) boots and runs"*
— confirmed 2026-09-11: the CD installer programmed onboard flash, the real
`gx908ja.u1` cassette cleared the `-11N` wall, and the installed game runs
(`docs/2026-09-11-hypbbc2p-cd-install-works.md`). Only the ddrsbm/MP3 claim is
left, and it needs firmware this repo does not contain.

**Earlier, 2026-09-10.** *"hyperbbc (flash-only) boots, runs, and has
audio"* — confirmed: it boots from our own packed 16 MB flash image and plays
attract with sound (`docs/2026-09-10-hyperbbc-boots.md`). The `.mgl` launcher did
not work (it autoloaded a consumer Sony BIOS); the OSD load sequence did.

**Also reproduced:** *"the BIOS boots past the color bars to the GX700
power-on self-test, parked at the CDR check"* — confirmed on our own bitstream:
`REG OK … 18E OK, CDR BAD`. `18E OK` is `rtl/s573_io.v` answering the H8 I/O-MCU
self-test, so that emulation is confirmed too. See
`docs/2026-09-10-gx700-post-reproduced.md`. The rest below remain unreproduced.

* *DDR Solo Bass Mix* boots from restored flash into attract, plays a credited
  stage and streams its encrypted MP3 soundtrack on hardware (2026-08-02).
* *hyperbbc* and *hypbbc2p* boot and run on a DE10 (2026-06-12).
* 97% ALM / 100% DSP / +0.069 ns.
* DDR Solo song-wheel inputs written and simulated, held out of a bitstream for
  lack of headroom (`rtl/s573_io.v:143`) — upstream cited +0.069 ns. **Our own fit
  is tighter still at +0.006 ns**, so this constraint is confirmed, not lifted.

### Not verified

* That this tree compiles at all. No Quartus on the Mac or in the sandbox.
* ~~The savestate change.~~ **Complete.** It fits, timing is met (by 6 ps), the
  OSD parses with only the intended entries removed, the bitstream boots and runs
  a game, and the joy blanking no longer fires. Caveat on the last one: it is a
  negative observation, not a red/green A/B — the bug was found by reading RTL and
  never demonstrated on silicon.
* ~~Whether `SS_ENABLE=0` lets Quartus prune the savestate logic.~~ **Measured
  2026-09-09: partial.** The request path is dead, but `savestates` still costs
  **603 placed ALMs** because the reset sequencer inside it survives —
  `reset_out` fans out to 3,480 loads, `ss_reset` to 1,727. See
  `docs/2026-09-09-savestate-pruning-measured.md`.
* That the new `.qpf` and `tools/build-573.ps1` work.

## Changed 2026-09-09

Savestates gated off (`SS_ENABLE`), the five OSD entries commented out, and —
not in the handoff that prompted it — the `joy_unmod[16]` blanking tied to the
same constant. That modifier is mappable (J1 position 13) and blanked all twenty
joy bits unconditionally so the d-pad could pick a slot; with savestates dead it
silently dropped every JAMMA input while a mapped button was held.

Full write-up: `docs/2026-09-09-savestate-gate-and-lever-recount.md`.

## The finding worth keeping

The audit's lever #5 (stub the savestate FSM for 300–647 ALM) **cannot be built
as written.** `ss_in` is not a constant array; it is a register file, and
`savestates.vhd` — the module the lever proposes stubbing — is the only thing
that initialises it, via the `SS_reset` it generates. The defaults are not all
zero (`cpu.vhd`: `ss_in(0) <= x"BFC00000"` — the reset PC). Driving `ss_reset`
benign leaves `ss_in` at zeros, so the R3000 resets to PC 0 and never fetches
the BIOS. `savestates.vhd` is also the reset sequencer: on a plain reset it
pulses `SS_reset`, walks savetypes 12–16 writing zeros (skipping 0–11, which is
why register defaults survive), then asserts the internal reset.

The safe version costs nothing: with `SS_ENABLE=0` the save/load inputs are
constant at the `psx_top` boundary, so Quartus should prune the save path and
the non-reset load branches while leaving the reset path intact.

Full write-up: `docs/2026-09-09-savestate-lever-teardown.md`.

## Resource levers, recounted

Three of the audit's recommended levers already shipped, so its headline
arithmetic is not available headroom. DSP is no longer binding; LAB occupancy is.

| Lever | Claimed | State |
|---|---|---|
| #1 audio IIR → passthrough | 436 ALM · 8 DSP | shipped (patch 0025) |
| #3 strip PSX pads + lightgun | 575 ALM | shipped (patch 0026) |
| #4 strip memcard2 + SNAC | 80 ALM | shipped (patch 0027) |
| #5 savestate stub as written | 300–647 ALM | **rejected** — breaks reset |
| #5 savestate via constant folding | up to 647 ALM | **measured: ~40 ALM.** Request path dead; 603 ALM of reset machinery remains. Closed. |
| #5b force `SS_DataRead` to zero | ~670 LEs of muxing | new, narrow, safe — after a fit completes |
| #2 ascal bicubic off | ~300 ALM | written as patch 0028; **inert** while the CRT build removes ascal entirely |
| **MISTER_DEBUG_NOHDMI** (CRT-only) | **measured −4,551 ALM, −23 DSP** | **done** — `build-573.ps1 -Crt`. Worst setup +0.006 → +1.196 ns |
| #6 remove MDEC | 714 ALM · 9 DSP | gated on per-game disasm |
| #7 remove GTE | 4,663 ALM · 15 DSP | gated on no-COP2 proof |

## Next, in order

1. **Run the Windows build** (`tools/build-573.ps1`). Settles whether the tree
   compiles and whether the new `.qpf` is right — a bad project file fails in
   seconds, not after the fit. See `docs/2026-09-09-windows-build.md`.
2. **Read the `savestates`/`statemanager` rows** in the fitter's entity table
   against a ~647 ALM baseline. Settles lever #5.
3. **Confirm nothing regressed on hardware** — de-confounded (warm reboot,
   uptime < 60 s, exactly one core load). Check the five OSD entries are gone
   and *nothing else in the menu moved*; a mis-parsed conf string shows as a
   wrong or empty OSD, not a boot failure.
4. **Reproduce one upstream claim** — cheapest is *hyperbbc* (flash-only, no CD
   or cassette path). Until one is reproduced here, the README's results are
   someone else's.

## Open risks

* **The HPS-side MP3 service blocks GAMEPLAY, not just audio.** Measured
  2026-09-11: ddrsbm boots and its SPU sound effects work, but the game will not
  start a stage without the MP3 stream — no decoder means the playback counter
  never advances and the step-chart sync never begins. So this is a hard
  prerequisite for a playable DDR, not a finishing touch.

* **The HPS-side MP3 service is missing from this repo.** The status table claims
  it "plays on real hardware", but the code lives in an unpublished `Main_MiSTer`
  fork — there is no `support/` directory here. A DDR title on this tree would
  boot and run **silent**. Reaching that result is a firmware project (fork Main,
  vendor minimp3, build ARM), though the design and two hard-won bug fixes are
  documented. See `docs/2026-09-10-ddr-gap-hps-service.md`.

* **The DDR targets are further off than the status table suggests.** *DDR
  Extreme* (`ddrextrm`) and *4th Mix Plus* (`ddr4mp`) need a 32 MB PCMCIA card,
  a memory-card reader on the JVS host, and ZS01 cassettes with per-game keying
  — none present. Both are `MACHINE_NOT_WORKING` in MAME, so there is no working
  reference to diff against.
* **Savestates are still declared to the host** (the `SS…` field in the core
  line). Deliberate: it is the host's allocation hint and every core-side
  consumer is gated. Changing it is host-facing and wants a hardware A/B.
* **47/47 proves absence of collateral damage, not correctness.** No 573 module
  was touched, so the suite does not exercise the change. Only a fit and a board
  can.

## Verified dump hashes (acceptance criteria)

Staged in `local/sd-stage/games/System573/` (git-ignored) and copied to the
MiSTer's games folder. Anything not matching these is the wrong file.

| File | Source | Hash |
|---|---|---|
| `573bios.bin`, `boot.rom` | `sys573.zip` → `700a01.22g` | crc `11812ef8` |
| `573bios_gchgchmp.bin` | `sys573.zip` → `700a01,gchgchmp.22g` | crc `39ebb0ca` |
| `hbbflash.bin` | built by `tools/pack_hyperbbc.py` | crc `638e1e54` |
| `hbbnvram.bin` | `hyperbbc.zip` → `876ea.22h` | crc `8e11d196` |
| `hypbbc2p.u1` | `hypbbc2p` set → **`gx908ja.u1`** | crc `8900eaff`, sha1 `aea4449c…` |
| `hypbbc2p.chd` | `hypbbc2p` set → `908a02.chd` | CHD v4, header sha1 `573194ca9938c30415fc88dcc0c0152dd3024d71` |
| `flash16m_blank.bin` | generated, 0xFF | crc `86175ebf` |
| `nvram8k_blank.bin` | generated, 0xFF | crc `b4293435` |

**The cassette is the one that bites.** `games/System573/hypbbc2p.u1` in *git* is a
SYNTHESIZED cassette (crc `846648a5`) and stalls the boot at the on-screen `-11N`
wall — the BIOS boot check reads authentic-dump data from cassette block 1 that
`tools/gen_seccart_u1.py` cannot produce. Only crc `8900eaff` boots. A `-11N`
means the wrong file reached the drive, not a core bug.

**CHD note:** MAME's `DISK_IMAGE_READONLY` hash is of the data *inside* the CHD,
not the file, so `sha1sum` on the file will not match. Parse the CHD header's sha1
field instead (v4 header: sha1 at offset 0x20, v5 at 0x54).
