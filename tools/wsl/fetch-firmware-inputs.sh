#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fetch-firmware-inputs.sh -- download the three inputs tools/build-hps-mp3.sh
# needs, into $DOCS (default /mnt/c/Users/ricky/Documents on the WSL side).
#
#   Main_MiSTer-release-<YYYYMMDD>-<sha>.tar.gz
#                              upstream MiSTer-devel/Main_MiSTer at the commit that
#                              published the STABLE release releases/MiSTer_<date>
#                              (default: the newest one; MAIN_RELEASE=YYYYMMDD pins
#                              another). The fork is built on exactly the source of
#                              the stock binary everyone runs, not on master.
#   MiSTer_<YYYYMMDD>          that stock release binary itself: the console's
#                              /media/fat/MiSTer (deploy installs it) and the ABI
#                              reference the build's glibc gate compares against
#   gcc-arm-10.2-2020.11-<host>-arm-none-linux-gnueabihf.tar.xz
#                              ARM's toolchain; the 10.2 pin is a runtime glibc
#                              ABI pin (see build-hps-mp3.sh header)
#   minimp3.h                  lieff/minimp3, single header
#
# Idempotent: existing files are kept. Run via the job runner (needs network).
# ---------------------------------------------------------------------------
set -euo pipefail
DOCS="${DOCS:-/mnt/c/Users/ricky/Documents}"
MAIN_RELEASE="${MAIN_RELEASE:-latest}"
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

say "Main_MiSTer stable release ($MAIN_RELEASE)"
rm -rf /tmp/Main_MiSTer
git clone -q https://github.com/MiSTer-devel/Main_MiSTer.git /tmp/Main_MiSTer
cd /tmp/Main_MiSTer
if [ "$MAIN_RELEASE" = latest ]; then
  rel="$(ls releases | grep -E '^MiSTer_[0-9]{8}$' | sort | tail -1)"
else
  rel="MiSTer_$MAIN_RELEASE"
fi
[ -f "releases/$rel" ] || { echo "no releases/$rel in Main_MiSTer" >&2; exit 1; }
date="${rel#MiSTer_}"
# the commit that ADDED the release binary: its tree is the source it was built from
sha="$(git log -1 --format=%H --diff-filter=A -- "releases/$rel")"
short="$(git rev-parse --short "$sha")"
echo "stable release $rel = commit $short: $(git log -1 --format='%cd %s' --date=short "$sha")"
tgz="$DOCS/Main_MiSTer-release-$date-$short.tar.gz"
[ -f "$tgz" ] || git archive --format=tar.gz --prefix="Main_MiSTer-$short/" -o "$tgz" "$sha"
[ -f "$DOCS/$rel" ] || cp "releases/$rel" "$DOCS/$rel"
# The menu core ships alongside each Main release (the updater installs both as
# /media/fat/MiSTer and /media/fat/menu.rbf). Take the menu release of the same
# date, else the newest one not after it.
rm -rf /tmp/Menu_MiSTer
git clone -q --depth 1 --filter=blob:none --no-checkout https://github.com/MiSTer-devel/Menu_MiSTer.git /tmp/Menu_MiSTer
cd /tmp/Menu_MiSTer
menu="$(git ls-tree --name-only HEAD releases/ | sed -nE 's#^releases/(menu_[0-9]{8}\.rbf)$#\1#p' \
        | awk -v d="$date" '{ x = substr($0, 6, 8); if (x <= d) print }' | sort | tail -1)"
[ -n "$menu" ] || { echo "no menu release on or before $date" >&2; exit 1; }
[ -f "$DOCS/$menu" ] || git show "HEAD:releases/$menu" > "$DOCS/$menu"
echo "menu core: $menu"
cd "$DOCS"
ls -la "$tgz" "$DOCS/$rel" "$DOCS/$menu"
say "done"
