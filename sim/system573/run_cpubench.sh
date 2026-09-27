#!/usr/bin/env bash
# =============================================================================
# run_cpubench.sh -- measure the core's cached-fetch cost in the NVC full-system
# harness with the tools/cpubench_rom.py probe ROM (NOT the Konami BIOS).
#
#   sim/system573/run_cpubench.sh                 # psx/rtl as checked out
#   RTL_DIR=local/psx_rtl_no0004 sim/system573/run_cpubench.sh   # alternative cpu.vhd etc.
#   TAG=no0004 ...                                # build dir suffix (keeps both runs)
#
# Why (2026-09-27): ddrextrm's DecDCTvlc runs at CPI ~3.3 on the cabinet; the suspect
# is psx_patches/0004 (forced i-cache miss on every 16-byte line crossing). The probe
# runs three loops that differ only in line crossings (see the ROM generator) and the
# tb's CPUBENCH tap stamps every taken branch with the clk1x cycle count. TURBO=0:
# realistic memory timing. Same build recipe as run_ram_mirror.sh.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PSX="$ROOT/psx"; MEMSRC="$PSX/sim/system/src/mem"; TBSRC="$PSX/sim/system/src/tb"
RTL="${RTL_DIR:-$PSX/rtl}"
case "$RTL" in /*) ;; *) RTL="$ROOT/$RTL" ;; esac
NVCDIR="$ROOT/sim/nvc"
TAG="${TAG:-}"
WD="$HERE/build_cpubench${TAG:+_$TAG}"
STOP_TIME="${1:-6ms}"
ITERS="${ITERS:-200}"

command -v nvc >/dev/null 2>&1 || { echo "error: nvc not found" >&2; exit 1; }
[ -f "$RTL/cpu.vhd" ] || { echo "error: no cpu.vhd in $RTL" >&2; exit 1; }
"$ROOT/tools/apply_psx_patches.sh" >/dev/null

rm -rf "$WD"; mkdir -p "$WD"; cd "$WD"
ROMINFO="$(python3 "$ROOT/tools/cpubench_rom.py" "$WD/s573_bios.bin" --iters "$ITERS")"
echo "$ROMINFO"
A=$(sed -n 's/.*A=\([0-9a-f]*\).*/\1/p' <<<"$ROMINFO"); B=$(sed -n 's/.*B=\([0-9a-f]*\).*/\1/p' <<<"$ROMINFO")
C=$(sed -n 's/.*C=\([0-9a-f]*\).*/\1/p' <<<"$ROMINFO"); D=$(sed -n 's/.*D=\([0-9a-f]*\).*/\1/p' <<<"$ROMINFO")
echo "RTL dir: $RTL"; md5sum "$RTL/cpu.vhd"

NVC="nvc --std=2008 --ieee-warnings=off --messages=compact"
analyze() { $NVC --work="$1:$WD/$1" -L "$WD" -a --relaxed "${@:2}"; }
NVC_MEM="-M 3g -H 6g"
echo "== analyzing altera_mf stub =="
analyze altera_mf "$NVCDIR/altera_mf_stub.vhd"
echo "== analyzing mem library =="
analyze mem "$MEMSRC/dpram.vhd" "$MEMSRC/RamMLAB.vhd" \
            "$RTL/SyncFifo.vhd" "$RTL/SyncFifoFallThrough.vhd" \
            "$RTL/SyncFifoFallThroughMLAB.vhd" "$RTL/SyncRam.vhd"
echo "== analyzing psx core library =="
analyze psx "$MEMSRC/dpram.vhd"
CORE=(export divider pGPU mul32u mul9s gpu_fillVram gpu_cpu2vram gpu_vram2vram \
  gpu_vram2cpu gpu_line gpu_rect gpu_poly gpu_pixelpipeline gpu_overlay gpu_dither \
  gpu_videoout_async gpu_videoout_sync gpu_crosshair justifier_sensor gpu_videoout gpu \
  irq pJoypad joypad_pad joypad_mem joypad timer dma exp2 pGTE gte_mac0 gte_mac123 \
  gte_UNRDivide gte mdec cd_xa_zigzag cd_xa cd_top memctrl sio spu_ram spu_gauss spu \
  datacache cpu memorymux memcard statemanager savestates cheats psx_top psx_mister)
files=(); for f in "${CORE[@]}"; do files+=("$RTL/$f.vhd"); done
analyze psx "${files[@]}"
echo "== analyzing tb library =="
analyze tb "$TBSRC/globals.vhd" "$TBSRC/sdram_model3x.vhd" \
           "$TBSRC/ddrram_model.vhd" "$TBSRC/framebuffer.vhd"
echo "== analyzing tb_system573 =="
analyze tb "$HERE/tb_system573.vhd"
echo "== elaborating (CPUBENCH=1 TURBO=0 BENCH_HALT=$D) =="
$NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -e tb_system573 --stats \
     -gCPUBENCH="'1'" -gTURBO="'0'" -gBENCH_HALT="x\"$D\""
echo "== running (stop-time=$STOP_TIME) =="
$NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -r tb_system573 --stats --stop-time="$STOP_TIME" || true
echo "== report =="
wc -l "$WD/bench_trace.log"
python3 "$ROOT/tools/cpubench_report.py" "$WD/bench_trace.log" "A=$A" "B=$B" "C=$C"
