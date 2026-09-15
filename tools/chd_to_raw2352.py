#!/usr/bin/env python3
"""chd_to_raw2352.py -- convert a MODE1/2048 CD CHD into cue + raw 2352 .bin.

    tools/chd_to_raw2352.py dumps/mame573/910jca02.chd -o "/Volumes/.../dsfdct"
    tools/chd_to_raw2352.py dumps/mame573/936eaa.chd --verify <proven dsem.bin>

WHY: s573_cdimg serves 2352-byte raw sectors. A MAME CHD whose track metadata says
TYPE:MODE1 SUBTYPE:NONE has NO sync/header stored -- the 2048 user bytes sit at
offset 0 of the 2448-byte frame -- so it cannot be served directly and must be
re-wrapped. TYPE:MODE1_RAW discs already carry sync+header at offset 16 and are
used as-is. (dsem/936eaa and dsfdct/910jca02 are the only two 2048 discs here.)

    MODE1/2048   frame = [user 2048][subcode 96]                    offset 0
    MODE1_RAW    frame = [sync 12][hdr 3][mode 1][user 2048][edc/ecc 288][sub 96]

THE RECIPE IS NOT INVENTED -- it is read off dsem.bin, which is proven on hardware:
sync 00 FF*10 00, a BCD MSF header for LBA+150, mode byte 0x01, the 2048 user bytes,
then EDC and ECC left as ZEROS. Nothing in the core checks EDC/ECC, and dsem has
been playing with them zeroed since 2026-09-13. `--verify` re-derives a known .bin
and byte-compares, so that claim is testable rather than remembered.
"""
import argparse, os, struct, sys

SUB = 96
FRAME = 2448
USER = 2048
RAW = 2352
SYNC = b"\x00" + b"\xff" * 10 + b"\x00"


def load_chd_class():
    here = os.path.dirname(os.path.abspath(__file__))
    src = open(os.path.join(here, "chd_extract.py")).read()
    ns = {}
    exec(src.split("# ---------------- minimal ISO9660")[0], ns)
    return ns["Chd"]


def track_meta(path):
    d = open(path, "rb").read()
    import re
    m = re.search(rb"TRACK:\s*(\d+)\s+TYPE:\s*([A-Z0-9_]+)\s+SUBTYPE:\s*([A-Z_]+)\s+FRAMES:\s*(\d+)", d)
    if not m:
        sys.exit(f"{path}: no CD track metadata found")
    return m.group(2).decode(), m.group(3).decode(), int(m.group(4))


def bcd(n):
    return ((n // 10) << 4) | (n % 10)


def msf_header(lba):
    a = lba + 150
    return bytes((bcd(a // (60 * 75)), bcd((a // 75) % 60), bcd(a % 75)))


def frame_user(chd, lba, offset):
    pos = lba * FRAME + offset
    h, o = divmod(pos, chd.hunkbytes)
    buf = chd.hunk(h)[o:o + USER]
    while len(buf) < USER:
        h += 1
        buf += chd.hunk(h)[:USER - len(buf)]
    return buf


def convert(chd_path, frames=None):
    Chd = load_chd_class()
    ttype, sub, nframes = track_meta(chd_path)
    if ttype != "MODE1":
        sys.exit(f"{chd_path}: TYPE:{ttype} -- only MODE1/2048 needs converting "
                 f"({'MODE1_RAW is used directly' if ttype=='MODE1_RAW' else 'unsupported'})")
    c = Chd(chd_path)
    n = frames or nframes
    out = bytearray()
    for lba in range(n):
        out += SYNC + msf_header(lba) + b"\x01" + frame_user(c, lba, 0) + bytes(288)
    return bytes(out), n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("chd")
    ap.add_argument("-o", "--out", help="output stem: writes <stem>.bin and <stem>.cue")
    ap.add_argument("--verify", metavar="BIN", help="byte-compare against a known-good .bin")
    a = ap.parse_args()

    ttype, sub, nframes = track_meta(a.chd)
    print(f"  {os.path.basename(a.chd)}: TYPE:{ttype} SUBTYPE:{sub} FRAMES:{nframes}")
    data, n = convert(a.chd)
    print(f"  built {n} raw sectors = {len(data):,} bytes")

    if a.verify:
        ref = open(a.verify, "rb").read()
        m = min(len(ref), len(data))
        ok = ref[:m] == data[:m]
        print(f"  verify vs {os.path.basename(a.verify)}: first {m//RAW} sectors "
              f"{'IDENTICAL' if ok else 'DIFFER'}")
        if not ok:
            for i in range(0, m, RAW):
                if ref[i:i+RAW] != data[i:i+RAW]:
                    print(f"    first differing sector: LBA {i//RAW}")
                    print(f"      ref {ref[i:i+20].hex(' ')}")
                    print(f"      got {data[i:i+20].hex(' ')}")
                    break
            return 1
        if len(ref) != len(data):
            print(f"  (the reference is {abs(len(ref)-len(data))//RAW} sector(s) "
                  f"{'longer' if len(ref)>len(data) else 'shorter'}; content matches where they overlap)")
        return 0

    if not a.out:
        print("  (no -o given, nothing written)")
        return 0
    stem = a.out[:-4] if a.out.endswith(".bin") else a.out
    open(stem + ".bin", "wb").write(data)
    base = os.path.basename(stem)
    open(stem + ".cue", "w").write(
        f'FILE "{base}.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
    print(f"  wrote {base}.bin ({len(data):,} B) + {base}.cue")
    return 0


if __name__ == "__main__":
    sys.exit(main())
