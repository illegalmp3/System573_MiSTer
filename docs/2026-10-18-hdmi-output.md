# HDMI output back in the core -- 2026-10-18

Every bitstream since 2026-09-10 was built CRT-only (`-Crt`, MISTER_DEBUG_NOHDMI):
the HDMI scaler (ascal) and its PLL were left out for room. This puts HDMI back,
so one .rbf drives a TV over HDMI and a CRT from the analog port at the same time.

## Measurements (all HDMI builds, Quartus 17.0.2)

| build | change | ALMs needed | LABs | DSP | result |
|---|---|---|---|---|---|
| CRT seed 5 (job 241) | reference, no HDMI | 36,637 | 4,140 | 90 | timing met |
| M1 (316) | HDMI in + upstream PSX.qsf macros DOWNSCALE_NN, DISABLE_ALSA | 41,478 (99%) | 4,191 | 109 | **did not route** |
| M2 (317) | M1 + no register duplication + COMBO_LOGIC_FOR_AREA | -- | -- | -- | quartus_fit access violation (build PC) |
| M3 (318) | M2 + PSX-console options tied off | **38,804** | 4,187 | **97** | routed; pll_hdmi setup -0.075 |
| M4 (320/321) | M3, seeds 3 / 6 | 38,917 / 38,899 | | | -0.129 / -0.218 |
| M5 (322) | M3 + register duplication on | 38,804 | | | byte-identical rbf to M3 |
| **M6 (326)** | M5 + psx_patches/0032 (ascal PALETTE off) | **38,903 (93%)** | 4,181 | 97 | **met: setup +0.035, hold +0.069** |

## What changed

1. **Konami_System_573.qsf**: `MISTER_DOWNSCALE_NN` and `MISTER_DISABLE_ALSA`, both set
   by the upstream PSX core's own psx/PSX.qsf. ALSA is Linux audio into the core output;
   the 573 MP3 reaches the mixer through its own DDR3 ring. `PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA`
   (also upstream) added. Register duplication made no measurable difference (M3 = M5 byte for byte).
2. **rtl/emu.sv -- PSX-console options tied to their defaults** (local/hdmi/prune_psx_options.py):
   texture filter, widescreen hack, old GPU, render/dither 24 bit, 480p hack, rotate, FPS /
   error / CD / LBA overlays, turbo, PAL60 hack, CD speed/seek/lid options, GPU slowdown,
   crosshair, NeGcon rumble, the dead Fastboot / RAM(Homebrew) / SPU RAM select, and their
   OSD lines. Each is tied to its first OSD choice = the value every 573 session has run at
   (no System573.CFG exists on the card). Cost recovered: ~2,670 ALM and 12 DSP (M1 -> M3).
3. **psx_patches/0032**: ascal `PALETTE("false")`. After 2., the only failing path was the
   framebuffer palette read `pal1_mem -> o_hpix2` (-0.075 ns, slow -40C). That palette serves
   only the Linux framebuffer's 8 bpp mode (Main video.cpp FB_FMT_PAL8, reachable only through
   the `vmode` command); this core's framebuffer is 16/24 bpp (emu.sv FB_FORMAT) and Main's
   fb_enable uses 8888.

## Kept

Aspect ratio, scaling, crops, deinterlacing, "Sync 480i for HDMI", dithering, stereo mix,
"Pause when OSD open", all 573 options. The YC/composite encoder stays (the test setup's CRT is
on S-Video). Bicubic scaling stays off (psx_patches/0028).

## Build PC

The i9-14900KF crashed Quartus repeatedly and blue-screened once (0x3B, 12:19 2026-10-18)
with corrected machine checks around it. BIOS updated 1812 -> 1837 (ASUS Z790 GAMING WIFI7);
M5 and M6 ran clean afterwards, and M5 reproduced M3's rbf byte for byte.

## Hardware test (2026-10-18, SuperStation One)

HDMI TV and CRT over composite driven at the same time from this build: both show the
game. The log of that session (s573mp3.log, two sessions, ~6 + ~4 min):

* ddrextrm, 2 songs: underrun 0, stalls 0, rewinds 0; 99 % of frame flips one vblank
  apart (60 fps). Two OSD pauses mid-song (~1 s and ~7 s): watchdog kicks and frame
  flips at 0 while the MP3 `played`/`rd` counters stood still for exactly those
  seconds, then resumed with no underrun -- the 2026-10-02 pause fix, seen in the log.
* ddr3mj, 2 songs (streams from CD): underrun 0; flips mostly two vblanks apart, its
  normal 30 fps arrows.
