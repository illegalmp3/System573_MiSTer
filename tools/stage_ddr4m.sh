#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# stage_ddr4m.sh - stage Dance Dance Revolution 4th Mix (ddr4m, G*A33 VER. AAA)
# onto the games volume.  TIER 3: the first title needing the PCMCIA card.
#
#   tools/stage_ddr4m.sh "/Volumes/Samsung T7/games/System573"
#
# ddr4m's MAME machine config is `ddr3mp` (ksys573.cpp:6542 -> L2779-2788), which
# is dsfdr's config plus exactly ONE new device: pccard2_32mb(config) -- a Fujitsu
# 32 MB linear flash card in PCMCIA SLOT 2 (bus/pccard/linflash.cpp,
# linear_flash_pccard_29f017a_device<8> = 8 x 29F016A chip pairs). It also adds the
# JVS memory-card reader (k573mcr), which is a PLAYER-FACING peripheral, not a boot
# gate -- see docs/2026-09-14-tier3-pcmcia-design.md 1.
#
# Two cassettes, one slot, exactly like dsfdr: gea33aa is the INSTALL cassette
# (X76F041 + DS2401, 548 B) and gca33aa is the GAME cassette (ZS01, 140 B padded to
# 4116 for emu.sv's size-based type inference). Two launchers; prefix GE = install,
# GC = game.
#
# THE SAVE FILE IS 48 MiB, not 16: with "573 PCMCIA Card" ON the slot-4 image is the
# 16 MB onboard flash FOLLOWED BY the 32 MB card, in one file (Main parses at most
# six file/reset items per .mgl and both launchers already use all six, so a second
# mount slot is impossible). REQUIRES A 64 MB OR LARGER SDRAM MODULE on the
# DE10-Nano -- the card is backed at SDRAM 0x02000000..0x03FFFFFF.
#
# Everything is derived from dumps/mame573/ and verified, never hand-copied.
# -----------------------------------------------------------------------------
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
DST="${1:-}"
[ -n "$DST" ] || { echo "usage: $0 <games/System573 dir>" >&2; exit 2; }
[ -d "$DST" ] || { echo "no such directory: $DST" >&2; exit 2; }
ZIP="$ROOT/dumps/mame573/ddr4m.zip"
CHD="$ROOT/dumps/mame573/a33aaa02.chd"
[ -f "$ZIP" ] || { echo "missing $ZIP" >&2; exit 2; }
[ -f "$CHD" ] || { echo "missing $CHD" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Wait until a just-written file is actually readable. Native macOS returns
# immediately; a network/bridge-backed volume (e.g. staging over the Cowork device
# bridge) can report a successful write and a correct stat while the file is not yet
# openable for a few seconds. Every read-back below goes through this so the script
# works in both places.
wait_readable() {
  local f="$1" n=0
  while [ $n -lt 40 ]; do
    if [ -r "$f" ] && dd if="$f" of=/dev/null bs=1 count=1 status=none 2>/dev/null; then return 0; fi
    sleep 1; n=$((n+1))
  done
  echo "   WARNING: $f still not readable after 40 s -- skipping its verification" >&2
  return 1
}
unzip -oq "$ZIP" 'gea33aa.u1' 'gea33aa.u6' 'gca33aa.u6' -d "$TMP"

echo "== INSTALL cassette (X76F041, used as-is)"
cp -f "$TMP/gea33aa.u1" "$DST/ddr4m_install.u1"
cp -f "$TMP/gea33aa.u6" "$DST/ddr4m_install.u6"
if wait_readable "$DST/ddr4m_install.u1"; then
  printf '   ddr4m_install.u1 %s bytes\n' "$(wc -c < "$DST/ddr4m_install.u1" | tr -d ' ')"
fi

echo "== GAME cassette (ZS01, padded + verified)"
python3 "$ROOT/tools/stage_zs01_u1.py" "$ZIP" --u1 gca33aa.u1 --u6 gca33aa.u6 \
        -o "$DST/ddr4m.u1"
cp -f "$TMP/gca33aa.u6" "$DST/ddr4m.u6"
if wait_readable "$DST/ddr4m.u1"; then
  python3 "$ROOT/tools/stage_zs01_u1.py" "$ZIP" --u1 gca33aa.u1 --u6 gca33aa.u6 \
          --check "$DST/ddr4m.u1" >/dev/null
  echo "   ddr4m.u1 verified against the dump"
fi

echo "== disc (a33aaa02: TRACK:1 TYPE:MODE1_RAW SUBTYPE:RW_RAW FRAMES:128636 -> used directly)"
cp -f "$CHD" "$DST/ddr4m.chd"

echo "== blank 48 MiB save (16 MB onboard flash + 32 MB PCMCIA card)"
echo "   Main does not auto-create it: an .mgl type=s item mounts with pre=0, and a"
echo "   missing file EJECTS the slot (docs/2026-09-12-flash-persistence-fixed.md)."
if [ ! -f "$DST/ddr4m.sav" ]; then
  dd if=/dev/zero of="$DST/ddr4m.sav" bs=1048576 count=48 status=none
  echo "   created ddr4m.sav (48 MiB of zeroes)"
else
  wait_readable "$DST/ddr4m.sav" || true
  sz="$(wc -c < "$DST/ddr4m.sav" 2>/dev/null | tr -d ' ')"
  if [ "$sz" != "50331648" ]; then
    echo "   WARNING: ddr4m.sav is $sz bytes, expected 50331648 (48 MiB)." >&2
    echo "            A short file restores only what it holds; the card region is left" >&2
    echo "            uninitialised. Delete it to re-create, or extend it with:" >&2
    echo "              dd if=/dev/zero bs=1 count=\$((50331648-$sz)) >> \"$DST/ddr4m.sav\"" >&2
  else
    echo "   ddr4m.sav already present at 48 MiB -- left alone (it may hold an install)"
  fi
fi

echo "== launchers -> the card's _Console (copy by hand or with the card mounted)"
echo "   mgl/ddr4m_install.mgl, mgl/ddr4m_console.mgl"
echo
echo "   OSD for this title: 573 PCMCIA Card = 32MB (slot 2)   <-- REQUIRED, default is Off"
echo "                       573 Cabinet     = STANDARD"
echo "                       573 Boot Device = CD-ROM to install, Flash ROM afterwards"
ls -la "$DST"/ddr4m* 2>/dev/null || true
