#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# stage_zs01_u1.py - extract a ZS01 security-cassette dump from a MAME romset and
# emit the PADDED .u1 the core expects, with structural verification.
#
# WHY THIS EXISTS (2026-09-13): ddrusa's padded .u1 was produced by an ad-hoc
# command and written straight to the games volume. Nothing in the tree could
# reproduce or check it, and the failure mode it guards is SILENT:
#
#   emu.sv infers the cassette type from the .u1 SIZE alone
#     (sec_eep_max >= 560 -> ZS01 type 2; >= 256 -> X76F041; else X76F100)
#
# so a .u1 left at its raw 140 bytes selects an X76F100, holds the ZS01's cs
# de-asserted, and the game reads a chip that can never carry its game code.
# On screen that is "cassette does not match this game" -- indistinguishable
# from a protocol or key bug, which is what makes it expensive.
#
# ZS01 IMAGE LAYOUT (MAME zs01.cpp nvram order; 140 bytes total):
#   [  0:  4] response-to-reset : 5a 53 00 01   (constant; RTL drops these)
#   [  4: 12] command key (8)   : the fixed PIC key, same on every cartridge
#   [ 12: 20] data key    (8)   : PER-CARTRIDGE
#   [ 20: 28] config regs (8)
#   [ 28:140] 112 data bytes    : plaintext; carries the game code + region
#
# The core pads to 4116 B (the gtrfrk5m dump width, and what the AW=13 loader and
# zs01.v expect). zs01.v drops every byte at addr >= 140, so the padding is inert.
# -----------------------------------------------------------------------------
import argparse, sys, zipfile

PAD_TO   = 4116
RAW_LEN  = 140
RTR      = bytes([0x5a, 0x53, 0x00, 0x01])
# The command key is a fixed PIC key shared by all ZS01 cartridges. zs01.v carries
# it as the COMMAND_KEY default, so a dump that disagrees is the wrong chip.
CMD_KEY  = bytes([0xed, 0x68, 0x50, 0x4b, 0xc6, 0x44, 0x48, 0x3e])
TYPE_ZS01_MIN = 560

def die(m):
    print("FAIL: " + m, file=sys.stderr); sys.exit(1)

def verify(u1, ds=None):
    ok = True
    if len(u1) != RAW_LEN:
        die("raw image is %d bytes, expected %d" % (len(u1), RAW_LEN))
    if u1[0:4] != RTR:
        die("no ZS01 response-to-reset at [0:4]: got %s, expected %s"
            % (u1[0:4].hex(), RTR.hex()))
    print("  RtR        [0:4]   %s  ok" % u1[0:4].hex())
    if u1[4:12] != CMD_KEY:
        print("  command key MISMATCH: %s (expected the fixed PIC key %s)"
              % (u1[4:12].hex(), CMD_KEY.hex()))
        ok = False
    else:
        print("  cmd key    [4:12]  %s  ok (matches zs01.v COMMAND_KEY)" % u1[4:12].hex())
    print("  data key   [12:20] %s  (per-cartridge)" % u1[12:20].hex())
    print("  config     [20:28] %s" % u1[20:28].hex())
    data = u1[28:140]
    # The game code sits in plaintext at the head of the data region.
    code = data[0:8].rstrip(b"\x00")
    printable = bytes(c if 32 <= c < 127 else 46 for c in data[0:16])
    print("  data       [28:140] 112 B, head: %r" % printable.decode("ascii"))
    if code:
        print("  game code  %r" % code.decode("ascii", "replace"))
    # A genuine cassette carries its DS2401 serial, byte-reversed, in the data region.
    if ds and len(ds) == 8:
        rev = bytes(reversed(ds))
        at = data.find(rev)
        if at >= 0:
            print("  DS2401     %s found byte-reversed at data[%d]  ok" % (ds.hex(), at))
        else:
            print("  DS2401     %s NOT found in the data region (dump pair may be mismatched)" % ds.hex())
            ok = False
    return ok

def main():
    ap = argparse.ArgumentParser(description="Stage a padded ZS01 .u1 from a MAME romset zip.")
    ap.add_argument("zip", help="MAME romset zip (e.g. dumps/mame573/ddrusa.zip)")
    ap.add_argument("-o", "--out", help="output .u1 path (padded). Omit to verify only.")
    ap.add_argument("--u1", help="member name of the ZS01 dump (default: the only 140-byte member)")
    ap.add_argument("--u6", help="member name of the DS2401 dump (default: the only 8-byte member named *.u6)")
    ap.add_argument("--check", help="verify an EXISTING staged .u1 instead of writing one")
    a = ap.parse_args()

    with zipfile.ZipFile(a.zip) as z:
        names = z.namelist()
        u1n = a.u1 or next((n for n in names if z.getinfo(n).file_size == RAW_LEN), None)
        if not u1n: die("no %d-byte member in %s (members: %s)" % (RAW_LEN, a.zip, names))
        u6n = a.u6 or next((n for n in names if n.lower().endswith(".u6") and z.getinfo(n).file_size == 8), None)
        u1 = z.read(u1n)
        ds = z.read(u6n) if u6n else None
    print("source: %s :: %s (%d B)%s" % (a.zip, u1n, len(u1), (" + %s" % u6n) if u6n else ""))
    ok = verify(u1, ds)

    if a.check:
        cur = open(a.check, "rb").read()
        print("\nstaged file: %s" % a.check)
        print("  size %d B -> emu.sv infers %s" % (
            len(cur),
            "ZS01 (type 2)" if len(cur) - 1 >= TYPE_ZS01_MIN else
            "X76F041 (type 1) -- WRONG" if len(cur) - 1 >= 256 else
            "X76F100 (type 0) -- WRONG"))
        if len(cur) - 1 < TYPE_ZS01_MIN:
            die("staged .u1 is too small: the core will NOT instantiate the ZS01. Re-stage with -o.")
        if cur[:RAW_LEN] != u1:
            die("staged .u1's first %d bytes do NOT match the dump." % RAW_LEN)
        if any(cur[RAW_LEN:]):
            print("  WARNING: padding past byte %d is not all zero" % RAW_LEN)
        print("  first %d bytes match the dump, padding inert  ok" % RAW_LEN)
        print("\nOK: staged image is correct.")
        return 0 if ok else 1

    if a.out:
        out = u1 + bytes(PAD_TO - RAW_LEN)
        assert len(out) == PAD_TO
        with open(a.out, "wb") as f: f.write(out)
        print("\nwrote %s (%d B) -> emu.sv infers ZS01 (type 2)" % (a.out, len(out)))
    else:
        print("\n(verify only; pass -o PATH to write the padded .u1)")
    return 0 if ok else 1

sys.exit(main())
