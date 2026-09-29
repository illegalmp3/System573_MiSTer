#!/usr/bin/env bash
# Generate the security-cart $readmemh fixtures for tb_s573_seccart.v from the
# (gitignored, copyrighted) game dumps. Writes one hex byte per line:
#   sim/secdata/pnchmn2_u1.hex   (548 bytes,  X76F041 EEPROM image, pnchmn2)
#   sim/secdata/pnchmn2_u6.hex   (8 bytes,    DS2401 serial image, pnchmn2)
#   sim/secdata/gtrfrk5m_u1.hex  (4116 bytes, ZS01 NVRAM image, gtrfrk5m)
#   sim/secdata/gtrfrk5m_u6.hex  (8 bytes,    DS2401 serial image, gtrfrk5m)
#   sim/secdata/ddrusa_u1.hex    (140 bytes,  ZS01 NVRAM image, ddrusa)
#   sim/secdata/ddrusa_u6.hex    (8 bytes,    DS2401 serial image, ddrusa)
#   sim/secdata/ddrusa_zs01_vectors.hex  (golden wire vectors, tools/zs01_ref.py)
#
# Source preference: dumps/mame573/<game>.zip else /tmp/secA/*.
# If a dump is absent this exits 0 WITHOUT writing its fixtures -- the testbench then
# detects the missing fixtures and SKIPS that real-data part (so `make` stays green on
# machines without the dumps; the real assertions run wherever the dump exists).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/secdata"; mkdir -p "$OUT"

emit() { # emit <bytes-file> <out.hex>
  python3 - "$1" "$2" <<'PY'
import sys
data = open(sys.argv[1],'rb').read()
with open(sys.argv[2],'w') as f:
    for b in data: f.write(f"{b:02x}\n")
PY
}

# extract <zip> <u1name> <u6name> <out-prefix> <label>
extract() {
  local zip="$1" u1="$2" u6="$3" pfx="$4" label="$5"
  local tmp; tmp="$(mktemp -d)"
  local got=0
  if [ -f "$zip" ] && command -v unzip >/dev/null 2>&1; then
    if unzip -o -q "$zip" "$u1" "$u6" -d "$tmp" 2>/dev/null; then
      emit "$tmp/$u1" "$OUT/${pfx}_u1.hex"; emit "$tmp/$u6" "$OUT/${pfx}_u6.hex"; got=1
    fi
  fi
  if [ "$got" = 0 ] && [ -f "/tmp/secA/$u1" ] && [ -f "/tmp/secA/$u6" ]; then
    emit "/tmp/secA/$u1" "$OUT/${pfx}_u1.hex"; emit "/tmp/secA/$u6" "$OUT/${pfx}_u6.hex"; got=1
  fi
  rm -rf "$tmp"
  if [ "$got" = 1 ]; then
    echo "gen_secdata: wrote $OUT/${pfx}_u1.hex + ${pfx}_u6.hex ($label)"
  else
    echo "gen_secdata: $label dump not found -- that real-data part will SKIP"
  fi
}

extract "$ROOT/dumps/mame573/pnchmn2.zip"  gqa09ja.u1 gqa09ja.u6 pnchmn2  "pnchmn2 X76F041"

# TWO-cassette titles for tb_s573_seccart_dual.v (rtl/s573_cass_pack.v): the game
# cassette as the launcher's .u1 (ZS01 padded to 4116 B the way tools/stage_573.py
# does it) plus the .cas pack {game .u6, install .u6, install .u1} built by the same
# tools/make_cas_pack.py the staging uses -- so the bench loads the real file layout.
#   ddr4m  (cassxzi): game gca33aa ZS01, install gea33aa X76F041
#   ddr3ma (cassyyi): game gn887aa X76F100, install ge887aa X76F100
dual() { # dual <zip> <game.u1> <game.u6> <install.u1> <install.u6> <pfx> <zs01:0|1> <label>
  local zip="$1" gu1="$2" gu6="$3" iu1="$4" iu6="$5" pfx="$6" zs="$7" label="$8"
  local tmp; tmp="$(mktemp -d)"
  if [ -f "$zip" ] && command -v unzip >/dev/null 2>&1 && unzip -o -q "$zip" "$gu1" "$gu6" -d "$tmp" 2>/dev/null; then
    if [ "$zs" = 1 ]; then
      python3 "$ROOT/tools/stage_zs01_u1.py" "$zip" --u1 "$gu1" --u6 "$gu6" -o "$tmp/game.u1" >/dev/null
    else
      cp "$tmp/$gu1" "$tmp/game.u1"
    fi
    python3 "$ROOT/tools/make_cas_pack.py" "$zip" --game-u6 "$gu6" --install-u1 "$iu1" --install-u6 "$iu6" -o "$tmp/pack.cas" >/dev/null
    emit "$tmp/game.u1" "$OUT/${pfx}_game_u1.hex"; emit "$tmp/pack.cas" "$OUT/${pfx}_cas.hex"
    echo "gen_secdata: wrote $OUT/${pfx}_game_u1.hex + ${pfx}_cas.hex ($label)"
  else
    echo "gen_secdata: $label dump not found -- tb_s573_seccart_dual will SKIP it"
  fi
  rm -rf "$tmp"
}
dual "$ROOT/dumps/mame573/ddr4m.zip"  gca33aa.u1 gca33aa.u6 gea33aa.u1 gea33aa.u6 ddr4m  1 "ddr4m ZS01 game + X76F041 install"
dual "$ROOT/dumps/mame573/ddr3ma.zip" gn887aa.u1 gn887aa.u6 ge887aa.u1 ge887aa.u6 ddr3ma 0 "ddr3ma X76F100 game + X76F100 install"
extract "$ROOT/dumps/mame573/gtrfrk5m.zip" gea26jaa.u1 gea26jaa.u6 gtrfrk5m "gtrfrk5m ZS01"
extract "$ROOT/dumps/mame573/ddrusa.zip"   gka44ua.u1 gka44ua.u6 ddrusa   "ddrusa ZS01"
# Golden ciphertext vectors for tb_zs01_golden.v from the INDEPENDENT reference model.
if [ -f "$OUT/ddrusa_u1.hex" ]; then
  python3 "$ROOT/tools/zs01_ref.py" --u1hex "$OUT/ddrusa_u1.hex" --u6hex "$OUT/ddrusa_u6.hex" \
          --out "$OUT/ddrusa_zs01_vectors.hex" --nvout "$OUT/ddrusa_zs01_nv_after.hex"
fi
