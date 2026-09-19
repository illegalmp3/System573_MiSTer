#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-ubuntu.sh -- one-time provisioning of the WSL Ubuntu used for this
# project's Linux-side work (run as root via tools/win/jobrunner.ps1).
#
#   Icarus Verilog   the 573 RTL unit suite (sim/Makefile)
#   GHDL             VHDL fallback simulator (apt)
#   NVC              the VHDL-2008 simulator the psx/ elaboration gate and the
#                    dma/sio benches use (sim/nvc/*.sh); built from source because
#                    Ubuntu 24.04 does not package it
#   build tools      make/gcc/python3/git/wget/xz for the firmware cross-build
#                    (tools/build-hps-mp3.sh)
#
# Idempotent: re-running only upgrades what is missing.
# ---------------------------------------------------------------------------
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# latest release unless pinned: NVC_VER=1.16.2 ./setup-ubuntu.sh
NVC_VER="${NVC_VER:-$(curl -s https://api.github.com/repos/nickg/nvc/releases/latest \
          | sed -n 's/.*"tag_name": *"r\([0-9.]*\)".*/\1/p' | head -1)}"
NVC_VER="${NVC_VER:-1.16.2}"

say() { printf '\n== %s\n' "$*"; }

say "apt packages"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential make git python3 wget curl xz-utils file zip unzip ca-certificates \
  iverilog ghdl \
  automake autoconf pkg-config flex bison libdw-dev libffi-dev libzstd-dev zlib1g-dev \
  llvm-dev libreadline-dev 2>&1 | tail -3

say "versions"
iverilog -V 2>/dev/null | head -1
ghdl --version 2>/dev/null | head -1
python3 --version
gcc --version | head -1

if ! command -v nvc >/dev/null 2>&1; then
  say "building nvc $NVC_VER from source (no Ubuntu package)"
  mkdir -p /root/src && cd /root/src
  rm -rf "nvc-$NVC_VER"
  if [ ! -f "nvc-$NVC_VER.tar.gz" ]; then
    wget -q "https://github.com/nickg/nvc/releases/download/r$NVC_VER/nvc-$NVC_VER.tar.gz" \
      || wget -q -O "nvc-$NVC_VER.tar.gz" "https://github.com/nickg/nvc/archive/refs/tags/r$NVC_VER.tar.gz"
  fi
  tar -xzf "nvc-$NVC_VER.tar.gz"
  cd "nvc-$NVC_VER"
  [ -x configure ] || ./autogen.sh
  mkdir -p build && cd build
  ../configure --prefix=/usr/local >/dev/null
  make -j"$(nproc)" >/dev/null
  make install >/dev/null
fi
nvc --version | head -1

say "project dir is writable from WSL?"
cd "$(dirname "$0")/../.."
touch local/.wsl-can-write && rm -f local/.wsl-can-write && echo "yes: $(pwd)"

say "done"
