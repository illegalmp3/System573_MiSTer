#!/usr/bin/env bash
# Apply the System 573's local modifications to the vendored PSX_MiSTer submodule.
#
# psx/ is a git submodule pinned to an upstream SHA we cannot push to, but the 573
# integration must edit the PlayStation core (EXP1 routing, later 2 MB VRAM, DMA ch5).
# Those GPL-2.0 edits are kept as isolated, offer-back-able patch files under
# psx_patches/ and (re)applied to the submodule working tree before any sim or Quartus
# build. The submodule pointer itself never moves.
#
# Safe + idempotent: uses reverse-apply checks so it never re-applies an applied patch,
# and only ever resets the FILES A PATCH TOUCHES (never your unrelated psx/ edits), and
# only when a hunk is in a conflicted/partial state. --check never writes.
#
# Usage:  tools/apply_psx_patches.sh            # apply (idempotent)
#         tools/apply_psx_patches.sh --check     # report apply-ability, write nothing
#         tools/apply_psx_patches.sh --revert    # remove our patches (reverse-apply)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSX="$ROOT/psx"
PIN=67153439fbb8e85e4108b9f0ff474d37aa6f7f5b
PATCHES=( "$ROOT/psx_patches/0001-s573-exp1-widening.patch" \
          "$ROOT/psx_patches/0002-s573-nvc-cd-positionInIndex-init.patch" \
          "$ROOT/psx_patches/0003-s573-nvc-gpu-videoout-linemax-clamp.patch" \
          # 0004 (i-cache "redirect fix") RETIRED 2026-09-27 -> psx_patches/retired/. Its premise
          # was wrong: the tag store (RamMLAB) is an asynchronous read, so upstream's hit test
          # already sees the current FetchAddr. The patch forced an i-cache MISS on every 16-byte
          # line crossing (+5 clk1x each, NVC-measured: 65 -> 150 cycles for a 16-line loop),
          # which is what held ddrextrm at 30 fps. The June BIOS crash it was blamed for is the
          # cached-BIOS-mirror fill gap that 0005 fixes. docs/2026-09-27-ddrextrm-profile-verdict-and-icache-patch-0004.md
          "$ROOT/psx_patches/0005-s573-cpu-bios-uncached.patch" \
          "$ROOT/psx_patches/0006-s573-exp1-flash-wait.patch" \
          "$ROOT/psx_patches/0007-sdram-ch4-flash.patch" \
          "$ROOT/psx_patches/0008-s573-disable-cheats-engine.patch" \
          # 0009 (ext_data_new byte-lane fix) REMOVED: it deterministically stalls the boot
          # pre-EXP1 (fit-marginality on the 97%-ALM die, STA-clean). Per workflow w20walw69 the
          # byte-lane fix moves OFF the psx ext_data_new mux into the EXP1 slave (system573_top.v);
          # the sig is handled meanwhile by the sigpass BIOS (dumps/hyperbbc/573_sigpass.bin).
          #   "$ROOT/psx_patches/0009-s573-exp1-byte-read-lane.patch"
          # 0010 plumbs the CPU load width (reqsize_buf) out of memorymux -> psx_top ->
          # psx_mister as exp1_reqsize, so the EXP1 SLAVE (system573_top.v) can byte-align
          # its 16-bit halfword-native read return without touching the fragile ext_data_new mux.
          "$ROOT/psx_patches/0010-s573-exp1-reqsize.patch" \
          # 0011 removes the dormant consumer-PSX CD-ROM controller (cd_top + cd_xa helpers)
          # from psx_top -- the 573 drives its own ATAPI optical drive via rtl/atapi.v over EXP1
          # and never uses cd_top (confirmed dormant by 4 BIOS scans). Its outputs are tied to
          # safe idle constants (SS_Idle_cd/Pause_idle_cd held '1' so savestate/pause complete;
          # region_out passed straight through). Frees ~2.9k ALMs on the ALM/LAB-bound 573 die.
          "$ROOT/psx_patches/0011-s573-remove-cd-top.patch" \
          # 0012 = the NET of the former 0012..0019 (June 2026 CLUT-garble investigation, now in
          # psx_patches/retired/): three debug probes and three withdrawn fixes, all constant '0'
          # and folded away, plus the one live change -- the palette cache is invalidated on
          # cpu2vram/vram2vram VRAM writes along with the texture cache (not on vramFill).
          # Squashed 2026-10-02 by tools/attic/squash_clut_patches.sh, which proves the stack with this patch
          # produces a byte-identical psx/ tree to the eight it replaces.
          "$ROOT/psx_patches/0012-s573-clut-cache-net.patch" \
          # 0020 = SDRAM CAS latency 2->3: CL2 @ 101.6 MHz is out of SDR spec; the 573's
          # continuous flash traffic collects the margin debt as deterministic low-bit
          # miscapture on GPU-DMA reads (clut 491 -> 480/481). Audit: docs/audits/2026-06-10.
          "$ROOT/psx_patches/0020-sdram-cas-latency-3.patch" \
          # 0021 = 2 MB VRAM (the 573's CXD8561Q drives 1024 VRAM rows; the vendored core
          # implements 512 and truncates Y to 9 bits, so boot-time uploads to y>=512 WRAP
          # onto y-512 and corrupt the visible half -- the font-atlas/garble root cause).
          # Widens dst/src/scissor/texpage/CLUT Y to 10 bits per MAME psxgpu (gputype 2)
          # and maps row-bit-9 to DDR3 page 0x08 (+8MB; clear of memcard/SPU/framebuffer
          # pages). Scanout untouched (display reads stay bit-identical). Red/green sim
          # proof: sim/gpu_replay/run_vram2mb.sh + docs/audits/2026-06-10-vram-2mb-redgreen.md.
          "$ROOT/psx_patches/0021-gpu-2mb-vram-10bit-y.patch" \
          # 0022: 4 MB main-RAM decode (PLATFORM.md Main RAM row, constants-class bug #3).
          # The 573 has 4 MB RAM (MAME ksys573.cpp "4M"); the pristine core decodes only
          # 2 MB (ram8mb=0) or 8 MB linear (ram8mb=1), so +4MB accesses silently hit the
          # wrong SDRAM cells. Adds an opt-in ram4mb port (default '0' = pristine
          # behavior): masks RAM-region address bit 22 at the psx_top ram_Adr chokepoint
          # (CPU + icache + DMA reads) and at the dma.vhd write-back fifo insert --
          # matching MAME's DMA n_adrmask = ramsize-1 = 0x3fffff (cpu/psx/dma.cpp).
          # emu.sv enables it via S573_RAM4MB. Red/green: sim/system573/run_ram_mirror.sh.
          "$ROOT/psx_patches/0022-s573-main-ram-4mb.patch" \
          # 0023 = ATAPI CD-ROM on DMA channel 5 (the hard gate for every CD-installer
          # game). The BIOS's only sector-read data path is DMA mode (mode byte = 2 ->
          # ISR arms ch5: MADR=buf, BCR=bytes>>2, CHCR=0x11050100 manual+chop32); the
          # vendored core's ch5 is dead (request tied '0', no trigger, no WORKING arm
          # -> 'severity failure'). Adds the SPU-pattern 16-bit read trio
          # (atapi_dmaRequest/DMA_ATA_readEna/DMA_ATA_read) threaded dma -> psx_top ->
          # psx_mister -> emu.sv -> system573_top/atapi.v. readEna is ce-qualified
          # (the 573 fabric free-runs on clk1x). Device->RAM only (CHCR bit0 forced 0).
          # Red/green: sim/tb_cdboot.v (BIOS ch5 contract BFM, 32-word chopped bursts).
          "$ROOT/psx_patches/0023-s573-dma-ch5-atapi.patch" \
          # 0024 = SIO1 DSR cassette presence: the BIOS leaf 0x80038A28 polls SIO1_STAT
          # (0x1F801054) bit 7 (DSR); every real security cassette asserts slot DSR
          # (local/seccart_presence/) show ZERO SIO1 writes, so no IRQ work is needed.
          "$ROOT/psx_patches/0024-s573-sio1-dsr-presence.patch" \
          # 0025 = audio IIR low-pass -> PASSTHROUGH (resource recovery): frees ~436
          # ALM + 8 DSP so the 16 MB flash-saver (persistence) fits + clears the 100%
          # DSP wall. LOW risk: HPS-configured framework filter, zero boot exposure;
          # drops only the optional audio low-pass. docs/audits/2026-06-12-resource-recovery-scope.md
          "$ROOT/psx_patches/0025-s573-audio-iir-passthrough.patch" \
          # 0026 = resource-recovery candidate #3 (~575 ALM): strip the PSX controller
          # + light-gun paths. The 573 is a JAMMA/JVS arcade board with NO PSX
          # controller port -- gameplay input arrives over the JAMMA register in
          # s573_io.v (0x1f400008, fed by emu.sv ~{joy}), entirely independent of the
          # PSX SIO0 pad path. Removes joypad.vhd's ijoypad_pad SM (~534 ALM) and the
          # gpu_videoout.vhd justifier_sensor x2 + gpu_crosshair x2 (~41 ALM), tying
          # the shared SIO0 OR-bus (receiveValidPad/receiveBufferPad/ackPad/isActivePad)
          # and the gun overlay/IRQ10 terms to benign idle so the bus + GPU video mux
          # read exactly as "no pad/gun present". KEEPS joypad_mem + memcard1 (DDR /
          # Dancing-Stage edit data saves to the PS1 card). NVC-elaborate clean.
          # docs/audits/2026-06-12-resource-recovery-scope.md (cand #3).
          "$ROOT/psx_patches/0026-s573-strip-psx-joypad-pad-lightgun.patch" \
          # 0027 = resource-recovery candidate #4 (~64 ALM): drop the 2nd PS1 memory
          # card (joypad_mem #2) + the SNAC pad passthrough paths inside joypad.vhd.
          # Only card 1 is a real 573 use; no 573 game mounts a 2nd card, and the 573
          # never enables SNAC (a physical DE10 user-IO controller path -- emu.sv ties
          # snacport1/2 = 0). The mem2 master-port outputs are tied idle (no DDR3
          # traffic) and the SNAC select/clock lines are tied '0', which is exactly the
          # "no card-2 / no SNAC" state the surrounding SIO0 logic already special-cases
          # (selectedPortXSnac=0 -> actionNextCombine=actionNext + stock port select).
          # Stacks on 0026 (same file, joypad.vhd). NVC-elaborate clean.
          # docs/audits/2026-06-12-resource-recovery-scope.md (cand #4).
          "$ROOT/psx_patches/0027-s573-strip-memcard2-snac.patch" \
          # 0028 = resource-recovery lever #2, re-scoped. Clears ONLY MASK bit 3
          # (bicubic) on the ascal instance in sys/sys_top.v, which passed no MASK at
          # all and so defaulted to x"FF" (every interpoler enabled). MASK is a
          # GENERIC, so `IF MASK(MASK_BICUBIC)='1'` folds statically even inside a
          # process; the bicubic pipeline is driven unconditionally but read only in
          # that guard, so its final register loses fanout and the X.D+C MAC chain
          # prunes backwards (h and v). The audit's speculative "verify bic_* prunes"
          # caveat is therefore settled by construction.
          # NOT the audit's 0x03: MASK_NEAREST(0) and MASK_POLY(4) share the polyphase
          # datapath, and a compiled-out CASE arm leaves o_ldw UNASSIGNED (holds the
          # previous pixel) rather than falling back cleanly. 0xF7 drops bicubic only.
          # Motive is the TIMING path, not area -- pll_hdmi owns this build's binding
          # path at +0.006 ns and ascal is the only block on it.
          # CONSEQUENCE: do not select bicubic scaling in MiSTer.ini / the video OSD.
          "$ROOT/psx_patches/0028-s573-ascal-no-bicubic.patch" \
          # 0029 = OBSERVATION taps for the Tier-3 frame profile (rtl/s573_prof_gpu.v):
          # GP1(05) buffer flip, VBLANK irq, cpuPaused, stallNext, GPU/MDEC busy.
          # Nothing is driven into the core.
          "$ROOT/psx_patches/0029-s573-frame-profile.patch" \
          # 0030 = MDEC 15-bit inter-macroblock wait made switchable (mdec15Fast, OSD
          # "MDEC Timing", default = upstream 2171) + one pulse per decoded macroblock.
          # Upstream 9530638 introduced the 2171 for Parasite Eve 2 with no measurement;
          # ddrextrm's 304x176 15-bit movies need >16 ms/frame under it
          # (docs/2026-09-18-ddrextrm-video-path-from-sources.md).
          "$ROOT/psx_patches/0030-s573-mdec-timing-switch.patch" \
          # 0031 = the R3000 fetch PC brought out (dbg573_pc) for the PC-sampling
          # profiler rtl/s573_prof_pc.v. Observation only.
          "$ROOT/psx_patches/0031-s573-cpu-pc-tap.patch" \
          # 0032 = ascal PALETTE off (sys/sys_top.v). The palette RAM serves only the Linux
          # framebuffer's 8 bpp mode; this core's framebuffer is 16/24 bpp. With HDMI in, its
          # read (pal1_mem -> o_hpix2) was the one path missing timing (-0.075 ns, pll_hdmi).
          "$ROOT/psx_patches/0032-s573-ascal-no-fb-palette.patch" \
          # 0033 = ascal output sweep (sys/ascal.vhd): the next o_vcpt_pre3 and its end-of-frame
          # test are registered every o_clk instead of computed in the line-end cycle. With the
          # 2026-10-20 logic in, o_vcpt_pre3 -> o_vcpt_pre3 was the only failing path
          # (-0.163 / -0.221 ns, pll_hdmi). Output timing identical (sim/ascal_equiv).
          "$ROOT/psx_patches/0033-s573-ascal-vcpt-pipeline.patch" )

if [ ! -e "$PSX/.git" ]; then
  echo "error: psx submodule not initialised. Run: git submodule update --init psx" >&2
  exit 1
fi
cd "$PSX"
mode="${1:-apply}"

# files a patch touches (relative to psx/), for scoped resets only
touched_files() { for p in "${PATCHES[@]}"; do sed -n 's#^+++ b/\([^\t]*\).*#\1#p' "$p"; done | sort -u; }

case "$mode" in
  --check)
    # Validate the patch STACK, not each patch in isolation. Later patches
    # (e.g. 0006/0007) extend the same files/regions earlier ones (0001) add, so
    # a per-patch reverse/forward check against the live tree gives false
    # "WILL NOT APPLY" once the stack is applied. Instead, reconstruct the pinned
    # baseline of every touched file in a scratch dir and apply the patches there
    # in order -- exactly the sequence `apply` produces -- writing NOTHING to the
    # real psx working tree.
    rc=0
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    # Seed scratch with the pinned (PIN) version of each touched file.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      mkdir -p "$scratch/$(dirname "$f")"
      git show "$PIN:$f" > "$scratch/$f" 2>/dev/null \
        || { echo "error: cannot read pinned $f" >&2; exit 1; }
    done < <(touched_files)
    for p in "${PATCHES[@]}"; do
      [ -f "$p" ] || { echo "error: missing patch $p" >&2; exit 1; }
      # Apply (check, then apply) into the scratch tree so later patches in the
      # stack see earlier ones. `git apply -p1` operates on the files in $scratch
      # without needing it to be a git repo (we run it with the scratch dir as cwd).
      if ( cd "$scratch" && git apply -p1 --check "$p" 2>/dev/null \
                          && git apply -p1         "$p" 2>/dev/null ); then
        echo "applies cleanly:  $(basename "$p")"
      else
        echo "WILL NOT APPLY:   $(basename "$p")"
        ( cd "$scratch" && git apply -p1 --check "$p" ) || true
        rc=1
      fi
    done
    exit $rc
    ;;
  --revert)
    for ((i=${#PATCHES[@]}-1; i>=0; i--)); do
      p="${PATCHES[$i]}"
      if git apply --reverse --check "$p" 2>/dev/null; then git apply --reverse "$p"; fi
    done
    echo "psx: reverted local patches (pristine pinned core)."
    exit 0
    ;;
  apply|"")
    head="$(git rev-parse HEAD)"
    [ "$head" = "$PIN" ] || echo "warning: psx at $head, expected pinned $PIN; patches may not apply cleanly." >&2
    # Fast path: the patches form a STACK (later ones extend the same regions
    # earlier ones add). The topmost patch on each file reverse-checks clean iff
    # the whole stack is already applied; so if the LAST patch reverse-applies,
    # everything is in place -- skip the per-patch dance (whose isolated reverse-
    # check gives false negatives on bottom-of-stack patches like 0001, forcing an
    # unnecessary reset+reapply of the whole tree).
    if [ "${#PATCHES[@]}" -gt 0 ] && \
       git apply --reverse --check "${PATCHES[${#PATCHES[@]}-1]}" 2>/dev/null; then
      for p in "${PATCHES[@]}"; do echo "already applied: $(basename "$p")"; done
      exit 0
    fi
    for p in "${PATCHES[@]}"; do
      [ -f "$p" ] || { echo "error: missing patch $p" >&2; exit 1; }
      if git apply --reverse --check "$p" 2>/dev/null; then
        echo "already applied: $(basename "$p")"
      elif git apply --check "$p" 2>/dev/null; then
        git apply "$p"; echo "applied: $(basename "$p")"
      else
        # partial/conflicted: reset ONLY this patch's files to the pinned state, then apply
        echo "note: resetting patch-touched files to pinned state, then applying $(basename "$p")" >&2
        # shellcheck disable=SC2046
        git checkout -- $(touched_files)
        git apply "$p"; echo "applied (after reset): $(basename "$p")"
      fi
    done
    exit 0
    ;;
  *)
    echo "usage: $0 [apply|--check|--revert]" >&2; exit 2
    ;;
esac
