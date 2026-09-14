#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# stage_dsfdr.sh - stage Dancing Stage Fever (dsfdr) onto the games volume.
#
#   tools/stage_dsfdr.sh "/Volumes/Samsung T7/games/System573"
#
# dsfdr ships TWO cassettes for ONE slot (see mgl/dsfdr_*.mgl): gea37ja is the
# INSTALL cassette (X76F041, 548 B) and gca37ja is the GAME cassette (ZS01,
# 140 B padded to 4116 for emu.sv's size-based type inference). Two launchers,
# the ddrs2k pattern -- not dual-cassette RTL.
#
# Everything is derived from dumps/mame573/ and verified, never hand-copied: the
# ZS01 image goes through tools/stage_zs01_u1.py, which checks the response-to-
# reset, the fixed PIC command key against zs01.v's default, the plaintext game
# code and the DS2401 serial cross-checked byte-reversed against the .u6. An
# ad-hoc padding command is exactly how ddrusa's .u1 ended up unverifiable.
# -----------------------------------------------------------------------------
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
DST="${1:-}"
[ -n "$DST" ] || { echo "usage: $0 <games/System573 dir>" >&2; exit 2; }
[ -d "$DST" ] || { echo "no such directory: $DST" >&2; exit 2; }
ZIP="$ROOT/dumps/mame573/dsfdr.zip"
CHD="$ROOT/dumps/mame573/a37jaa02.chd"
[ -f "$ZIP" ] || { echo "missing $ZIP" >&2; exit 2; }
[ -f "$CHD" ] || { echo "missing $CHD" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unzip -oq "$ZIP" 'gea37ja.u1' 'gea37ja.u6' 'gca37ja.u6' -d "$TMP"

echo "== INSTALL cassette (X76F041, used as-is)"
cp -f "$TMP/gea37ja.u1" "$DST/dsfdr_install.u1"
cp -f "$TMP/gea37ja.u6" "$DST/dsfdr_install.u6"
printf '   dsfdr_install.u1 %s bytes\n' "$(wc -c < "$DST/dsfdr_install.u1" | tr -d ' ')"

echo "== GAME cassette (ZS01, padded + verified)"
python3 "$ROOT/tools/stage_zs01_u1.py" "$ZIP" --u1 gca37ja.u1 --u6 gca37ja.u6 \
        -o "$DST/dsfdr.u1"
cp -f "$TMP/gca37ja.u6" "$DST/dsfdr.u6"
python3 "$ROOT/tools/stage_zs01_u1.py" "$ZIP" --u1 gca37ja.u1 --u6 gca37ja.u6 \
        --check "$DST/dsfdr.u1" >/dev/null
echo "   dsfdr.u1 verified against the dump"

echo "== disc (MODE1_RAW: used directly)"
cp -f "$CHD" "$DST/dsfdr.chd"

echo "== blank 16 MB flash save (Main does not auto-create it: pre=0 ejects the slot)"
if [ ! -f "$DST/dsfdr.sav" ]; then
  if [ -f "$ROOT/dumps/mame573/../../out/flash16m_blank.bin" ]; then
    cp -f "$ROOT/out/flash16m_blank.bin" "$DST/dsfdr.sav"
  else
    dd if=/dev/zero of="$DST/dsfdr.sav" bs=1048576 count=16 status=none
  fi
  echo "   created dsfdr.sav (16 MiB of zeroes)"
else
  echo "   dsfdr.sav already present -- left alone (it may hold an install)"
fi

echo "== launchers -> the card's _Console (copy by hand or with the card mounted)"
echo "   mgl/dsfdr_install.mgl, mgl/dsfdr_console.mgl"
ls -la "$DST"/dsfdr* 2>/dev/null || true
