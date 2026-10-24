#!/usr/bin/env bash
# psx_patches/0033 equivalence: pinned ascal.vhd vs the patched psx/sys/ascal.vhd.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
grep -q "o_vcpt_pre3_last" "$ROOT/psx/sys/ascal.vhd" || { echo "psx/sys/ascal.vhd: 0033 not applied"; exit 1; }
# Sim-only, applied identically to BOTH copies: ascal relies on 4-bit wrap of
# `natural RANGE 0 TO 15` counters (o_off-1, o_pshift-1 at 0 -> 15 in the fitted
# logic), which GHDL range-checks. Make the wrap explicit.
simfix() { tr -d '\r' | sed -e 's/o_pshift<=o_off(0) -1;/o_pshift<=(o_off(0)+15) MOD 16;/' \
                             -e 's/o_pshift<=o_pshift-1;/o_pshift<=(o_pshift+15) MOD 16;/' \
                             -e 's/o_ihsizem<=o_ihsize + o_off(0) - 2;/o_ihsizem<=(o_ihsize + o_off(0) + 4094) MOD 4096;/'; }
git -C "$ROOT/psx" show HEAD:sys/ascal.vhd | simfix \
  | sed -e 's/^ENTITY ascal IS/ENTITY ascal_ref IS/' -e 's/^END ENTITY ascal;/END ENTITY ascal_ref;/' \
        -e 's/^ARCHITECTURE rtl OF ascal IS/ARCHITECTURE rtl OF ascal_ref IS/' > "$W/ascal_ref.vhd"
simfix < "$ROOT/psx/sys/ascal.vhd" > "$W/ascal_dut.vhd"
# MUTATE=1: break the DUT on purpose (end-of-frame one line early) -- the bench must FAIL
[ "${MUTATE:-0}" = 1 ] && sed -i 's/o_vcpt_pre3_last<=(o_vcpt_pre3+1>=o_vtotal);/o_vcpt_pre3_last<=(o_vcpt_pre3+2>=o_vtotal);/' "$W/ascal_dut.vhd"
grep -q "ENTITY ascal_ref IS" "$W/ascal_ref.vhd"
# the DUT must be exactly the pinned file + psx_patches/0033
mkdir -p "$W/chk/sys"; git -C "$ROOT/psx" show HEAD:sys/ascal.vhd > "$W/chk/sys/ascal.vhd"
( cd "$W/chk" && git apply -p1 "$ROOT/psx_patches/0033-s573-ascal-vcpt-pipeline.patch" )
cmp "$W/chk/sys/ascal.vhd" "$ROOT/psx/sys/ascal.vhd" && echo "psx/sys/ascal.vhd == pinned + 0033"
cd "$W"
G="ghdl"; O="--std=08 -frelaxed --ieee=synopsys"
$G -a $O ascal_ref.vhd
$G -a $O ascal_dut.vhd
$G -a $O "$ROOT/sim/ascal_equiv/tb_ascal_vcpt.vhd"
$G -e $O tb_ascal_vcpt
$G -r $O tb_ascal_vcpt --assert-level=error --stop-time=20ms 2>&1 | tee run.log | grep -v "NUMERIC_STD\|metavalue\|^\s*$" | tail -40
grep -q "PASS" run.log
