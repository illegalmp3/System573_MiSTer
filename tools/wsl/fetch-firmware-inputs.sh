#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fetch-firmware-inputs.sh -- download the three inputs tools/build-hps-mp3.sh
# needs, into $DOCS (default /mnt/c/Users/ricky/Documents on the WSL side).
#
#   Main_MiSTer-<sha>.tar.gz   upstream MiSTer-devel/Main_MiSTer, at the LAST
#                              commit on or before $MAIN_DATE (default 2026-09-07:
#                              the board runs the 260907 stock install and the
#                              previous good build was "main-s573-20260907")
#   gcc-arm-10.2-2020.11-<host>-arm-none-linux-gnueabihf.tar.xz
#                              ARM's toolchain; the 10.2 pin is a runtime glibc
#                              ABI pin (see build-hps-mp3.sh header)
#   minimp3.h                  lieff/minimp3, single header
#
# Idempotent: existing files are kept. Run via the job runner (needs network).
# ---------------------------------------------------------------------------
set -euo pipefail
DOCS="${DOCS:-/mnt/c/Users/ricky/Documents}"
MAIN_DATE="${MAIN_DATE:-2026-09-07}"
HOST="$(uname -m)"
cd "$DOCS"

say() { printf '\n== %s\n' "$*"; }

say "toolchain ($HOST host)"
TC="gcc-arm-10.2-2020.11-$HOST-arm-none-linux-gnueabihf.tar.xz"
if [ ! -f "$TC" ]; then
  wget -q --show-progress -O "$TC.part" \
    "https://developer.arm.com/-/media/Files/downloads/gnu-a/10.2-2020.11/binrel/$TC" \
    && mv "$TC.part" "$TC"
fi
ls -la "$TC"
xz -t "$TC" && echo "toolchain archive OK"

say "minimp3.h"
[ -f minimp3.h ] || wget -q -O minimp3.h https://raw.githubusercontent.com/lieff/minimp3/master/minimp3.h
grep -q MINIMP3_MAX_SAMPLES_PER_FRAME minimp3.h && echo "minimp3.h OK"

say "Main_MiSTer at the last commit on or before $MAIN_DATE"
if ! ls Main_MiSTer*.tar.gz >/dev/null 2>&1; then
  rm -rf /tmp/Main_MiSTer
  git clone -q https://github.com/MiSTer-devel/Main_MiSTer.git /tmp/Main_MiSTer
  cd /tmp/Main_MiSTer
  sha="$(git rev-list -n1 --before="$MAIN_DATE 23:59:59" HEAD)"
  git checkout -q "$sha"
  short="$(git rev-parse --short "$sha")"
  when="$(git log -1 --format=%cd --date=short)"
  echo "Main_MiSTer $short ($when): $(git log -1 --format=%s)"
  git archive --format=tar.gz --prefix="Main_MiSTer-$short/" -o "$DOCS/Main_MiSTer-$short-$when.tar.gz" "$sha"
  cd "$DOCS"
fi
ls -la Main_MiSTer*.tar.gz
say "done"
