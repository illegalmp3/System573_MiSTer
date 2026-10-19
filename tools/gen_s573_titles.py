#!/usr/bin/env python3
"""
gen_s573_titles.py - regenerate the title table embedded in tools/s573_stage.py.

    python3 tools/gen_s573_titles.py            # rewrite the table in tools/s573_stage.py
    python3 tools/gen_s573_titles.py --check    # exit 1 if the embedded table is stale

tools/s573_stage.py is the stager we ship: it builds games/System573 from a user's
own MAME romsets and needs nothing from this repository. Everything it knows about
a title is a table, and the table is generated HERE, from the same two sources of
truth the in-repo tooling uses:

  * mgl/*.mgl -- the launchers we ship. Each <file path=...> item is a file the
    stager must produce, so the launchers decide WHAT is staged (a launcher that
    asks for <set>.cue gets the MODE1 cue+raw2352 conversion, one that asks for
    <set>.chd gets the CHD as-is). A path with no recipe here stops the generator.
  * dumps/mame573/ksys573.cpp -- MAME's driver. It says where each file comes
    from: the ROM names, sizes, CRC32s and SHA1s (ROM_LOAD / ROMX_LOAD), the disc
    SHA1s (DISK_IMAGE), the cassette chip per role and the PCMCIA card (through
    tools/stage_573.py title_info(), the same parser stage_573 stages with), and
    the onboard-flash interleave (flashbank_map) for titles that ship flash ROMs.

The .sav size comes from stage_573.save_layout(), so both stagers agree.
"""
import argparse, hashlib, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import stage_573 as S                       # noqa: E402
from s573_names import games, launcher_file  # noqa: E402

ROOT = S.ROOT
MGL_DIR = os.path.join(ROOT, "mgl")
TOOL = os.path.join(HERE, "s573_stage.py")
BEGIN = "# ======== BEGIN GENERATED TABLE"
END = "# ======== END GENERATED TABLE"

ROMLOAD = re.compile(
    r'ROMX?_LOAD\(\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*'
    r'(?:BAD_DUMP\s+)?CRC\(([0-9a-fA-F]{8})\)\s*SHA1\(([0-9a-fA-F]{40})\)')
DISK = re.compile(r'DISK_IMAGE(?:_READONLY)?\(\s*"([^"]+)"\s*,\s*\d+\s*,\s*'
                  r'(?:BAD_DUMP\s+)?SHA1\(([0-9a-fA-F]{40})\)')


def die(msg):
    sys.exit("gen_s573_titles: " + msg)


def rom_start(src, romset):
    m = re.search(r"ROM_START\(\s*%s\s*\)(.*?)ROM_END" % re.escape(romset), src, re.S)
    if not m:
        die(f"{romset}: no ROM_START")
    return m.group(1)


def rom_lines(body):
    """{rom name: (size, crc, sha1)} for the dumped ROMs in a ROM_START body."""
    out = {}
    for m in ROMLOAD.finditer(body):
        out[m.group(1)] = (int(m.group(3), 16), m.group(4).lower(), m.group(5).lower())
    return out


def bios_roms(src):
    """The SYS573_BIOS_A options: ({option name: BIOS rom name}, rom lines)."""
    i = src.find("#define SYS573_BIOS_A")
    if i < 0:
        die("no SYS573_BIOS_A macro")
    body = []
    for line in src[i:].splitlines():
        body.append(line)
        if not line.rstrip().endswith("\\"):
            break
    body = "\n".join(body)
    opts = dict((int(n), o) for n, o in re.findall(r'ROM_SYSTEM_BIOS\(\s*(\d+)\s*,\s*"(\w+)"', body))
    by_bios = {}
    for name, n in re.findall(r'ROMX_LOAD\(\s*"([^"]+\.22g)".*?ROM_BIOS\(\s*(\d+)\s*\)', body):
        by_bios[opts[int(n)]] = name
    return by_bios, rom_lines(body)


def flash_lanes(src):
    """Onboard flash layout from ksys573.cpp flashbank_map: [(region, base, lane)].
    lane 0 = umask16(0x00ff) = even bytes, lane 1 = umask16(0xff00) = odd bytes."""
    m = re.search(r"void\s+ksys573_state::flashbank_map\(address_map &map\)\s*\{(.*?)\n\}", src, re.S)
    if not m:
        die("no flashbank_map")
    out = []
    for r in re.finditer(r'map\(\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*\)\.rw\(\s*"([^"]+)"'
                         r'.*?\.umask16\(\s*(0x[0-9a-fA-F]+)\s*\)', m.group(1)):
        lane = {0x00ff: 0, 0xff00: 1}[int(r.group(4), 16)]
        out.append((r.group(3), int(r.group(1), 16), lane))
    if len(out) != 8:
        die(f"flashbank_map: expected 8 chips, found {len(out)}")
    return out


def regions(body):
    """{region tag: rom name} for single-ROM regions in a ROM_START body."""
    out = {}
    for m in re.finditer(r'ROM_REGION\w*\(\s*0x[0-9a-fA-F]+\s*,\s*"([^"]+)"[^)]*\)\s*(?:/\*.*?\*/\s*)?ROMX?_LOAD\(\s*"([^"]+)"', body):
        out[m.group(1)] = m.group(2)
    return out


def mgl_files(path):
    txt = open(path, encoding="utf-8").read()
    body = txt[txt.index("<mistergamedescription>"):]
    return re.findall(r'<file\b[^>]*\bpath="([^"]+)"', body)


class Gen:
    def __init__(self):
        self.src = S.driver_text()
        self.roms = {}
        self.bios_opt, self.bios_lines = bios_roms(self.src)

    def rom(self, setname, name, lines):
        if name not in lines:
            die(f"{setname}: {name} has no dumped ROM_LOAD line (NO_DUMP?)")
        size, crc, sha1 = lines[name]
        key = f"{setname}/{name}"
        self.roms[key] = {"name": name, "set": setname, "size": size, "crc": crc, "sha1": sha1}
        return key

    def bios(self, option):
        if option not in self.bios_opt:
            die(f"no BIOS option {option!r} in SYS573_BIOS_A")
        return self.rom("sys573", self.bios_opt[option], self.bios_lines)

    def recipe(self, setname, path):
        if path == "573bios.bin":
            return {"make": "rom", "rom": self.bios("std")}
        if path == "573bios_gchgchmp.bin":
            return {"make": "rom", "rom": self.bios("gchgchmp")}
        # The blanks the hypbbc2p [Install] launcher erases flash and NVRAM with:
        # all 0xFF (checked against local/sd-stage, the files used on hardware).
        if path == "flash16m_blank.bin":
            return {"make": "fill", "size": 16 << 20, "byte": 0xFF}
        if path == "nvram8k_blank.bin":
            return {"make": "fill", "size": 8192, "byte": 0xFF}
        body = rom_start(self.src, setname)
        lines = rom_lines(body)
        if path == "hbbflash.bin":
            # tools/pack_hyperbbc.py, generalised: the 16 MB onboard flash image is the
            # eight 29F016A dumps interleaved exactly as flashbank_map wires them.
            reg = regions(body)
            parts = []
            for tag, base, lane in flash_lanes(self.src):
                if tag not in reg:
                    die(f"{setname}: no ROM for flash chip {tag}")
                parts.append({"rom": self.rom(setname, reg[tag], lines), "base": base, "lane": lane})
            return {"make": "flash", "size": 16 << 20, "fill": 0xFF, "parts": parts}
        if path == "hbbnvram.bin":
            reg = regions(body)
            return {"make": "rom", "rom": self.rom(setname, reg["m48t58"], lines)}
        t = S.title_info(setname)
        stem, ext = os.path.splitext(path)
        if stem != setname:
            die(f"{setname}: launcher file {path!r} has no recipe")
        cas = t["cassettes"]
        if ext == ".sav":
            mb, zs01, total = S.save_layout(t)
            older = sorted({mb << 20, (mb << 20) + (1024 if zs01 else 0)} - {total})
            return {"make": "sav", "size": total, "older": older}
        if ext == ".u1":
            g = cas["game"]
            key = self.rom(setname, g["eeprom"][0], lines)
            if S.chip_of(t, "game") == "ZS01":
                ds = self.rom(setname, g["id"][0], lines) if "id" in g else None
                return {"make": "zs01", "rom": key, "ds2401": ds}
            return {"make": "rom", "rom": key, "chip": S.chip_of(t, "game")}
        if ext == ".u6":
            return {"make": "rom", "rom": self.rom(setname, cas["game"]["id"][0], lines)}
        if ext == ".cas":
            g, i = cas["game"], cas["install"]
            return {"make": "cas", "game_u6": self.rom(setname, g["id"][0], lines),
                    "install_u6": self.rom(setname, i["id"][0], lines),
                    "install_u1": self.rom(setname, i["eeprom"][0], lines),
                    "install_chip": S.chip_of(t, "install")}
        if ext in (".chd", ".cue"):
            disks = dict((d, h) for d, h in DISK.findall(body))
            if not t["discs"] or t["discs"][0] not in disks:
                die(f"{setname}: no dumped DISK_IMAGE to load")
            disc = t["discs"][0]          # the runtime disc (stage_573.title_info order)
            sha1 = disks[disc]
            r = {"make": "chd" if ext == ".chd" else "mode1", "disc": disc, "sha1": sha1.lower()}
            if ext == ".cue":
                r["bin"] = setname + ".bin"
            return r
        die(f"{setname}: launcher file {path!r} has no recipe")

    def build(self):
        names = {}
        for s in games():
            try:
                names[launcher_file(s)] = s
                names[launcher_file(s, install=True)] = s
            except SystemExit:      # sys573 itself: the BIOS entry, no version code
                pass
        titles = {}
        for f in sorted(os.listdir(MGL_DIR)):
            if not f.endswith(".mgl"):
                continue
            if f not in names:
                die(f"mgl/{f}: not the launcher name of any romset (tools/s573_names.py)")
            s = names[f]
            gl = re.search(r'^GAME\(\s*\d+,\s*%s,.*?"Konami",\s*"([^"]+)"' % re.escape(s),
                           self.src, re.M)
            t = titles.setdefault(s, {"set": s, "title": gl.group(1), "launchers": [], "files": {}})
            t["launchers"].append(f)
            for p in mgl_files(os.path.join(MGL_DIR, f)):
                r = self.recipe(s, p)
                if p in t["files"] and t["files"][p] != r:
                    die(f"{s}: {p} has two different recipes")
                t["files"][p] = r
        return {"roms": dict(sorted(self.roms.items())),
                "titles": [titles[k] for k in sorted(titles)]}


def render(table):
    md5 = hashlib.md5(open(S.DRIVER, "rb").read()).hexdigest()
    return (f"{BEGIN} by tools/gen_s573_titles.py -- do not edit by hand ========\n"
            f"# from ksys573.cpp (md5 {md5}) + mgl/\n"
            'TABLE = json.loads(r"""\n' + json.dumps(table, indent=1, sort_keys=True) +
            '\n""")\n' + END + " ========\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    block = render(Gen().build())
    txt = open(TOOL, encoding="utf-8").read()
    i, j = txt.index(BEGIN), txt.index(END)
    j = txt.index("\n", j) + 1
    new = txt[:i] + block + txt[j:]
    if a.check:
        if new != txt:
            sys.exit("tools/s573_stage.py: embedded table is STALE -- run tools/gen_s573_titles.py")
        print("table up to date")
        return
    if new != txt:
        with open(TOOL, "w", encoding="utf-8", newline="\n") as f:
            f.write(new)
        print("tools/s573_stage.py: table regenerated")
    else:
        print("tools/s573_stage.py: table already up to date")


if __name__ == "__main__":
    main()
