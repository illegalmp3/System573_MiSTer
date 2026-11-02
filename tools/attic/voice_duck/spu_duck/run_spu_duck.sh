#!/bin/bash
# GHDL run of the patched spu.vhd (psx_patches 0035), from the worktree root via the job runner.
set -u
P=$(pwd)/psx; T=$(pwd)/sim/spu_duck; W=/root/ghdl_spu; rm -rf $W; mkdir -p $W; cd $W
F="--std=08 -frelaxed -fsynopsys --workdir=$W -P$W"
ghdl -a $F --work=altera_mf $T/altera_mf_stub.vhd || exit 1
ghdl -a $F --work=mem $P/sim/system/src/mem/RamMLAB.vhd $P/sim/system/src/mem/dpram.vhd $P/rtl/SyncFifo.vhd $P/rtl/SyncFifoFallThrough.vhd 2>&1 | grep -v "^$" | head -20
ghdl -a $F --work=psx $P/sim/system/src/mem/dpram.vhd $P/rtl/spu_ram.vhd $P/rtl/spu_gauss.vhd $P/rtl/spu.vhd 2>&1 | head -20
ghdl -a $F --work=work $T/tb_spu_duck.vhd 2>&1 | head
ghdl -e $F tb_spu_duck 2>&1 | head
date +%T; timeout 1200 ghdl -r $F tb_spu_duck -gDUCK_MODE=0 -gDUCK_VOICE=0 -gOUTFILE=$W/m00.txt --ieee-asserts=disable 2>&1 | grep -v "^$" | grep -E "v0:|n=|done|error" | head -60
nz=$(awk '$1 != 0' $W/m00.txt | wc -l); echo "reference run: $(wc -l < $W/m00.txt) samples, $nz non-zero"
if [ "$nz" -lt 50 ]; then echo "RESULT: FAIL (reference run is silent -- testbench, not the patch)"; exit 1; fi
for c in "1 0 m01" "2 0 m10" "3 0 m11" "3 5 other"; do
  set -- $c
  date +%T; timeout 1800 ghdl -r $F tb_spu_duck -gDUCK_MODE=$1 -gDUCK_VOICE=$2 -gOUTFILE=$W/$3.txt --ieee-asserts=disable 2>&1 | grep -v "^$" | tail -1
done
python3 - <<'PY'
import math
W='/root/ghdl_spu'
def rd(n): return [tuple(map(int,l.split())) for l in open(f'{W}/{n}.txt')]
base=rd('m00'); errs=0
rms=lambda v: math.sqrt(sum(a*a for a,_ in v)/len(v))
print('samples', len(base), 'rms m00', round(rms(base),1), 'nonzero', sum(1 for a,_ in base if a))
for name, div in (('other',1),('m01',2),('m10',4),('m11',None)):
    # tolerance: the voice is floored once by the shift and once more by the main
    # volume multiply (0x7FFE/0x8000), so against reference/div it may differ by < 2 LSB
    v=rd(name); bad=0; worst=0.0
    for (a,b),(c,d) in zip(base,v):
        if div is None: dv = max(abs(c), abs(d))
        else: dv = max(abs(c - a/div), abs(d - b/div))
        worst = max(worst, dv)
        bad += (dv >= 2) if div else (dv != 0)
    print(f'{name}: rms {rms(v):.1f} ratio {rms(v)/max(rms(base),1e-9):.4f} worst |diff| {worst:.2f} LSB, out of tolerance {bad}')
    errs += bad
if rms(base) < 100: print('FAIL: the reference run is silent'); errs += 1
print('RESULT:', 'PASS' if errs == 0 else f'FAIL ({errs})')
PY
