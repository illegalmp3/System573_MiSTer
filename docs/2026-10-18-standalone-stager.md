# Standalone stager for users' MAME romsets (2026-10-18)

`tools/s573_stage.py` builds `games/System573/` from a user's own MAME romsets. It is
the file we ship next to the release zip: one Python file, standard library only, and
nothing from this repository. It replaces "run `tools/stage_573.py` from a checkout
with `dumps/mame573/` filled in" as the user-facing way to stage titles.

    python3 s573_stage.py <MAME roms folder> <SD card or USB root>
    python3 s573_stage.py <MAME roms folder> --list
    python3 s573_stage.py --blank-saves <SD card or USB root>

## Where its facts come from

The tool carries a generated table (`TABLE`, between the BEGIN/END GENERATED
markers). `tools/gen_s573_titles.py` writes it from the same two sources the in-repo
tooling uses; `--check` fails when the table is stale.

- **What to stage = the launchers.** Every `<file path=...>` in `mgl/*.mgl` is a file
  the tool must produce. A launcher that loads `<set>.cue` gets the MODE1/2048
  cue + raw-2352 rebuild, one that loads `<set>.chd` gets the CHD as-is. A path with
  no recipe stops the generator.
- **Where it comes from = `ksys573.cpp`.** ROM names, sizes, CRC32 and SHA1
  (`ROM_LOAD` / `ROMX_LOAD`, the BIOS from `SYS573_BIOS_A`), disc SHA1s
  (`DISK_IMAGE`), the cassette chip per role and the PCMCIA card (through
  `stage_573.title_info()`), and for Hyper Bishi Bashi Champ the onboard-flash
  interleave (`flashbank_map`: base address and byte lane of each 29F016A).
- **The `.sav` size** comes from `stage_573.save_layout()` (factored out of
  `stage_573.main()` for this), so both stagers agree.

`stage_573.title_info()` also learned `ROT90`: its `GAME()` pattern only accepted
`ROT0`, so it could not read `konam80s`.

## How it finds the user's files

ROMs are looked up by **CRC32 + size** in every zip's central directory (and in loose
files of a matching size), then checked against MAME's **SHA1** after reading. Discs
are identified by the **SHA1 in the CHD header** -- the field MAME's `DISK_IMAGE`
SHA1 is (checked: v4 `0x30` and v5 `0x54` match the driver for 936eaa and 887jaa02).
So non-merged, split and merged sets all work, and zip / CHD names do not matter
(tested with every member renamed and the CHD renamed in a sub-folder). `.7z` sets
are not read (stdlib has no 7z); the tool says so when it sees them.

## CHD reader

Only the two MODE1/2048 discs (dsem 936eaa, dsfdct 910jca02) are decoded; every
other disc is copied and MiSTer Main reads it directly. The reader handles CHD v3/v4
(zlib) and v5 (uncompressed, `zlib`, `lzma`, `cdzl`, `cdlz`, including the v5
Huffman-coded hunk map and CD ECC regeneration), checks every hunk against the CRC
in the map, and checks the whole decoded image against the header's raw SHA1, so a
decoding mistake cannot produce a quietly wrong disc. Verified against the real
dumps: 894jaa02 and 887aaa02 (v5 cdlz/cdzl) and 936eaa, 910jca02 (v4) all decode to
their raw SHA1; ECC regeneration matches 20 stored sectors of 908a02.
`cdfl`/`zstd`/parent CHDs are refused with a `chdman copy -c cdlz,cdzl` hint.

## Verification

`tools/test_s573_stage.py WORK [MANIFEST]` (jobs 344, 346 under WSL):

- `stage_573.py` staged every title it handles into `ref/` (CHDs left out, the two
  MODE1 discs converted by `chd_to_raw2352.py`); the standalone stager staged
  everything from `dumps/mame573/` into `new/`. Every reference file a launcher
  loads is **byte-identical** (`.u1` incl. ZS01 padding, `.u6`, `.cas`, `dsem.bin`/
  `dsfdct.bin` + cues, `.sav`); every copied CHD equals its source.
- `573bios.bin`, `573bios_gchgchmp.bin`, `hbbflash.bin`, `hbbnvram.bin`, the two
  blanks and `ddrsbm.u1/.u6` are byte-identical to `local/sd-stage/` (the files used
  on the cabinet).
- A second run writes nothing; an existing `.sav` is kept untouched; a 16 MiB
  pre-timekeeper `.sav` is extended to 16,786,432 B with its contents kept.
- An SD-root destination stages into `games/System573/`; `--dry-run` writes nothing.
- Windows (job 345, python.org embeddable Python 3.12.7 in `local/py-embed`): seven
  titles staged into a path with spaces, outputs identical to the WSL run, second
  run all "already correct".

24 of 26 titles stage from `dumps/mame573/`; ddrs2k (905aaa02.chd) and konam80s
(set + disc) are not in that folder and are reported as missing, as they should be.

## Blank saves

`--blank-saves OUT` writes only the empty `.sav` of every title (real zero bytes,
never a truncated file -- see `stage_573.py`), skipping any that exist. The release
also carries them as `System573_blank_saves.zip` (24 files, ~1 MB zipped) for anyone
staging by hand. It is a separate download on purpose: extracting it over a card
that already has saves would replace installed games with empty ones.

## Not covered

- Python is not on Windows by default (this PC only has the Store stub); users need
  Python 3.8+ from python.org or the Microsoft Store.
- MiSTer's own Linux has a Python 3, so the tool may run on the MiSTer itself; not
  tried.
