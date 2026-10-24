#!/usr/bin/env python3
"""Generate the MAS3507D gain tables for rtl/s573_mas_gain.v from MAME's own formula
(mas3507d.cpp, BSD-3):
    gain_to_db(v)         = round(20 * log10((0x100000 - v) / 0x80000))   (C round, double)
    gain_to_percentage(v) = v == 0 ? 0 : powf(10.0, (db + 6) / 20.0)      (float)
x = 0x100000 - v runs 1..0xFFFFF for v = 1..0xFFFFF; db(x) is monotonic in x, so the
RTL finds db by scanning thresholds T[i] = the smallest x whose db is 6 - i.
Also writes a full expected table (v -> Q12) for the testbench sweep."""
import math, struct, sys

def c_round(a):                      # C round(): half away from zero
    return math.floor(a + 0.5) if a >= 0 else -math.floor(-a + 0.5)

def db_of(v):
    return int(c_round(20.0 * math.log10((0x100000 - v) / 0x80000)))

def f32(a):
    return struct.unpack("f", struct.pack("f", a))[0]

def q12_of(v):
    if v == 0:
        return 0
    pct = f32(math.pow(10.0, (db_of(v) + 6) / 20.0))     # powf: float result
    return int(math.floor(pct * 4096.0 + 0.5))

# thresholds: walk x upward, record the first x of each db
first = {}
for x in range(1, 0x100000):
    d = db_of(0x100000 - x)
    if d not in first:
        first[d] = x
dbs = sorted(first, reverse=True)            # 6, 5, ..., -114
# (db is not contiguous at the very bottom: x=1 -> -114, x=2 -> -108; the scan only needs the steps that exist)
# monotonic check
prev = None
for x in range(1, 0x100000):
    d = db_of(0x100000 - x)
    assert prev is None or d >= prev; prev = d
rows = []
for i, d in enumerate(dbs):
    v = 0x100000 - first[d]
    rows.append((i, d, first[d], q12_of(v)))
print(f"{len(rows)} entries, db {dbs[0]}..{dbs[-1]}", file=sys.stderr)

# Embed the table in rtl/s573_mas_gain.v between its GENERATED markers (no include
# file: nothing for Quartus or iverilog to go looking for).
target = sys.argv[1] if len(sys.argv) > 1 else "rtl/s573_mas_gain.v"
lines = ["    // ---- BEGIN GENERATED gain table (tools/gen_mas_gain_rom.py, MAME mas3507d.cpp",
         "    // gain_to_db / gain_to_percentage; do not edit). Entries run from +6 dB down;",
         "    // the gain is the FIRST entry with x >= threshold, x = 0x100000 - v (the dB",
         "    // steps are not contiguous at the very bottom). {threshold x 21b, Q12 gain 15b}",
         f"    localparam integer GAIN_N = {len(rows)};",
         "    function [35:0] gain_rom;",
         "        input [6:0] i;",
         "        begin",
         "            case (i)"]
for i, d, x, q in rows:
    lines.append(f"            7'd{i}: gain_rom = {{21'd{x}, 15'd{q}}};   // {d:+d} dB")
lines += ["            default: gain_rom = {21'd1, 15'd0};", "            endcase", "        end",
          "    endfunction", "    // ---- END GENERATED gain table"]
src = open(target).read()
a = src.index("    // ---- BEGIN GENERATED gain table")
b = src.index("    // ---- END GENERATED gain table")
b = src.index("\n", b) + 1
new = src[:a] + "\n".join(lines) + "\n" + src[b:]
if new != src:
    open(target, "w").write(new)
    print(f"{target}: gain table written", file=sys.stderr)
if len(sys.argv) > 2:                      # expected v -> q12 for every v (testbench)
    with open(sys.argv[2], "w") as f:
        for v in range(0x100000):
            f.write("%05x %04x\n" % (v, q12_of(v)))
