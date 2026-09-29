#!/usr/bin/env python3
"""
make_cas_pack.py - build the .cas CASSETTE PACK for a two-cassette System 573 title.

    python3 tools/make_cas_pack.py dumps/mame573/ddr4m.zip \
        --game-u6 gca33aa.u6 --install-u1 gea33aa.u1 --install-u6 gea33aa.u6 -o ddr4m.cas

WHY. ksys573.cpp (header Note 3; the cassxzi / cassyyi machine configs) gives these
titles two security cassettes for one physical slot -- an INSTALL cassette while
installing from CD, the GAME cassette afterwards. The core holds both (rtl/
s573_seccart.v) and the OSD "573 Cassette" option says which is in the slot, so one
launcher replaces the old install/console pair. MiSTer Main parses at most six .mgl
items and the launchers use all six, so the second cassette rides in the index-5
file that is otherwise the 8-byte .u6. The layout (rtl/s573_cass_pack.v):

    [0:7]    game cassette DS2401 serial   -- the .u6 exactly, so the first 8 bytes
                                              are what a plain .u6 launch would send
    [8:15]   install cassette DS2401 serial  (cassette:install:id)
    [16:..]  install cassette EEPROM image   (cassette:install:eeprom, AS DUMPED:
                                              548 B X76F041 / 132 B X76F100)

The core infers the install chip from the file SIZE (the same rule emu.sv uses for
the game .u1): 16+548 = 564 B -> X76F041, 16+132 = 148 B -> X76F100. The sizes are
checked here against the driver's ROM_REGION lengths so a truncated or wrong dump
cannot masquerade as the other chip. Note the ZS01 is never an install cassette in
the driver (option_add("install", ...) is only ever _XI or _YI), so no padding.
"""
import argparse, sys, zipfile

X76F041_LEN = 0x224   # 548: ksys573.cpp ROM_REGION( 0x0000224, "cassette:install:eeprom" )
X76F100_LEN = 0x084   # 132: ksys573.cpp ROM_REGION( 0x0000084, "cassette:install:eeprom" )
SER_LEN     = 8


def die(m):
    print("FAIL: " + m, file=sys.stderr)
    sys.exit(1)


def build_pack(game_u6: bytes, install_u6: bytes, install_u1: bytes) -> bytes:
    if len(game_u6) != SER_LEN:
        die(f"game .u6 is {len(game_u6)} B, want {SER_LEN}")
    if len(install_u6) != SER_LEN:
        die(f"install .u6 is {len(install_u6)} B, want {SER_LEN}")
    if len(install_u1) not in (X76F041_LEN, X76F100_LEN):
        die(f"install .u1 is {len(install_u1)} B; the driver's install cassettes are "
            f"{X76F041_LEN} B (X76F041) or {X76F100_LEN} B (X76F100)")
    return game_u6 + install_u6 + install_u1


def describe(pack: bytes) -> str:
    n = len(pack) - 16
    chip = {X76F041_LEN: "X76F041", X76F100_LEN: "X76F100"}.get(n, "?")
    return f"{len(pack)} B = game.u6 8 + install.u6 8 + install.u1 {n} ({chip})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("zip", help="MAME romset zip holding the three files")
    ap.add_argument("--game-u6", required=True)
    ap.add_argument("--install-u1", required=True)
    ap.add_argument("--install-u6", required=True)
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    with zipfile.ZipFile(a.zip) as z:
        names = set(z.namelist())
        for n in (a.game_u6, a.install_u1, a.install_u6):
            if n not in names:
                die(f"{n} not in {a.zip}")
        pack = build_pack(z.read(a.game_u6), z.read(a.install_u6), z.read(a.install_u1))
    with open(a.out, "wb") as f:
        f.write(pack)
        f.flush()
    print(f"   {a.out} <- {a.game_u6} + {a.install_u6} + {a.install_u1}: {describe(pack)}")


if __name__ == "__main__":
    main()
