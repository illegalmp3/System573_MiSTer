# Two-cassette titles get ONE launcher (the `.cas` cassette pack)

**2026-09-28.** Design + sim verdict + build. Hardware: pending (see "What to test").

Build (job 168, 1,528 s): 37,628 / 41,910 ALM (90 %, +481 over the previous build),
LABs 4,170 / 4,191 (99.5 %), all timing corners non-negative (worst 0.071 ns), no
undriven nets. Deployed to the SD as `Konami_System_573.rbf` (md5
`a3de1dc5975b1911235eb7fa66043e12`, read back identical); the previous bitstream is
kept as `Konami_System_573.prev-20260928f.rbf`.

## The question

Titles such as DDR 3rd/4th Mix shipped two `.mgl`s -- `<rom>_install.mgl` and
`<rom>_console.mgl` -- while DDR Extreme, MAX, 5th Mix etc. have one. Can the pairs
become single launchers?

## Why there were two

`ksys573.cpp`, header Note 3:

> Some games require an installation cassette when installing from CD. Go to the
> slot devices menu in the tab menu and change the cassette from "game" to
> "install" and select reset. After installing you need to change the cassette
> back to "game" and select reset.

The machine configs make it explicit: `cassxzi` = game `KONAMI573_CASSETTE_ZI`
(ZS01 + DS2401) + install `_XI` (X76F041 + DS2401); `cassyyi` = game `_YI` + install
`_YI` (X76F100 + DS2401 twice). Every ROM_START for these titles loads both a
`cassette:game:*` and a `cassette:install:*` region. One physical slot, two
cassettes, swapped by hand -- MAME models the swap as a slot option + reset.

Of the staged Tier 2/3 set that is:

| config    | game    | install | titles |
|-----------|---------|---------|--------|
| `cassxzi` | ZS01    | X76F041 | ddr3mp, ddr4m, ddr4mj, ddr4mp, ddr4mps, ddr4ms, ddr4msj, dsfdr |
| `cassyyi` | X76F100 | X76F100 | ddr3ma, ddr3mj, ddr3mk, ddr3mka, ddrs2k, ddrs2kj, dsfdct |

(`option_add("install", ...)` is only ever `_XI` or `_YI` in the driver -- an install
cassette is never a ZS01.)

The core held ONE cassette image (ioctl index 4 = `.u1`, index 5 = `.u6`), and MiSTer
Main parses at most SIX `<file>`/`<reset>` items per `.mgl`
(`support/arcade/mra_loader.h`: `mgl_item_struct item[6]`; `scan_mgl` silently drops
the rest; the `<reset>` counts -- it is `MGL_ACTION_RESET`, a 100 ms `BUTTON2` pulse
via `user_io_set_kbd_reset`). The launchers use exactly six (bios, u1, u6, chd, sav,
reset). Hence two launchers, differing only in which `.u1`/`.u6` they load.

## The design

**Hold both cassettes, pick one with the OSD.** Three pieces:

1. **`rtl/s573_cass_pack.v`** -- the index-5 file is now EITHER the 8-byte `.u6` OR a
   `.cas` pack:

   | bytes    | content |
   |----------|---------|
   | `[0:7]`  | game cassette DS2401 serial -- the `.u6` exactly |
   | `[8:15]` | install cassette DS2401 serial (`cassette:install:id`) |
   | `[16:]`  | install cassette EEPROM image as dumped (548 B X76F041 / 132 B X76F100) |

   An 8-byte `.u6` never reaches byte 8, so single-cassette titles are byte-for-byte
   unchanged. The install chip is inferred from the file SIZE with the same rule
   emu.sv uses for the game `.u1` (highest byte index >= 16+256 -> X76F041, else
   >= 16+8 -> X76F100), latched when the download ends. The F5 entry is
   `"F5,U6CAS,..."` and the decode is on `ioctl_index[5:0] == 5` so the extension
   sub-index cannot matter.

2. **`rtl/s573_seccart.v`** -- a second cassette: its own DS2401 (`inst_id`) and its
   own X76F100 (`inst100`); an install X76F041 lives in the existing `eeprom041`,
   which no two-cassette config uses for its GAME chip (the staging tool refuses
   any other pairing). `inst_sel` puts the install cassette in the slot: exactly one
   of {eeprom100, eeprom041, zs01, inst100} has its CS driven, the SDA read-back and
   the DS2401 pull-down follow, and the `sec_dbg[63:62]` stamp (HPS STATUS word 9)
   reports the type of the cassette IN THE SLOT.

   Two loading details that matter:
   * the `.sav` ZS01 restore (`s573_cass_nv`) used to go through the shared load port
     into ALL models' low addresses. Harmless with one cassette; it would have
     overwritten bytes 0..139 of the install X76F041. `load_eep_zs01_only` routes the
     restore to the ZS01 alone.
   * a 4116-byte ZS01 `.u1` wraps its low 10 address bits over `eeprom041`. In
     launcher order (`.u1` then `.cas`) the pack lands last and wins; for
     order-independence `inst041_loaded` shuts the `.u1` stream out of `eeprom041`
     once an install image bigger than an X76F100's has been loaded.

3. **OSD `"O[110:109],573 Cassette,Auto,Game,Install;"`** -- `Auto` follows
   `573 Boot Device`: CD-ROM -> install cassette, Flash ROM -> game cassette. That is
   the sequence the operator performs (Note 3) and what the two launchers encoded.
   `Game`/`Install` force it (drmn2mpu's install note in the driver wants the GAME
   cassette with a CD boot for its second step -- not a DDR case, but the override is
   free). The selection is live like the DIP switch; change it before launching.

So the install/play flow becomes the ddrextrm flow for every title: **Boot Device =
CD-ROM, launch, install, wait for "Flash saved"; Boot Device = Flash ROM, launch.**

The `.sav` layout is unchanged and now CONSISTENT across install and play
(`sec_cart_type` -- the ZS01 block's presence -- comes from the game `.u1`, not from
which cassette is selected; the old install launcher saved WITHOUT the cassette
block and the console launcher expected it after the flash image, so the
timekeeper region moved between the two -- the magic-checked headers made that
safe, but it was two layouts for one file).

## What the sims prove (`sim/tb_s573_seccart_dual.v`, in the suite)

Fixtures are the REAL dumps, produced by the SAME tools that stage the T7
(`stage_zs01_u1.py`, `make_cas_pack.py`): ddr4m `gca33aa.u1/.u6` (game ZS01) +
`gea33aa.u1/.u6` (install X76F041) and ddr3ma `gn887aa.*` + `ge887aa.*` (X76F100 x2).
The bench drives the D0-D7 latch with the BIOS/installer waveforms of the existing
cassette benches.

* Part 0: a plain 8-byte `.u6` through the splitter -> 8 game-serial writes, 0 install
  writes, `inst_present = 0`.
* Part A (ddr4m, launcher order, then a ZS01 NVRAM restore over addresses 0..139):
  `inst_present/type = 1/1`; install selected -> X76F041 RTR `19 55 AA 55`, the REAL
  gea33aa config password accepted and a wrong one NAKed, BCR1/BCR2 and data[0..3] read
  back as the REAL image bytes (so neither the restore nor the wrapped `.u1` touched
  them), DS2401 ROM == gea33aa.u6; game selected -> ZS01 RTR `5A 53 00 01`, DS2401 ROM
  == gca33aa.u6 (asserted different from the install's), and an X76-framed RTR does
  NOT answer `19 55 AA 55`.
* Part B: the same in REVERSED file order -- the install cassette still authenticates
  and reads its own config (the guard).
* Part C (ddr3ma): install selected -> RTR `19 00 AA 55`, block 0 opens with the
  install read password and returns the install image's bytes, the game password is
  NAKed; game selected -> the mirror image; DS2401 follows the selection.

Every pre-existing cassette bench (`s573_seccart`, `zs01_*`, `s573_cass_nv`,
`x76f041`, `x76f100*`, `ds2401`, `system573_top`, `zs01_detect`, `sectrace_arm`,
`atapi_inquiry`, `drivecheck`) still passes with the new ports tied off.

### A model bug the new bench exposed (sim-only)

`x76f041.v` computed the registered read address with `doff(bytec)` in a CONTINUOUS
assignment; the function reads `command`/`address` from its body, and a simulator only
re-evaluates the assignment when the ARGUMENT changes. After the address byte was
latched the sim kept the previous command's offset for the whole first data byte
(the byte read as `00`; with `0x60` = READ CONFIG REGS just before, `rd_addr` sat at
96). Synthesis sees through the function, so hardware was never affected; the
expression now takes every input as an explicit argument (`doffb(command[0],
address, bytec)`) so the sim tells the truth.

## Staging

* `tools/make_cas_pack.py <romset.zip> --game-u6 --install-u1 --install-u6 -o <rom>.cas`
  builds the pack and checks the image sizes against the driver's ROM_REGION lengths.
* `tools/stage_573.py` writes ONE `<rom>.mgl` for every title; for two-cassette titles
  it also writes `<rom>.cas` next to `<rom>.u1/.u6`. The game `.u1`/`.u6` already on
  the T7 are the same files the old console launcher used, so re-staging only ADDS
  the `.cas`. The old `_install.u1/.u6` and the launcher pairs keep working on the new
  bitstream (an 8-byte index-5 file = no install cassette) and can be deleted once the
  single launchers are confirmed.

## What to test on the SuperStation One

1. A single-cassette title (ddrextrm) still boots from flash on the new bitstream --
   the index-5 path changed width (AW 3 -> 10) and decode (`[5:0]`).
2. ddr4m (cassxzi) from `ddr4m.mgl`: Boot Device = CD-ROM -> the installer must see
   the X76F041 install cassette (no "cassette does not match"); wait for "Flash
   saved"; Boot Device = Flash ROM -> boots to attract with the ZS01 game cassette
   and plays a credit. HPS STATUS word 9 bits [15:14] = 1 during the install, 2 in play.
3. ddr3ma (cassyyi) the same way -- the first title to exercise `inst100`.
4. Regression: an OLD pair (e.g. `ddr3mj_install/_console`) still works.
