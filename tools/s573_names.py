#!/usr/bin/env python3
"""
s573_names.py - the launcher (.mgl) file name for a System 573 romset:

    <MAME title without its version code> (<region>, <year>).mgl
    e.g. ddr3mj -> "Dance Dance Revolution 3rd Mix (Japan, 1999).mgl"

Everything comes from the romset's GAME() line in dumps/mame573/ksys573.cpp:
the year is GAME()'s year field, the title is its description with the trailing
version-code parenthetical removed ("(GN887 VER. JAA)", "(GCA37JAA)"), and the
region is the FIRST letter of the version code (VER. JAA -> J). Where two sets
would get the same name, both also carry their version code ("..., Ver. JCA)").

Region letters, as Konami's codes are labelled in MAME's own descriptions: J =
Japan, A = Asia, E = Europe ("Euro"), U = USA ("US") -- e.g. G.I. Joe "(Japan,
JAA)" / "(US, UAA)" / "(Asia, AA)", Midnight Run "(EAA, Euro ...)"; and K = Korea,
which ksys573.cpp states itself: ddr3mka "Ver.Korea (GN887 VER. KAA)", ddr3mk
"Ver.Korea2 (... VER. KBA)".

Rename mode (no other effect): renames <set>.mgl, <set>_console.mgl and
<set>_install.mgl in DIR to their full names ("_install" keeps an " [Install]"
suffix; "_console" is the play launcher and gets none). Files already renamed, and
anything that is not a known romset's launcher, are left alone.

    python3 tools/s573_names.py ddr3mj            # print the name
    python3 tools/s573_names.py --rename mgl      # rename launchers in mgl/
    python3 tools/s573_names.py --rename mgl -n   # show what would be renamed
"""
import argparse, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRIVER = os.path.join(ROOT, "dumps", "mame573", "ksys573.cpp")

REGION = {"J": "Japan", "A": "Asia", "E": "Europe", "U": "USA", "K": "Korea"}
# characters FAT/exFAT (the MiSTer SD card) cannot hold in a file name
BAD = re.compile(r'[\\/:*?"<>|]')

_games = None
def games(driver=DRIVER):
    global _games
    if _games is None:
        src = open(driver, encoding="utf-8", errors="replace").read()
        _games = {m.group(2): (int(m.group(1)), m.group(3)) for m in re.finditer(
            r'^GAME\(\s*(\d{4}),\s*(\w+),\s*\w+,\s*\w+,\s*\w+,\s*\w+,\s*\w+,\s*ROT\d+,'
            r'\s*"Konami",\s*"([^"]+)"', src, re.M)}
    return _games

def _parts(romset):
    """(title, region, year, version code) from a romset's GAME() line."""
    g = games().get(romset)
    if not g:
        sys.exit(f"{romset}: no GAME() line in {DRIVER}")
    year, desc = g
    m = re.search(r'\s*\(([^()]*)\)\s*$', desc)
    if not m:
        sys.exit(f"{romset}: description has no version-code parenthetical: {desc!r}")
    code = m.group(1)
    v = re.search(r'VER\.\s*(([A-Z])[A-Z]{1,2})\b', code) or \
        re.search(r'^G[A-Z*]{1,2}\d{2}(([A-Z])[A-Z]{2})$', code)          # "GCA37JAA"
    if not v or v.group(2) not in REGION:
        sys.exit(f"{romset}: no known region letter in version code {code!r}")
    return desc[:m.start()].strip(), REGION[v.group(2)], year, v.group(1)

_base_count = None
def full_name(romset):
    """'Title (Region, Year)' for a romset, from its GAME() line. Where two sets in
    the driver would get the same name (dsfdct VER. JCA / dsfdcta VER. JAA, both
    Japan 1999), each gets its version code too: 'Title (Region, Year, Ver. JCA)'."""
    global _base_count
    if _base_count is None:
        _base_count = {}
        for r in games():
            try:
                t, reg, y, _ = _parts(r)
            except SystemExit:
                continue
            k = (t, reg, y)
            _base_count[k] = _base_count.get(k, 0) + 1
    title, region, year, code = _parts(romset)
    if _base_count.get((title, region, year), 0) > 1:
        name = f"{title} ({region}, {year}, Ver. {code})"
    else:
        name = f"{title} ({region}, {year})"
    if BAD.search(name):
        sys.exit(f"{romset}: {name!r} has a character the SD card cannot store")
    return name

def launcher_file(romset, install=False):
    return full_name(romset) + (" [Install]" if install else "") + ".mgl"

def rename_plan(d):
    plan = []
    for f in sorted(os.listdir(d)):
        m = re.fullmatch(r'(\w+?)(_console|_install)?\.mgl', f)
        if not m or m.group(1) not in games():
            continue
        new = launcher_file(m.group(1), install=(m.group(2) == "_install"))
        if new != f:
            plan.append((f, new))
    news = [n for _, n in plan]
    dup = {n for n in news if news.count(n) > 1 or os.path.exists(os.path.join(d, n))}
    if dup:
        sys.exit("name collision: " + ", ".join(sorted(dup)))
    return plan

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("romset", nargs="*")
    ap.add_argument("--rename", metavar="DIR")
    ap.add_argument("-n", "--dry-run", action="store_true")
    a = ap.parse_args()
    for r in a.romset:
        print(f"{r}\t{launcher_file(r)}")
    if a.rename:
        for old, new in rename_plan(a.rename):
            print(f"{old}  ->  {new}")
            if not a.dry_run:
                os.rename(os.path.join(a.rename, old), os.path.join(a.rename, new))
