# The HPS MP3 service, reconstructed — `support/s573/`

**Date:** 2026-09-11 · **State:** written, host-tested, **not yet compiled for ARM and
never run on silicon**

`docs/2026-09-10-ddr-gap-hps-service.md` recorded that the download's status table claims
"MP3 decode (HPS-side service) — ✅ plays on real hardware" for code that **is not in this
repository**. This is that code, written back from the RTL contract and the four write-ups
the previous project left behind. It is the difference between a DDR title booting silent
and a DDR title being playable — ddrsbm's `ready` loop reads the decoded-frame and
sample counters as timing feedback, so gameplay does not advance without it.

Also confirmed while checking: `/media/fat/MiSTer` on the SD card is **stock** (2026-07-24,
1,059,560 bytes, zero `s573` strings), so there was no fork binary to recover.

## What is here

| file | what it is | lines |
|---|---|---|
| `support/s573/s573_descramble.{c,h}` | the descrambler, **copied unchanged** from `sim/spike_b_descramble/` | 7.1 KB |
| `support/s573/s573mp3_core.{c,h}` | the portable core: ring math, epoch/reset protocol, config adoption, the input sliding window | 214 + 260 |
| `support/s573/s573mp3.cpp` | the Main-side glue: mmap, the four SPI commands, minimp3, the poll hook | 454 |
| `support/s573/tests/` | 14 host-test groups + three mutation defines | — |

The descrambler is the one piece that needed no work: the decision-B spike proved that C
reproduces the fabric's emitted byte stream **bit-exactly** — 31/31 cases, 45,377 bytes,
with a diagnostically specific negative control. It is copied verbatim rather than
re-derived, and the test suite re-checks its resumability property in place (the same
window pulled in 7-byte chunks must equal the one-shot pull, and both must be 2N−1).

## The four defects that are pre-cleared

Each one cost the previous project a hardware session, and each has a host test whose
mutation define restores the bug. `make mutate` in `tests/` currently reports:

```
S573_MUT_WROTE_MASK15:  RED (good)
S573_MUT_FREE_MASK15:   RED (good)
S573_MUT_APPLY_NOFLUSH: RED (good)
MUTATION CHECK: PASS
```

That discipline is the direct lesson of `2026-08-02-mp3-stale-pcm-residue.md`, where
restoring one of the two masks left the suite **still passing** — "a suite that passes both
before and after a fix is not evidence."

1. **The core-name gate.** This core's CONF_STR still begins `"PSX;..."`, so Main's
   `orig_name` is `"PSX"` and a gate written against `"Konami_System_573"` can never match.
   The 573-specific name is the `.mgl` `<setname>`, `System573`. All six of our `.mgl`
   files set it. **Consequence worth repeating in every runbook: launching the bare `.rbf`
   gives no MP3 audio.**
2. **`cfg_epoch` adopted as 8 bits while compared as 16.** `CMD_573_MP3CFG` word 0 carries
   `cfg_epoch[7:0]` by design; the authoritative 16-bit value rides the hot `CMD_573_PTRS`
   poll. `s573_core_apply_cfg()` therefore takes the authoritative epoch as an explicit
   parameter and uses the 8-bit echo *only* as a torn-read detector.
3. **The ring pointer's wrap MSB.** `hps_wr_ptr`/`fab_rd_ptr` are `[15:0]` and the fabric's
   `have_data` compares all of it. `s573_core_pcm_byte_off()` is the single place the MSB is
   masked, and it is commented as such — the companion half of this bug is a `memcpy` that
   runs off the end of the mapping once the pointer is widened without masking there.
4. **No discard of decoded PCM on a re-arm.** The flush is gated on a **new window or new
   keys**, not on an enable edge (a bare pause/resume should keep its buffer, or the song
   fast-forwards by 1.49 s), and on the drain state **before** the adoption.

## Four deliberate deviations from what upstream ran

Recorded because each is a place a future session might "fix" back:

1. **The gate lives in `s573mp3.cpp`, not in a patch to Main's `user_io.cpp`.** Upstream
   patched `is_573()` into `user_io.cpp`, and the WORKING write-up names that as a classic
   untested boundary — a perfect unit that was never invoked. Keeping the gate local means
   the fork touches Main in exactly two places (a `#include`-free call in `user_io_poll()`
   and the Makefile), which also makes rebasing onto upstream cheap.
2. **`s573_core_ring_collapse()` parks at `rd + 1`, not at `rd`.** `rd` looks like the
   "true empty" answer and is wrong: if the ring reader has already committed to the beat at
   our snapshot it will complete and increment once more, and `wr == rd` then reads
   `(wr - rd) == 0xFFFF` — the fabric would replay the entire ring twice. `rd + 1` lands on
   empty either way. Upstream's measured `wr == rd+1` (26/26) is therefore not an artifact
   of their implementation; it is the requirement.
3. **`s573_core_refill()` clamps `in_pos` to `in_len`.** An out-of-range cursor makes the
   unsigned difference wrap and `memmove` about 4 GiB. The caller never does that — but
   "the caller never does that" is exactly how the 15-bit mask survived, and the clamp costs
   one compare. It has its own test.
4. **`S573MP3_ATTEN=0..100` instead of applying the MAS3507D gain matrix.** The clipping
   item from `2026-07-31-mp3-audio-WORKING.md` is still open (peaks at +1.17 and
   +1.64 dBFS). `CMD_573_MP3CFG` does carry `gain_ll`/`gain_rr` and a sticky `gain_seen`,
   and the service logs all three — but the encoding of that 20-bit matrix is not
   established anywhere in this tree, and guessing it risks silence or distortion. So the
   default is unity, the numbers are visible in the heartbeat, and there is an honest knob.

## Diagnostics (opt-in, off unless the env var is set)

- `S573MP3_HB=1` — one state line per second: epochs, input cursor, credit, frame counters,
  ring pointers and free space, `ctrl_flags`, `underrun_cnt`, buffer level, flushes, beats
  dropped, torn reads. Every field retires a specific doubt; `evt_ovf` and any nonzero
  `underrun_cnt` print their own loud line.
- `S573MP3_TONE=1` — pushes a known tone through the **same** ring path, to bisect delivery
  from decode. Upstream built this and never needed it; it is still the right first
  instrument if the audio goes silent.
- `S573MP3_ATTEN=n` — MP3-channel level in percent.

**`debug=1` must be set under `[MiSTer]` in `MiSTer.ini` or none of this prints.** `cfg.cpp`
reassigns the global `stdout` to `/dev/null` while parsing the INI, and three rebuild cycles
were lost to that once already. An empty log is not evidence.

## The build path — no Docker, and nothing to install

The Makefile wants `arm-none-linux-gnueabihf-` (ARM's published toolchain), not Debian's
`arm-linux-gnueabihf-`. The convenient host turned out to be one that is already here: the
Linux VM this session drives on the Mac is **aarch64 Ubuntu 22.04, 4 cores, 3.9 GB RAM**,
with `~/Documents` mounted read/write **and executable**, and ARM publishes an
aarch64-hosted build of exactly that toolchain. So the build runs in the VM, under the
agent, with no Docker Desktop, no Homebrew tap, no sudo (the toolchain is a tarball, not a
package) and no macOS host/BSD-tooling differences.

The VM has **no network**, so the three inputs are fetched on macOS into `~/Documents`:
`Main_MiSTer` source, `arm-gnu-toolchain-13.3.rel1-aarch64-arm-none-linux-gnueabihf.tar.xz`,
and `minimp3.h`.

Deploy needs no SSH — which matters, because this console has none. `MiSTer_Data` mounts
over USB, so the binary is copied to the SD card directly, with the stock one kept as
`MiSTer.orig` first.

## What is NOT verified

Everything on hardware. Specifically, and in the order the transport design's own plan puts
them:

1. **`spi.h` / `user_io.h` signatures.** `s573mp3.cpp` is written against the mailbox
   contract but has not yet seen Main's headers. First compile is the check.
2. **Visibility** — that the HPS's mapping of `0x32000000` sees the same bytes the fabric
   sees. Nobody has mmap'd that window on hardware; it is strongly inferred from
   `tools/mister_vram_dump.sh` working at `0x30000000` and never executed. The decisive
   build-free check is step 7 of the design plan: dump a window at
   `0x32000000 + mp3_start` and byte-compare it against the scrambled MP3 in the disc image.
   A match proves the write path, the address map and cross-agent visibility in one shot,
   **without needing the keys**.
3. **Ring placement (must-fix #2).** `0x33F10000` is still marked PROVISIONAL in
   `rtl/s573_pcm_ring.v` and has never been confirmed clear of ddrsbm's actual
   top-of-window sample-RAM usage. Wrong means silent live-data corruption.
4. **Word alignment.** The key schedule is per-word stateful with no resync point, so one
   skipped or duplicated word yields plausible-but-wrong audio while `0xa8`/`0xca`/`0xcc`
   all read GREEN. This is why step 7 is mandatory rather than optional.
5. **The early-stop case.** A *failed stage* aborts a song before `cur` reaches `mp3_end`,
   and the exhaustion backstop cannot see it. Upstream left this open with MAME named as
   the next instrument, and it is still open here.
