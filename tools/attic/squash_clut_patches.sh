#!/bin/bash
# Squash psx_patches 0012..0019 (three probes, three withdrawn fixes, one fix and its
# qualifier) into their NET effect, and prove the patched psx tree is byte-identical.
set -e
PIN=67153439fbb8e85e4108b9f0ff474d37aa6f7f5b
R=$(pwd); W=/tmp/sq; rm -rf $W; mkdir -p $W
list() { ( ROOT=$R; eval "$(sed -n '/^PATCHES=(/,/patch" )$/p' $1)"; printf '%s\n' "${PATCHES[@]}" ); }
mk() { mkdir -p $1; git -C psx archive $PIN | tar -x -C $1; }
ap() { d=$1; shift; for p in "$@"; do ( cd $d && git apply -p1 "$p" ) || { echo "FAILED to apply $p in $d"; exit 1; }; done; }
mapfile -t OLD < <(list tools/apply_psx_patches.sh)
echo "old stack: ${#OLD[@]} patches"
mk $W/A; ap $W/A "${OLD[@]}"
# 1. the stack reproduces the tree every build has used
n=$(diff -rq $W/A psx -x .git 2>/dev/null | grep -v "^Only in psx" | wc -l)
echo "old stack vs the live psx/ tree: $n differing files"; diff -rq $W/A psx -x .git | grep -v "^Only in psx" | head -5
# 2. net patch = state after 0019 minus state after 0011
PRE=(); MID=(); POST=(); s=0
for p in "${OLD[@]}"; do b=$(basename $p); num=${b:0:4}
  if [ $num -lt 0012 ]; then PRE+=("$p"); elif [ $num -le 0019 ]; then MID+=("$p"); else POST+=("$p"); fi; done
echo "pre ${#PRE[@]} mid ${#MID[@]} post ${#POST[@]}"
mk $W/n/a; ap $W/n/a "${PRE[@]}"; cp -r $W/n/a $W/n/b; ap $W/n/b "${MID[@]}"
NEW=$R/psx_patches/0012-s573-clut-cache-net.patch
{ cat <<'HDR'
s573: GPU palette (CLUT) cache -- the net of the June 2026 garble investigation

This is the combined effect of the former patches 0012..0019 (now in retired/),
generated mechanically as (tree after 0019) minus (tree after 0011); the stack with
this patch in their place produces a byte-identical psx/ tree (local/squash_clut.sh).

What is live: the palette cache is invalidated on cpu2vram / vram2vram VRAM writes
as well as the texture cache (0013, as qualified by 0019: not on vramFill).
What is dead weight, all constant '0' and folded away: the texture-mode flag-colour
probe (0012), DISABLE_CLUT_CACHE (0014), the CLUT stripe probe (0015), the
CLUT-resident interlock (0016), the row-dump probe (0017), the CLUT row-lock (0018).
The garble they chased was the 2 MB VRAM wrap fixed by 0021
(docs/audits/2026-06-10-missing-layer-reframe.md).
---
HDR
  ( cd $W/n && diff -ruN a b ) || true; } > $NEW
grep -c "^diff " $NEW
# 3. the new stack gives the same tree
mk $W/B; ap $W/B "${PRE[@]}" "$NEW" "${POST[@]}"
if diff -r $W/A $W/B >/dev/null; then echo "IDENTICAL: old stack == new stack (whole psx tree)"; else echo "DIFFERENT"; diff -rq $W/A $W/B | head; exit 1; fi
