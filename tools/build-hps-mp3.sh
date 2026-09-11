#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# build-hps-mp3.sh - build the forked Main_MiSTer ARM binary carrying the 573
#                    HPS MP3 service (support/s573/).
#
# Runs INSIDE the Linux VM that the Cowork session drives on the Mac: aarch64
# Ubuntu, ~/Documents mounted and executable, no sudo, no network. ARM publishes
# an aarch64-hosted build of arm-none-linux-gnueabihf, which is the triple
# Main's own Makefile expects -- so nothing needs installing.
#
# Three inputs must be fetched on macOS into ~/Documents first (the VM has no
# network):
#   Main_MiSTer.tar.gz
#   arm-gnu-toolchain-13.3.rel1-aarch64-arm-none-linux-gnueabihf.tar.xz
#   minimp3.h
#
# Stages:  setup | graft | build | deploy | all
# -----------------------------------------------------------------------------
set -euo pipefail

DOCS="${DOCS:-$HOME/mnt/Documents}"
PROJ="${PROJ:-$DOCS/System573_MiSTer}"
WORK="${WORK:-$HOME/s573build}"
TC="$WORK/toolchain"
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
  tctar="$(need_input 'arm-gnu-toolchain-*-aarch64-arm-none-linux-gnueabihf.tar.xz' 'ARM toolchain')"
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
  "$TC/bin/arm-none-linux-gnueabihf-gcc" --version | head -1

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
  python3 - "$MAIN" <<'PY'
import re, sys, os
main = sys.argv[1]

# ---- 1. the poll hook -------------------------------------------------------
p = os.path.join(main, 'user_io.cpp')
s = open(p, encoding='utf-8', errors='surrogateescape').read()
if 's573mp3_poll' in s:
    print('user_io.cpp: hook already present')
else:
    m = re.search(r'^([ \t]*)mdplus_poll\s*\(\s*\)\s*;[ \t]*$', s, re.M)
    if not m:
        m = re.search(r'^([ \t]*)\w*psx_poll\s*\(\s*\)\s*;[ \t]*$', s, re.M)
    if not m:
        sys.exit('user_io.cpp: found neither mdplus_poll() nor psx_poll() in '
                 'user_io_poll() -- refusing to guess where the hook goes')
    ind = m.group(1)
    ins = (m.group(0) + '\n' + ind +
           '/* Konami System 573: HPS-side MP3 decode service. Core-name gated '
           'inside. */\n' + ind + 's573mp3_poll();')
    s = s[:m.start()] + ins + s[m.end():]
    decl = ('\n/* support/s573/s573mp3.cpp */\nextern void s573mp3_poll(void);\n')
    # put the declaration after the last #include at the top of the file
    incs = list(re.finditer(r'^#include[^\n]*\n', s, re.M))
    at = incs[-1].end() if incs else 0
    s = s[:at] + decl + s[at:]
    open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
    print('user_io.cpp: hook inserted after %s' % m.group(0).strip())

# ---- 2. the Makefile --------------------------------------------------------
p = os.path.join(main, 'Makefile')
s = open(p, encoding='utf-8', errors='surrogateescape').read()
if 'support/s573' in s:
    print('Makefile: already carries support/s573')
else:
    # Append to whichever variables already gather support/* sources, so we
    # inherit the project's own flags and rules rather than inventing any.
    csrc  = re.search(r'^(\s*(?:C_SRC|CSRC|SRC_C)\s*[:+]?=)', s, re.M)
    ccsrc = re.search(r'^(\s*(?:CPP_SRC|CXXSRC|SRC_CPP|CC_SRC)\s*[:+]?=)', s, re.M)
    names = sorted(set(re.findall(r'^\s*([A-Z_0-9]+)\s*[:+]?=', s, re.M)))
    add = ('\n# Konami System 573 HPS MP3 service (support/s573)\n'
           'S573_C   := support/s573/s573mp3_core.c support/s573/s573_descramble.c\n'
           'S573_CPP := support/s573/s573mp3.cpp\n')
    hooked = False
    for var, val in (('C', 'S573_C'), ('CPP', 'S573_CPP')):
        # find a variable whose value already mentions support/ with that suffix
        suffix = r'\.c\b' if var == 'C' else r'\.cpp\b'
        for m in re.finditer(r'^([A-Z_0-9]+)\s*([:+]?=)([^\n]*(?:\\\n[^\n]*)*)', s, re.M):
            if 'support/' in m.group(3) and re.search(suffix, m.group(3)):
                add += '%s += $(%s)\n' % (m.group(1), val)
                hooked = True
                break
    if not hooked:
        sys.exit('Makefile: could not find the variables that gather support/*.c '
                 'and support/*.cpp. Variables present: %s' % ', '.join(names))
    # insert after the last variable assignment block near the top
    m = re.search(r'^\s*$', s[2000:], re.M)
    at = s.find('\n', 0)
    # safest: put it immediately before the first rule (a line with a ':' target)
    r = re.search(r'^[A-Za-z0-9_./$()%-]+\s*:[^=]', s, re.M)
    at = r.start() if r else len(s)
    s = s[:at] + add + '\n' + s[at:]
    open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
    print('Makefile: support/s573 sources added')
PY
  say "graft OK"
}

stage_build() {
  [ -x "$TC/bin/arm-none-linux-gnueabihf-gcc" ] || die "run the setup stage first"
  say "building (this is the first compile of s573mp3.cpp against Main's headers)"
  export PATH="$TC/bin:$PATH"
  make -C "$MAIN" -j"$(nproc)" 2>&1 | tail -60
  local out
  out="$(ls -1 "$MAIN"/MiSTer 2>/dev/null || true)"
  [ -n "$out" ] || die "no MiSTer binary produced"
  file "$out"
  arm-none-linux-gnueabihf-strip -s "$out" || true
  ls -la "$out"
  strings -a "$out" | grep -c s573mp3 | sed 's/^/s573mp3 strings in the binary: /'
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
