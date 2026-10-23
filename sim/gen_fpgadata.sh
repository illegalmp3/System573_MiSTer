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
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/fpgadata"; mkdir -p "$OUT"
SRC=""
for c in "${S573IN1:-}/data/fpga.bit" "$ROOT/../573in1/data/fpga.bit"; do
  [ -f "$c" ] && { SRC="$c"; break; }
done
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
