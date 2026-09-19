# ddrextrm: the background-video path, read from the sources

**2026-09-18.** Baseline `ed00df8` (the four 09-17 instrumentation commits dropped and
bookmarked on `instr-mdec-a182001`). Symptoms under study, all reported from the
cabinet on ddrextrm: arrow scrolling drops below 60 fps whenever the background
video is "busy", recovers to 60 on near-static backgrounds, and the background
videos themselves play at roughly half speed.

Everything below is taken from a source file and cited; nothing is a hardware
guess. Where the sources run out, that is said explicitly.

## 1. What the game actually does per video frame

Source: `out/re/ddrextrm_GAME.DAT`, main executable at flash offset `0x80000`
(`PS-X EXE`, load `0x80010000`, size `0xde800`, entry `0x80017d98`), disassembled
with `tools/s573_oracle/mipsdis.py`.

* The movies are `data/movie/common/<name>.sbs` (string at `0x800146cc`). On the
  disc (`b19jaa02.chd`, DDRMAX — same generation and format as EXTREME) every
  `/MOV/*.SBS` is exactly 655,360 bytes: **80 frames in fixed 8 KB slots**, each
  slot starting with a plain PSX **BS v2 frame header**
  (`mdec_len, 0x3800, q_scale, version=2`), no STR sector wrapper. Read with the
  new `tools/chd5.py` (CHD v5 cdlz/cdzl in pure Python; the existing
  `chd_extract.py` is v3/v4 only).
* The player is Sony **libpress**, linked into the game — its I/O address table is
  at `0x800db0f0` (`0x1f801080..` DMA0/1, `0x1f801820/24` MDEC, `0x1f8010f0` DPCR) and
  its error strings `MDEC_in_sync` / `MDEC_out_sync` / `MDEC_rest:bad option` sit at
  `0x80015088`. Identified routines:

  | address | routine | what it does |
  |---|---|---|
  | `0x80073804` | `DecDCTvlc` | **CPU** VLC → MDEC-code expansion, one call per frame |
  | `0x800734f4` | `DecDCTin` | DPCR\|=0x88; DMA0 MADR=buf+4, BCR=(n>>5)<<16\|0x20, MDEC0=buf[0], CHCR=0x01000201 |
  | `0x80073584` | `DecDCTout` | blocking wait for DMA1 idle, then DMA1 MADR=img, BCR=(n>>5)<<16\|0x20, CHCR=0x01000200 |
  | `0x80073610` / `0x800736a4` | in/out sync | spin on DMA0 / DMA1 `CHCR.24`, 0x100000 tries, then print the error |
  | `0x80073404` | `DecDCTReset` | MDEC1=0x80000000, DMA0/1 CHCR=0, MDEC1=0x60000000 |
  | `0x8007329c` | game wrapper | `DecDCTin(buf, mode)`: mode bit1 → sets cmd bit 25 (bit15 flag); bit 27 stays set → depth "11" = **15-bit output** |

* Frame size: the movie state block (`*(0x801afbf4)`) has `width` at `+0xbc`,
  `height` at `+0xbe`; the default set at `0x80070fa0` is **304 × 176**
  (`addiu v1,zero,0x130` / `addiu v0,zero,0xb0`), and the setter at `0x80072f10`
  clamps to ≤320 × ≤240. 304 × 176 = **19 × 11 = 209 macroblocks** per frame.
  `DecDCTout` is called with `size = width*height/2` words (`0x80072190..0x800721b8`),
  i.e. 26,752 words = 836 DMA blocks of 32.
* The per-frame kick at `0x80072110..0x800721d8` is **non-blocking and aborting**:
  it polls `DecDCTinSync(1)` (MDEC status bit 29) and `DecDCToutSync(1)` (DMA1
  busy); if either says busy it calls **`DecDCTReset(1)` and starts the next frame
  anyway** (`0x80072140..0x8007218c`). Frame 0's header says `mdec_len = 0x0e60` →
  3,680 words = 7,360 MDEC codes for that frame.

So per video frame the machine does: CPU VLC decode → DMA0 3,680 words in →
MDEC decode of 209 macroblocks at 15-bit → DMA1 26,752 words out → (LoadImage
of the 107 KB image into VRAM via DMA2). If the MDEC is still busy when the game
wants the next frame, the game resets it and the frame is lost — that is the
mechanism by which a slow MDEC turns into a slow-motion video without any error.

## 2. What the vendored PSX core's MDEC costs per macroblock

Source: `psx/rtl/mdec.vhd` (identical between the pinned `67153439` and upstream
`main` `cd17b5a`, 2026-08-21 — upstream has touched only `cd_top.vhd` and `spu.vhd`
since our pin). The IDCT, colour and output processes run on **clk2x = 67.7376 MHz**
(`rising_edge(clk2x)` at lines 791, 1000, 1144).

| stage | cycles (clk2x) | where |
|---|---|---|
| IDCT, 2 passes × 4 u-steps × 64 = 512 per block, 6 blocks | **3,072** | lines 830–890 |
| **`IDCT_WAIT` in 15-bit mode** (10 in every other depth) | **2,171** | lines 806–809, 896–902 |
| colour convert, 5 states × 256 pixels + 4 | 1,284 | lines 1038–1090 |
| output read → FIFO, 256 | 256 | line 1177 |
| DMA1 drain of 128 words (can only partly overlap: `FifoRL_Rd` needs `FifoOut_Empty`, line 672) | ~300 | |

IDCT + wait alone: 5,243 clk2x = 77.4 µs per macroblock → **16.2 ms for one 304 × 176
frame**, before colour/output/DMA. With the rest, ~18–22 ms. A 60 Hz frame is 16.7 ms.
The wait is therefore the single largest item and, on its own, makes one video frame
cost more than one game frame.

Where 2,171 comes from — `git log -S2171 -- rtl/mdec.vhd` in the vendored clone:

> `9530638` 2022-11-05 Robert Peip — *"MDEC: reduce decoding speed for 15bit mode
> (fixes Parasite Eve 2 FMV-ingame stuttering)"*

The commit adds the `IDCT_WAIT` state and the constant with no measurement cited;
24-bit output, which moves more data, keeps the 10-cycle wait. It is a
compatibility slowdown for one title, not a characterisation of the chip.

Other references checked for a real-hardware figure:

* psx-spx (MDEC chapter) — documents formats and the "blocksize 20h" DMA
  convention, **no decode timing at all**.
* Sony Psy-Q docs (`mdecnote.pdf`, Fall '96 MDEC seminar) — no throughput numbers.
* DuckStation `mdec.cpp` — `TICKS_PER_BLOCK = 448`, scheduled as `448 × 6` per
  macroblock **for every depth** = 2,688 clk1x = 79 µs (16.6 ms per 304 × 176 frame),
  again an emulator model, not a measurement.
* MAME's `psxmdec` decodes instantly, so it is no reference for speed.

**Conclusion of the source search:** no document gives the real MDEC's speed. The
one hard fact from the game side is that DDR EXTREME on a real 573 plays these
videos at full rate at 60 fps, so the real chip decodes a 304 × 176 15-bit frame
comfortably inside the game's cadence; both emulator models put it right at or
above 16.7 ms. The 2,171-cycle wait is the only number in the pipeline that is
neither derived from the algorithm nor from a document.

## 3. What is still not explained by the sources

The MDEC cost explains **dropped/slow video**. It does not by itself explain the
**game** dropping to 30 fps, because the game's decode path is asynchronous (it
polls, and aborts rather than waits). The CPU-side work that only exists while a
video plays is: `DecDCTvlc` (~7,400 codes per frame, all RAM loads/stores — the
R3000 has no data cache), the 107 KB `LoadImage` per displayed frame, and whatever
`DrawSync`/`VSync` spinning the game does around them. Run C (09-17) measured the
levels — MDEC 24.6 %, GPU 10 %, DMA-paused 3.5 %, CPU memory-stall 13.6 % — but a
level cannot tell a spin-wait from real work, so it did not say *where* the CPU's
33 ms go. That needs a PC profile, not more occupancy counters.

## 4. Files

* `tools/chd5.py` — CHD v5 reader (map Huffman per `chd.cpp::decompress_v5_map`,
  `cdlz`/`cdzl` per `chdcodec.cpp`), `--info / --ls / --get`.
* `out/re/ddrextrm_game.bin` — the extracted main executable (load `0x80010000`).
