#!/usr/bin/env python3
"""
stage_573.py - stage ANY System 573 DDR/Dancing Stage title onto the games volume.

    python3 tools/stage_573.py <romset> "/Volumes/Samsung T7/games/System573"
    python3 tools/stage_573.py <romset> --dry-run

Every per-title fact is READ OUT OF dumps/mame573/ksys573.cpp at run time -- the
machine config (and so the PCMCIA slot and size), the cassette roles and their
chip types, and the disc name. Nothing is hardcoded per title, so the driver stays
the single source of truth and a wrong assumption about one title cannot hide in a
table someone forgot to update. This replaces the hand-written per-title scripts
(stage_dsfdr.sh, stage_ddr4m.sh), which are kept only as worked references.

CHIP TYPE COMES FROM THE MACHINE CONFIG, not from the dump size. The cass* helper
in ksys573.cpp names the device per role -- option_add("game", KONAMI573_CASSETTE_ZI)
and so on -- and KONAMI573_CASSETTE_X*/Y*/Z* map to X76F041 / X76F100 / ZS01.
(An earlier version of this script inferred the chip from the .u1 SIZE using emu.sv's
load-time rule, and got ddr4m's 140-byte ZS01 wrong -- it called it an X76F100. That
rule describes what emu sees AFTER staging, so using it to decide how to stage is
circular. The driver states the answer; read it there.)

Sizes then decide the HANDLING:
    X76F041 (548 B) / X76F100 (132 B) -> used as-is
    ZS01    (140 B) -> PADDED to 4116 B by tools/stage_zs01_u1.py, which also verifies
                       the response-to-reset, the fixed PIC command key, the plaintext
                       game code and the DS2401 cross-check. Left unpadded, emu's size
                       rule would infer X76F100 and the game would see the wrong
                       response-to-reset.
"""
import argparse, os, re, shutil, subprocess, sys, tempfile, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUMPS = os.path.join(ROOT, "dumps", "mame573")
DRIVER = os.path.join(DUMPS, "ksys573.cpp")

CARD_SIZE = {"pccard1_16mb": ("1", 16), "pccard1_32mb": ("1", 32),
             "pccard2_32mb": ("2", 32), "pccard2_64mb": ("2", 64)}

# KONAMI573_CASSETTE_<suffix> -> chip. X = X76F041, Y = X76F100, Z = ZS01;
# a trailing I means the cassette also carries a DS2401 silicon serial.
CASSETTE_CHIP = {"X": "X76F041", "XI": "X76F041", "Y": "X76F100", "YI": "X76F100",
                 "Z": "ZS01", "ZI": "ZS01"}


def driver_text():
    if not os.path.exists(DRIVER):
        sys.exit(f"missing {DRIVER} -- the driver is the source of truth here")
    return open(DRIVER, errors="replace").read()


def machine_bodies(src):
    out = {}
    for m in re.finditer(r"void\s+\w+::(\w+)\(machine_config &config\)\s*\{", src):
        i, depth, j = m.end(), 1, m.end()
        while depth and j < len(src):
            depth += (src[j] == "{") - (src[j] == "}")
            j += 1
        out[m.group(1)] = src[i:j]
    return out


def resolve(cfg, bodies, seen=None):
    seen = seen or set()
    if cfg in seen or cfg not in bodies:
        return set()
    seen.add(cfg)
    feats = set()
    for call in re.findall(r"\b(\w+)\s*\(\s*config\s*[,)]", bodies[cfg]):
        feats.add(call)
        feats |= resolve(call, bodies, seen)
    if "KONAMI_573_MEMORY_CARD_READER" in bodies[cfg]:
        feats.add("*k573mcr")
    return feats


def title_info(romset):
    src = driver_text()
    bodies = machine_bodies(src)
    g = re.search(r'GAME\(\s*\d+,\s*%s,\s*\w+,\s*(\w+),\s*\w+,\s*\w+,\s*\w+,\s*ROT0,\s*"Konami",\s*"([^"]+)"' % re.escape(romset), src)
    if not g:
        sys.exit(f"{romset}: no GAME() line in ksys573.cpp")
    cfg, desc = g.group(1), g.group(2)
    feats = resolve(cfg, bodies)
    slot, mb = next((CARD_SIZE[k] for k in CARD_SIZE if k in feats), (None, 0))
    r = re.search(r"ROM_START\(\s*%s\s*\)(.*?)ROM_END" % re.escape(romset), src, re.S)
    if not r:
        sys.exit(f"{romset}: no ROM_START in ksys573.cpp")
    body = r.group(1)

    # role -> chip, straight out of the cass* helper this config pulls in
    role_chip = {}
    for f in feats:
        for o in re.finditer(r'option_add\(\s*"(\w+)"\s*,\s*KONAMI573_CASSETTE_(\w+)\s*\)', bodies.get(f, "")):
            role_chip[o.group(1)] = CASSETTE_CHIP.get(o.group(2), "?" + o.group(2))

    cassettes = {}
    for reg in re.finditer(r'ROM_REGION\(\s*0x[0-9a-fA-F]+,\s*"cassette:(\w+):(eeprom|id)"\s*,[^)]*\)\s*ROM_LOAD\(\s*"([^"]+)"\s*,\s*0x[0-9a-fA-F]+\s*,\s*0x([0-9a-fA-F]+)', body):
        role, kind, fname, sz = reg.group(1), reg.group(2), reg.group(3), int(reg.group(4), 16)
        cassettes.setdefault(role, {})[kind] = (fname, sz)
    discs = re.findall(r'DISK_IMAGE(?:_READONLY)?\(\s*"([^"]+)"', body)
    return dict(romset=romset, cfg=cfg, desc=desc, slot=slot, card_mb=mb,
                mcr="*k573mcr" in feats, cassettes=cassettes, discs=discs,
                role_chip=role_chip, dio="k573d" in feats)


def chip_of(t, role):
    """The chip for this cassette role, per the driver's machine config."""
    c = t["role_chip"].get(role)
    if c is None:
        sys.exit(f"{t['romset']}: no KONAMI573_CASSETTE_* option for role '{role}' "
                 f"in config {t['cfg']} -- refusing to guess")
    return c


def chd_track(path):
    try:
        d = open(path, "rb").read()
    except OSError:
        return None
    m = re.search(rb"TRACK:\s*\d+\s+TYPE:\s*([A-Z0-9_]+)\s+SUBTYPE:\s*([A-Z_]+)\s+FRAMES:\s*(\d+)", d)
    return (m.group(1).decode(), m.group(2).decode(), int(m.group(3))) if m else None



MGL_HEAD = """<!--
  {rom} ({desc}) -- {phase} launcher.
  GENERATED by tools/stage_573.py from ksys573.cpp. Do not hand-edit; regenerate.

  Machine config {cfg} -> {board} board{cardline}.
  Cassette this launcher loads: {chip}{casnote}
  Disc {disc}: TYPE:{dtype} FRAMES:{frames}{convnote}

  OSD for this title:
    573 PCMCIA Card = {osdcard}
    573 Cabinet     = {cab}
    573 Boot Device = {boot}
    573 MP3 Descramble = DEFAULT

  Six items max: Main parses at most SIX file/reset items per .mgl
  (mra_loader.h mgl_item_struct item[6]) and silently drops the rest. This is
  exactly six, which is also why the PCMCIA card shares the slot-4 save file
  rather than having its own mount.

  The .sav MUST exist before launch -- an .mgl type="s" item mounts with pre=0 and
  a missing file EJECTS the slot (docs/2026-09-12-flash-persistence-fixed.md).
  tools/stage_573.py creates it at {savmb} MiB (+1 KB for a ZS01 cassette, +9 KB timekeeper).

  After an install, WAIT for the "Flash saved" toast before cutting power. The game
  tells you to switch off at exactly the moment the auto-save has not fired yet
  (it needs ~9 s of flash quiet, then streams {savmb} MiB).
-->
<mistergamedescription>
  <rbf>_Console/Konami_System_573</rbf>
  <setname>System573</setname>
  <file delay="1" type="f" index="0" path="573bios.bin"/>
  <file delay="1" type="f" index="4" path="{u1}"/>
  <file delay="1" type="f" index="5" path="{u6}"/>
  <file delay="2" type="s" index="1" path="{chd}"/>
  <file delay="3" type="s" index="4" path="{sav}"/>
  <reset delay="1"/>
</mistergamedescription>
"""


def write_launchers(t, mgldir, sav_mb, disc_name, dtype, frames):
    os.makedirs(mgldir, exist_ok=True)
    rom = t["romset"]
    cab = "DDR Solo" if "Solo" in t["desc"] else "STANDARD"
    osdcard = "32MB (slot 2)" if t["slot"] == "2" else "Off"
    cardline = f", PCMCIA slot {t['slot']} / {t['card_mb']} MB" if t["slot"] else ", no PCMCIA card"
    conv = "" if dtype == "MODE1_RAW" else "   <== MODE1/2048: ships as cue+raw2352, NOT the CHD"
    roles = sorted(t["cassettes"])
    two = len(roles) > 1
    out = []
    for role in roles:
        install = (role != "game")
        stem = f"{rom}_install" if install else (f"{rom}_console" if two else rom)
        note = ("  (the INSTALL cassette -- swapped for the game cassette on a real cabinet;"
                " two launchers, one physical slot)" if two else "")
        txt = MGL_HEAD.format(
            rom=rom, desc=t["desc"], phase="INSTALL" if install else "PLAY",
            cfg=t["cfg"], board="digital (k573dio)" if t["dio"] else "analog (GX700-PWB(F))",
            cardline=cardline, chip=chip_of(t, role), casnote=note,
            disc=disc_name, dtype=dtype, frames=frames, convnote=conv,
            osdcard=osdcard, cab=cab,
            boot="CD-ROM" if install else ("Flash ROM" if two else "CD-ROM to install, Flash ROM after"),
            savmb=sav_mb,
            u1=f"{rom}_install.u1" if install else f"{rom}.u1",
            u6=f"{rom}_install.u6" if install else f"{rom}.u6",
            chd=(f"{rom}.cue" if dtype == "MODE1" else f"{rom}.chd"), sav=f"{rom}.sav")
        fp = os.path.join(mgldir, stem + ".mgl")
        open(fp, "w").write(txt)
        out.append(os.path.basename(fp))
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("romset")
    ap.add_argument("dest", nargs="?")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--mgl", metavar="DIR", help="also write launcher(s) into DIR (e.g. mgl)")
    a = ap.parse_args()

    t = title_info(a.romset)
    card = f"slot {t['slot']} / {t['card_mb']} MB" if t["slot"] else "none"
    sav_mb = 16 + (t["card_mb"] if t["slot"] == "2" and t["card_mb"] == 32 else 0)
    # A ZS01 cassette is NVRAM (zs01.cpp nvram_read/nvram_write) and an install writes
    # it, so its state rides in ONE extra 1 KB block after the flash image(s)
    # (rtl/s573_cass_nv.v). Main never grows a type="s" image (pre=0 -> cangrow=0:
    # user_io.cpp clamps a write past EOF to zero bytes), so the block must already
    # be in the file.
    zs01 = any(chip_of(t, r) == "ZS01" for r in t["cassettes"])
    # The M48T58 timekeeper (settings, bookkeeping) is NVRAM too and every title writes
    # it; its 8 KB image rides as a 9-block region (1 KB header + 8 KB) after the
    # cassette block (rtl/s573_tk_nv.v, 2026-09-28: ddrextrm NOTE 605 "RTC-RAM cleared"
    # on every boot). Same rule: the region must already be in the file.
    TK_BYTES = 9 * 1024
    sav_bytes = (sav_mb << 20) + (1024 if zs01 else 0) + TK_BYTES

    print(f"== {t['romset']}: {t['desc']}")
    print(f"   machine config : {t['cfg']}   board: {'digital (k573dio)' if t['dio'] else 'analog'}")
    print(f"   PCMCIA         : {card}")
    print(f"   JVS memcard rdr: {'in the config (player-facing; not a boot gate -- ddr4m 2026-09-15)' if t['mcr'] else 'no'}")
    for role, parts in sorted(t["cassettes"].items()):
        fn, sz = parts.get("eeprom", ("?", 0))
        u6 = parts.get("id", ("-", 0))[0]
        chip = chip_of(t, role)
        pad = "  -> PAD to 4116 B (stage_zs01_u1.py)" if chip == "ZS01" else "  -> as-is"
        print(f"   cassette {role:<7}: {fn} {sz} B = {chip:<7} id={u6}{pad}")
    for d in t["discs"]:
        p = os.path.join(DUMPS, d + ".chd")
        tr = chd_track(p)
        if tr is None:
            print(f"   disc {d:<10}: NOT PRESENT in dumps/mame573")
        else:
            conv = "" if tr[0] == "MODE1_RAW" else "   <== MODE1/2048: needs cue+raw2352 conversion (see dsem)"
            print(f"   disc {d:<10}: TYPE:{tr[0]} SUBTYPE:{tr[1]} FRAMES:{tr[2]}{conv}")
    print(f"   save file      : {sav_bytes} B  ({'16 MB onboard flash + 32 MB card' if sav_mb == 48 else '16 MB onboard flash'}"
          f"{' + 1 KB ZS01 cassette state' if zs01 else ''} + 9 KB timekeeper)")

    if t["slot"] == "1":
        print("\n   *** SLOT 1 IS NOT MODELLED. rtl/s573_flash.v decodes slot 2 (banks 32-47)")
        print("       only; banks 16-31 read 0xFFFF = empty slot. This title cannot work yet. ***")
    if t["card_mb"] == 64:
        print("\n   *** 64 MB KONAMI_DUAL card -- a different device, not modelled. ***")

    if a.mgl:
        d0 = t["discs"][0] if t["discs"] else "?"
        tr = chd_track(os.path.join(DUMPS, d0 + ".chd")) or ("?", "?", 0)
        made = write_launchers(t, a.mgl, sav_mb, d0, tr[0], tr[2])
        print("   launchers: " + ", ".join(made))

    if a.dry_run or not a.dest:
        print("\n   (dry run -- nothing written)")
        return
    if not os.path.isdir(a.dest):
        sys.exit(f"no such directory: {a.dest}")

    zp = os.path.join(DUMPS, a.romset + ".zip")
    if not os.path.exists(zp):
        sys.exit(f"missing {zp}")
    print()
    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(zp) as z:
            names = set(z.namelist())
            for role, parts in sorted(t["cassettes"].items()):
                stem = a.romset if role == "game" else f"{a.romset}_install"
                fn, sz = parts["eeprom"]
                if fn not in names:
                    sys.exit(f"{fn} not in {zp}")
                z.extract(fn, tmp)
                u1_out = os.path.join(a.dest, stem + ".u1")
                if chip_of(t, role) == "ZS01":
                    u6n = parts["id"][0]
                    subprocess.check_call([sys.executable, os.path.join(ROOT, "tools", "stage_zs01_u1.py"),
                                           zp, "--u1", fn, "--u6", u6n, "-o", u1_out])
                else:
                    shutil.copyfile(os.path.join(tmp, fn), u1_out)
                    print(f"   {stem}.u1 <- {fn} ({sz} B, {chip_of(t, role)}, as-is)")
                u6n = parts["id"][0]
                if u6n in names:
                    z.extract(u6n, tmp)
                    shutil.copyfile(os.path.join(tmp, u6n), os.path.join(a.dest, stem + ".u6"))
                    print(f"   {stem}.u6 <- {u6n}")
        for d in t["discs"]:
            src = os.path.join(DUMPS, d + ".chd")
            if not os.path.exists(src):
                continue
            tr = chd_track(src)
            if tr and tr[0] == "MODE1":
                # 2048-byte sectors: no sync/header stored, so the CHD cannot be
                # served directly. Re-wrap as raw 2352 (tools/chd_to_raw2352.py,
                # whose recipe is verified byte-for-byte against the proven dsem.bin).
                subprocess.check_call([sys.executable,
                                       os.path.join(ROOT, "tools", "chd_to_raw2352.py"),
                                       src, "-o", os.path.join(a.dest, a.romset)])
            else:
                shutil.copyfile(src, os.path.join(a.dest, a.romset + ".chd"))
                print(f"   {a.romset}.chd <- {d}.chd")
        sav = os.path.join(a.dest, a.romset + ".sav")
        if os.path.exists(sav):
            have = os.path.getsize(sav)
            # a save from before the cassette block / timekeeper region existed: APPEND
            # the missing zero bytes (written bytes, see below). The flash image in
            # front is untouched, so the install is kept; a zero region is "nothing
            # saved yet" to the core (header magic absent) and is filled on first save.
            older = {sav_mb << 20: "cassette block + timekeeper region",
                     (sav_mb << 20) + (1024 if zs01 else 0): "timekeeper region"}
            if have in older and have < sav_bytes:
                with open(sav, "ab") as f:
                    f.write(bytes(sav_bytes - have))
                    f.flush()
                    os.fsync(f.fileno())
                print(f"   {a.romset}.sav extended by the {older[have]} -> {sav_bytes} B (install kept)")
            elif have != sav_bytes:
                print(f"   WARNING {a.romset}.sav is {have} B, expected {sav_bytes}")
            else:
                print(f"   {a.romset}.sav already present at {sav_bytes} B -- left alone (may hold an install)")
        else:
            # WRITE the zeroes -- never f.truncate(). All 16 saves this script made
            # on 2026-09-15 with truncate() were NEVER written by the MiSTer (Mac
            # mtimes, 0 non-zero bytes after installs), while every save created with
            # real zero bytes (tools/stage_ddr4m.sh uses dd) holds its install. A
            # truncate-extended file on the exFAT T7 is allocated but its data was
            # never written; writing the bytes is what the working saves have in common.
            blk = bytes(1 << 20)
            with open(sav, "wb") as f:
                for _ in range(sav_mb):
                    f.write(blk)
                if zs01:
                    f.write(bytes(1024))
                f.write(bytes(TK_BYTES))
                f.flush()
                os.fsync(f.fileno())
            print(f"   {a.romset}.sav created, {sav_bytes} B of zeroes (written, not truncated)")
    print(f"\n   OSD: 573 PCMCIA Card = {'32MB (slot 2)' if t['slot']=='2' else 'Off'}"
          f" | Cabinet = {'DDR Solo' if 'Solo' in t['desc'] else 'STANDARD'}"
          f" | Boot Device = CD-ROM to install, Flash ROM after")
    print("   Wait for the \"Flash saved\" toast after the install before cutting power.")


if __name__ == "__main__":
    main()
