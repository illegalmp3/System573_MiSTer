#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# build-hps-mp3.sh - build the forked Main_MiSTer ARM binary carrying the 573
#                    HPS MP3 service (support/s573/).
#
# Runs in a Linux environment with the project dir mounted: originally the
# aarch64 Ubuntu VM on the Mac; since 2026-09-18 the WSL Ubuntu on the Windows PC
# (x86_64), driven by tools/win/jobrunner.ps1 with DOCS=/mnt/c/Users/ricky/Documents.
# ARM publishes both aarch64- and x86_64-hosted builds of arm-none-linux-gnueabihf,
# which is the triple Main's own Makefile expects. tools/wsl/fetch-firmware-inputs.sh
# downloads the three inputs below into $DOCS when the environment has network.
#
# Three inputs must be present in $DOCS:
#   Main_MiSTer*.tar.gz
#   gcc-arm-10.2-2020.11-<host>-arm-none-linux-gnueabihf.tar.xz  (host = the
#                                                                 machine running this)
#   minimp3.h
#
# THE TOOLCHAIN VERSION IS NOT A FREE CHOICE. Main's Makefile comment says
# "using gcc version 10.2.1" and its devcontainer pins gcc-arm-10.2-2020.11, and
# that pin is a RUNTIME ABI pin, not a warnings preference. Building with ARM's
# 13.3 produced a perfectly valid binary that required GLIBC_2.38
# (__isoc23_sscanf/strtol), GLIBC_2.34 (pthread_create, shm_open,
# __libc_start_main -- glibc folded pthreads into libc) and GLIBC_2.35 (hypotf).
# MiSTer's rootfs has none of those, so the loader refuses the binary before
# main() and the console simply never comes up. Measured on hardware 2026-09-11.
# 10.2's sysroot is glibc 2.31 and the resulting binary tops out at GLIBC_2.28
# with old-style librt/libpthread linkage, which is what upstream ships.
#
# Stages:  setup | graft | build | deploy | all
# -----------------------------------------------------------------------------
set -euo pipefail

DOCS="${DOCS:-$HOME/mnt/Documents}"
PROJ="${PROJ:-$DOCS/System573_MiSTer}"
WORK="${WORK:-$HOME/s573build}"
# The extraction target is VERSION-NAMED on purpose. $WORK/toolchain holds a 13.3
# toolchain from an earlier experiment, and pointing TC there is exactly the
# mistake this file's header is about: it builds a valid ARM binary the console
# cannot load. Name the directory after the pin, and verify the compiler below.
TC="${TC:-$WORK/tc102}"
MAIN="$WORK/Main_MiSTer"
SD="${SD:-$HOME/mnt/MiSTer_Data}"

say()  { printf '\n== %s\n' "$*"; }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

need_input() {
  local pat="$1" desc="$2"
  local hit
  hit="$(ls -1 "$DOCS"/$pat 2>/dev/null | head -1 || true)"
  [ -n "$hit" ] || die "missing input: $desc (expected $DOCS/$pat)"
  printf '%s' "$hit"
}

stage_setup() {
  mkdir -p "$WORK"

  local tctar srctar mp3h
  tctar="$(need_input "gcc-arm-10.2-*-$(uname -m)-arm-none-linux-gnueabihf.tar.xz" 'ARM toolchain')"
  srctar="$(need_input 'Main_MiSTer*.tar.gz' 'Main_MiSTer source')"
  mp3h="$(need_input 'minimp3.h' 'minimp3 single header')"

  if [ ! -x "$TC/bin/arm-none-linux-gnueabihf-gcc" ]; then
    say "extracting the toolchain (~2 GB, one time)"
    rm -rf "$TC.tmp"; mkdir -p "$TC.tmp"
    tar -xJf "$tctar" -C "$TC.tmp" --strip-components=1
    rm -rf "$TC"; mv "$TC.tmp" "$TC"
  else
    say "toolchain already extracted"
  fi
  local tcver
  tcver="$("$TC/bin/arm-none-linux-gnueabihf-gcc" --version | head -1)"
  printf '%s\n' "$tcver"
  # The pin is a RUNTIME ABI pin (see the header). Enforce it here rather than
  # letting the ABI gate catch it after a full build -- or, worse, letting a
  # differently-named toolchain directory decide which compiler runs.
  case "$tcver" in
    *" 10.2."*) : ;;
    *) die "toolchain at $TC is not 10.2 ($tcver).
Main pins gcc-arm-10.2-2020.11 and that pin is a runtime ABI pin: a 13.3 build
requires GLIBC_2.34/2.35/2.38, which MiSTer's rootfs does not have, so the
loader refuses the binary and the console never boots. Point TC at the 10.2
toolchain or delete $TC and re-run setup to extract it." ;;
  esac

  if [ ! -f "$MAIN/Makefile" ]; then
    say "extracting Main_MiSTer"
    rm -rf "$MAIN.tmp"; mkdir -p "$MAIN.tmp"
    tar -xzf "$srctar" -C "$MAIN.tmp" --strip-components=1
    rm -rf "$MAIN"; mv "$MAIN.tmp" "$MAIN"
  else
    say "Main_MiSTer already extracted"
  fi
  [ -f "$MAIN/user_io.cpp" ] || die "$MAIN does not look like Main_MiSTer (no user_io.cpp)"

  mkdir -p "$MAIN/lib/minimp3"
  cp -f "$mp3h" "$MAIN/lib/minimp3/minimp3.h"
  grep -q 'MINIMP3_MAX_SAMPLES_PER_FRAME' "$MAIN/lib/minimp3/minimp3.h" \
    || die "minimp3.h does not define MINIMP3_MAX_SAMPLES_PER_FRAME -- wrong file?"
  say "inputs OK"
}

stage_graft() {
  [ -f "$MAIN/Makefile" ] || die "run the setup stage first"
  say "grafting support/s573 into the Main tree"
  mkdir -p "$MAIN/support/s573"
  cp -f "$PROJ/support/s573/s573mp3.cpp" \
        "$PROJ/support/s573/s573mp3_core.c" "$PROJ/support/s573/s573mp3_core.h" \
        "$PROJ/support/s573/s573_descramble.c" "$PROJ/support/s573/s573_descramble.h" \
        "$MAIN/support/s573/"

  # The two touch points in Main. Both are discovered, never assumed: if the
  # upstream shape has moved, this fails loudly instead of building a binary
  # whose service is never called (which is exactly defect 1's failure mode).
  python3 - "$MAIN" <<'PYEOF'
import re, sys, os
main = sys.argv[1]

# ---- 1. the Makefile -------------------------------------------------------
# CPP_SRC already globs ./support/*/*.cpp, so s573mp3.cpp is picked up for free.
# C_SRC does NOT glob support/, so the two C files would be silently left out of
# the link -- which would present as undefined references, not as a quiet
# failure, but the assertion below is what guarantees that stays true.
p = os.path.join(main, 'Makefile')
s = open(p, encoding='utf-8', errors='surrogateescape').read()
if '$(wildcard ./support/*/*.cpp)' not in s:
    sys.exit('Makefile: CPP_SRC no longer globs ./support/*/*.cpp -- s573mp3.cpp '
             'would not be compiled. Refusing to guess.')
if 'support/*/*.c)' in s.replace('support/*/*.cpp)', ''):
    print('Makefile: already gathers support C sources')
else:
    m = re.search(r'^C_SRC\s*=.*?(?=\n\S|\n\n)', s, re.M | re.S)
    if not m:
        sys.exit('Makefile: could not find the C_SRC block')
    add = ('\n\n# Konami System 573 HPS MP3 service: CPP_SRC already globs\n'
           '# ./support/*/*.cpp, but C_SRC does not glob support/ -- s573mp3_core.c\n'
           '# and s573_descramble.c would be left out of the link.\n'
           'C_SRC += $(wildcard ./support/*/*.c)')
    s = s[:m.end()] + add + s[m.end():]
    open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
    print('Makefile: C_SRC += support/*/*.c added')

# ---- 2. the poll hook ------------------------------------------------------
# Placed beside psx_poll(): this core reports itself as "PSX", so is_psx() is
# true for it as well, and that call site is in the same poll section. The gate
# lives inside the service, NOT in a patch to user_io.cpp -- upstream put it
# here and the WORKING write-up names that as the untested boundary that kept a
# perfect unit from ever being invoked.
p = os.path.join(main, 'user_io.cpp')
s = open(p, encoding='utf-8', errors='surrogateescape').read()
if 's573mp3_poll' in s:
    print('user_io.cpp: hook already present')
else:
    m = re.search(r'^([ \t]*)if \(is_psx\(\)\) psx_poll\(\);[ \t]*$', s, re.M)
    if not m:
        sys.exit('user_io.cpp: could not find "if (is_psx()) psx_poll();" in '
                 'user_io_poll() -- refusing to guess where the hook goes')
    ind = m.group(1)
    ins = (m.group(0) + '\n' + ind +
           '// Konami System 573: HPS-side MP3 decode service. Core-name gated\n' + ind +
           '// inside -- this core reports itself as "PSX", so is_psx() is true too.\n' + ind +
           's573mp3_poll();')
    s = s[:m.start()] + ins + s[m.end():]
    incs = list(re.finditer(r'^#include[^\n]*\n', s, re.M))
    at = incs[-1].end() if incs else 0
    s = s[:at] + '\n/* support/s573/s573mp3.cpp */\nextern void s573mp3_poll(void);\n' + s[at:]
    open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
    print('user_io.cpp: hook inserted after psx_poll()')

# ---- 3. the CD read trace hook ---------------------------------------------
# Every block-device READ the fabric asks for passes the commented-out
# `//printf("SD RD (%llu,%d) on %d, WIDE=%d\n", ...)` in user_io_poll(), with
# lba/blksz/disk/blks in scope. The service counts them per second and logs a
# "reads RESUMED after N s" line, which is how a silent song loader (ddrs2k
# attract demo, 2026-09-12) is told apart from a starved one.
s = open(p, encoding='utf-8', errors='surrogateescape').read()
if 's573_cd_trace' in s:
    print('user_io.cpp: cd trace hook already present')
else:
    m = re.search(r'^([ \t]*)//printf\("SD RD \(%llu,%d\) on %d, WIDE=%d\\n", lba, blksz, disk, fio_size\);[ \t]*$', s, re.M)
    if not m:
        sys.exit('user_io.cpp: could not find the commented "SD RD" printf in the read path')
    ind = m.group(1)
    ins = m.group(0) + '\n' + ind + 's573_cd_trace(disk, lba, blks, blksz);   // System 573 CD read trace (gated inside)'
    s = s[:m.start()] + ins + s[m.end():]
    s = s.replace('extern void s573mp3_poll(void);\n',
                  'extern void s573mp3_poll(void);\nextern void s573_cd_trace(int disk, unsigned long long lba, int blks, int blksz);\n', 1)
    open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
    print('user_io.cpp: cd trace hook inserted')
PYEOF
  say "graft OK"
}

stage_build() {
  [ -x "$TC/bin/arm-none-linux-gnueabihf-gcc" ] || die "run the setup stage first"
  say "building (this is the first compile of s573mp3.cpp against Main's headers)"
  export PATH="$TC/bin:$PATH"
  make -C "$MAIN" -j"$(nproc)" 2>&1 | tail -60
  local out
  # Main has moved its link output before (bin/MiSTer today, ./MiSTer historically).
  # Search both rather than assume, and say which one was found -- a build that
  # "succeeded" while the script reads a stale binary from the other path is the
  # kind of null this project keeps getting bitten by.
  out=""
  for cand in "$MAIN/bin/MiSTer" "$MAIN/MiSTer"; do
    [ -f "$cand" ] && { out="$cand"; break; }
  done
  [ -n "$out" ] || die "no MiSTer binary produced (looked in $MAIN/bin/MiSTer and $MAIN/MiSTer)"
  say "link output: $out"
  file "$out"
  arm-none-linux-gnueabihf-strip -s "$out" || true
  ls -la "$out"
  strings -a "$out" | grep -c s573mp3 | sed 's/^/s573mp3 strings in the binary: /'
  # ABI GATE. A binary that demands a newer glibc than the board has does not
  # fail visibly -- the console just never boots, which reads as "the core is
  # broken". Compare against the binary the board ALREADY RUNS, and refuse to
  # stage anything that asks for more.
  # The card is not mounted in WSL; a copy of the stock binary the board runs is
  # kept in the project (out/MiSTer.upstream-nos573, 2026-09-12 stock install).
  local ref="$SD/MiSTer.orig"
  [ -f "$ref" ] || ref="$PROJ/out/MiSTer.upstream-nos573"
  if [ -f "$ref" ]; then
    local hi_ours hi_ref
    hi_ours=$(arm-none-linux-gnueabihf-readelf -V "$out" | grep -oE 'GLIBC_[0-9.]+' \
              | sed 's/GLIBC_//' | sort -uV | tail -1)
    hi_ref=$(arm-none-linux-gnueabihf-readelf -V "$ref" | grep -oE 'GLIBC_[0-9.]+' \
              | sed 's/GLIBC_//' | sort -uV | tail -1)
    if [ -z "$hi_ref" ]; then
      die "could not read the reference binary's GLIBC requirements ($ref). An
empty reading is NOT a pass -- verify the instrument before believing a null."
    fi
    say "glibc floor: ours GLIBC_$hi_ours vs the board's own binary GLIBC_$hi_ref"
    if [ "$(printf '%s\n%s\n' "$hi_ours" "$hi_ref" | sort -V | tail -1)" != "$hi_ref" ]; then
      die "ABI GATE: this build needs GLIBC_$hi_ours but the board runs a binary
needing only GLIBC_$hi_ref. It would not boot. Use the 10.2 toolchain."
    fi
  else
    say "WARNING: no $ref to compare against -- ABI gate SKIPPED, not passed"
  fi

  mkdir -p "$DOCS/System573_MiSTer/out"
  cp -f "$out" "$DOCS/System573_MiSTer/out/MiSTer"
  say "binary copied to System573_MiSTer/out/MiSTer"
}

stage_deploy() {
  [ -d "$SD" ] || die "SD card not mounted at $SD"
  [ -f "$DOCS/System573_MiSTer/out/MiSTer" ] || die "build first"
  if [ ! -f "$SD/MiSTer.orig" ]; then
    say "keeping the stock binary as MiSTer.orig"
    cp -f "$SD/MiSTer" "$SD/MiSTer.orig"
  fi
  cp -f "$DOCS/System573_MiSTer/out/MiSTer" "$SD/MiSTer"
  chmod +x "$SD/MiSTer" 2>/dev/null || true
  # debug=1 or none of the service's output is ever visible (cfg.cpp sends the
  # global stdout to /dev/null unless it is set)
  if ! grep -qE '^[[:space:]]*debug[[:space:]]*=' "$SD/MiSTer.ini"; then
    say "adding debug=1 to MiSTer.ini (backup: MiSTer.ini.bak573)"
    cp -f "$SD/MiSTer.ini" "$SD/MiSTer.ini.bak573"
    python3 - "$SD/MiSTer.ini" <<'PY'
import sys,io
p=sys.argv[1]
s=open(p,encoding='utf-8',errors='surrogateescape').read()
i=s.find('[MiSTer]')
if i<0: sys.exit('no [MiSTer] section')
j=s.find('\n',i)+1
open(p,'w',encoding='utf-8',errors='surrogateescape').write(s[:j]+'debug=1\n'+s[j:])
print('debug=1 added')
PY
  fi
  ls -la "$SD/MiSTer" "$SD/MiSTer.orig"
  say "deployed. Launch via a .mgl -- the bare .rbf gives no MP3 (core-name gate)."
}

case "${1:-all}" in
  setup)  stage_setup ;;
  graft)  stage_graft ;;
  build)  stage_build ;;
  deploy) stage_deploy ;;
  all)    stage_setup; stage_graft; stage_build ;;
  *)      die "usage: $0 [setup|graft|build|deploy|all]" ;;
esac
