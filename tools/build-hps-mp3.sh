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
# OUTPUT: out/MiSTer_System573 -- a SECOND Main binary, installed next to the stock
# /media/fat/MiSTer, never over it. Stock Main switches to it per core from
# MiSTer.ini (user_io.cpp user_io_init: `main = getFullPath(cfg.main); if it is not
# the running exe and FileExists(main): app_restart(path, xml, main)`; cfg.main
# defaults to "MiSTer", so the menu and every other core switch back). The section
# is [System573] -- the launchers' <setname>, which is what cfg.cpp
# ini_get_section() matches; the .rbf file name plays no part.
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

# ---- 4. let the slot-4 save GROW (2026-09-28, timekeeper region) ------------
# user_io_file_mount() sets sd_image_cangrow[index] = (pre != 0); an .mgl type="s"
# item mounts with pre=0, so a core write one block past EOF is clamped to zero
# bytes and silently dropped. The 573 core appends the 9 KB M48T58 region to a
# .sav made before it existed (rtl/s573_tk_nv.v); FileWriteAdv already refreshes
# file->size after an append, so growth only needs the clamp lifted for the 573
# core's slot 4. Gated on the core name inside s573_sav_cangrow().
s = open(p, encoding='utf-8', errors='surrogateescape').read()
if 's573_sav_cangrow' in s:
    print('user_io.cpp: cangrow hook already present')
else:
    old = 'sd_image_cangrow[index] = (pre != 0);'
    if s.count(old) != 1:
        sys.exit('user_io.cpp: expected exactly one "sd_image_cangrow[index] = (pre != 0);"')
    s = s.replace(old, 'sd_image_cangrow[index] = (pre != 0) || s573_sav_cangrow(index);   // System 573 slot-4 .sav may grow (gated inside)')
    s = s.replace('extern void s573mp3_poll(void);\n',
                  'extern void s573mp3_poll(void);\nextern int s573_sav_cangrow(int index);\n', 1)
    open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
    print('user_io.cpp: cangrow hook inserted')
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
  if [ ! -f "$ref" ] && [ -f "$SD/MiSTer" ] && ! strings -a "$SD/MiSTer" | grep -q s573mp3; then
    ref="$SD/MiSTer"          # the card's own stock binary
  fi
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
  cp -f "$out" "$DOCS/System573_MiSTer/out/MiSTer_System573"
  say "binary copied to System573_MiSTer/out/MiSTer_System573"
}

stage_deploy() {
  [ -d "$SD" ] || die "SD card not mounted at $SD"
  local bin="$DOCS/System573_MiSTer/out/MiSTer_System573"
  [ -f "$bin" ] || die "build first"
  # Earlier deploys REPLACED /media/fat/MiSTer and kept the stock one as MiSTer.orig.
  # Put the stock binary back first, so nothing but this core runs the fork.
  if [ -f "$SD/MiSTer" ] && strings -a "$SD/MiSTer" | grep -q s573mp3; then
    if [ -f "$SD/MiSTer.orig" ] && ! strings -a "$SD/MiSTer.orig" | grep -q s573mp3; then
      say "restoring the stock MiSTer from MiSTer.orig (the old deploy had replaced it)"
      cp -f "$SD/MiSTer.orig" "$SD/MiSTer"
    else
      say "WARNING: $SD/MiSTer is a 573 build and no stock MiSTer.orig is there --"
      say "         run the MiSTer updater (or copy a stock MiSTer) to restore it"
    fi
  fi
  cp -f "$bin" "$SD/MiSTer_System573"
  chmod +x "$SD/MiSTer_System573" 2>/dev/null || true
  # The same INI edit the release's stager does (tools/s573_stage.py --install-mp3),
  # so the developer card and a user's card are set up identically. debug=1 goes in
  # the [System573] section only: the service's output is invisible without it
  # (cfg.cpp sends stdout to /dev/null otherwise), and no other core needs it.
  python3 - "$PROJ/tools/s573_stage.py" "$SD" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("st", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
log = []
for n in ["MiSTer.ini"] + sorted(x for x in os.listdir(sys.argv[2]) if x.lower().startswith("mister_") and x.lower().endswith(".ini")):
    p = os.path.join(sys.argv[2], n)
    m.ini_add_main(p, False, log)
    s = open(p, encoding="utf-8", errors="surrogateescape", newline="").read()
    lines = s.splitlines(keepends=True)
    k = next(i for i, l in enumerate(lines) if l.strip().lower() == "[system573]")
    end = next((i for i in range(k + 1, len(lines)) if lines[i].lstrip().startswith("[")), len(lines))
    if not any(l.split("=", 1)[0].strip().lower() == "debug" for l in lines[k + 1:end]):
        nl = "\r\n" if lines[k].endswith("\r\n") else "\n"
        lines.insert(k + 1, "debug=1" + nl)
        open(p, "w", encoding="utf-8", errors="surrogateescape", newline="").write("".join(lines))
        log.append(f"{n}: debug=1 in [System573]")
print("\n".join(log))
PY
  ls -la "$SD/MiSTer" "$SD/MiSTer_System573"
  say "deployed. Launch via a .mgl -- the bare .rbf is core name PSX, so neither the"
  say "[System573] INI section nor the MP3 service applies to it."
}

case "${1:-all}" in
  setup)  stage_setup ;;
  graft)  stage_graft ;;
  build)  stage_build ;;
  deploy) stage_deploy ;;
  all)    stage_setup; stage_graft; stage_build ;;
  *)      die "usage: $0 [setup|graft|build|deploy|all]" ;;
esac
