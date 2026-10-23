#!/usr/bin/env bash
# Generate the Digital I/O bitstream $readmemh fixture for tb_k573dio_cpld.v from a
# 573in1 checkout (https://github.com/spicyjpeg/573in1, data/fpga.bit -- 573in1's own
# open bitstream, not a Konami one). The fixture is the RAW configuration data (the
# .bit 'e' tag payload, MSB-first bytes exactly as loadDigitalIOBitstream hands them
# to _writeBitstreamMSB), one hex byte per line:
#
#   sim/fpgadata/fpga_573in1_raw.hex
#
# Source: $S573IN1/data/fpga.bit, else ../../573in1/data/fpga.bit next to this repo.
# If neither is present this exits 0 WITHOUT writing the fixture -- the bench then
# runs its synthetic-stream cases only.
#
# Also (optional): a KONAMI bitstream, found by the SHA-1 list in psx-spx
# "Expansion I/O Boards" inside any dumps/mame573/**/*PSX.EXE (e.g. the ddr4m
# boot loader, which embeds the 3rdMIX image at file offset 0x414a0), written as
#   sim/fpgadata/fpga_konami_lsb.hex   41337 bytes, stored LSB-first as Konami does
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/fpgadata"; mkdir -p "$OUT"
SRC=""
for c in "${S573IN1:-}/data/fpga.bit" "$ROOT/../573in1/data/fpga.bit"; do
  [ -f "$c" ] && { SRC="$c"; break; }
done
python3 -I - "$ROOT/dumps/mame573" "$OUT/fpga_konami_lsb.hex" <<'PY' || true
import sys, os, hashlib
KNOWN = {'32d455a25eb26fe4e4b577cb0f0e3bebd0f82959', 'a53b8906de95c34b6e3f053bd7488c888bc904b6',
         '5d27c84e812f71401f940621f79c5c6114192895', '450b12627b7eacd3ea3f8b0b7a16589a13010c41',
         '53d0c1e3f6ae042d7d45ce889b79a12f1be5eabd'}
for root, _, files in os.walk(sys.argv[1]):
    for f in files:
        if not f.upper().endswith('PSX.EXE'): continue
        d = open(os.path.join(root, f), 'rb').read()
        i = d.find(b'\xff\x04')
        while i >= 0:
            blk = d[i:i + 41337]
            if len(blk) == 41337 and hashlib.sha1(blk).hexdigest() in KNOWN:
                open(sys.argv[2], 'w').write(''.join('%02x\n' % b for b in blk))
                print("gen_fpgadata: Konami bitstream %s from %s @0x%x" % (hashlib.sha1(blk).hexdigest()[:12], f, i))
                sys.exit(0)
            i = d.find(b'\xff\x04', i + 1)
PY
[ -n "$SRC" ] || { echo "gen_fpgadata: no 573in1 fpga.bit found; skipping"; exit 0; }
python3 -I - "$SRC" "$OUT/fpga_573in1_raw.hex" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
p = ((d[0] << 8) | d[1]) + 4          # same walk as 573in1 io.cpp loadDigitalIOBitstream
while p < len(d):
    t = d[p]
    if t == ord('e'):
        n = int.from_bytes(d[p+1:p+5], 'big'); raw = d[p+5:p+5+n]; break
    p += 3 + ((d[p+1] << 8) | d[p+2])
else:
    sys.exit("no data tag")
open(sys.argv[2], 'w').write(''.join('%02x\n' % b for b in raw))
print("gen_fpgadata: %d bytes from %s" % (len(raw), sys.argv[1]))
PY
