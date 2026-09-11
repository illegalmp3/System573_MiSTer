# The descrambler is verified against the real disc — 52/52 songs, no hardware

**Date:** 2026-09-11 · **Tools:** `tools/s573_oracle/` · **Input:**
`dumps/mame573/894jaa02.chd` (the ddrsbm disc)

## What was closed

The decision-B spike proved `s573_descramble.c` reproduces the fabric's emitted
byte stream bit-for-bit — 31/31 cases, 45,377 bytes, with a discriminating negative
control. But it named its own limit, and the limit was real:

> the existing `tb_k573_mp3dec` reference model is a **transliteration of the RTL's
> own functions**, so the "44/44 green" never tested fidelity — it tested
> self-consistency.

So the descrambler and the RTL agreed with each other, and nothing tied either of
them to what Konami actually put on the disc. That gap is now closed, and it took no
board, no MAME, and no keys from the running game.

## Method

ddrsbm's descramble scheme uses **only `key1`** (`s573_desc_step()`: `dec_common`,
then `rotl 1` per word; `key2`/`key3` are untouched on that path). A 16-bit seed is
a 65,536-key space, so the key can be recovered from the ciphertext by asking what
makes the plaintext look like MPEG audio.

1. `chd_extract.c` — CHD → ISO user data, built natively against Main's vendored
   `libchdr`. MAME stores a CD as interleaved 2352-byte sectors plus 96 bytes of
   subcode, so a whole-hunk dump has subcode spliced through it every 2352 bytes and
   no contiguous match can ever hit; this strips the subcode and each sector's
   16-byte sync/header, leaving the 2048-byte Mode-1 payload.
2. `findkey.c` — for each 2-byte-aligned offset and each of the 65,536 seeds, descramble
   and require a **chain of 20 consecutive MPEG-1 Layer III frames** at exactly the
   computed frame lengths, with a constant bitrate.
3. `verify_chain.c` — descramble the whole window with the **shipping**
   `support/s573/s573_descramble.c` and decode it with the **shipping**
   `lib/minimp3/minimp3.h`, then check the decode ACCOUNTS FOR the window:
   duration × bitrate must come back to the byte count, with almost no skipped frames.

The oracle is independent by construction: MPEG frame structure and a decoder that
knows nothing about Konami.

## Result

**52 of 52 song files pass.** Every one descrambles cleanly and decodes as continuous
audio, with the decode accounting for 99–100% of the descrambled bytes:

| | |
|---|---|
| song files on the disc | 53 (`D_01`…`D_53`) |
| PASS | **52** |
| FAIL | 0 |
| no key found | 1 — `D_01.DAT`, which is **2048 bytes**: there is no song in it |
| format, every single file | **44100 Hz, stereo, 128 kbps CBR** |
| durations | 18.5 s – 187.5 s |
| MP3 offset inside every file | **0x40** |

The per-file keys are in `tools/s573_oracle/ddrsbm_key1.txt`.

### The corroboration that makes the 0x40 meaningful

The MP3 payload starts at offset **0x40** in every file. Independently, the
`mp3_start` values the game programmed **on silicon** (captured 2026-07-31) are:

```
0x0067B840   0x006C4040   0x00A72840   0x0079C840
```

Every one ends in **0x40**. Two unrelated sources — a static disc image parsed here,
and the game's own register writes observed on a board six weeks ago — agree on the
same payload offset. Neither was derived from the other.

### The negative control

Flipping one bit of a correct key (`0x3395` → `0x3396`) decodes **0 frames**. The
first version of `findkey` required only a 4-frame chain and produced 14 false keys
across the disc; `verify_chain` rejected all 14, and raising the requirement to 20
frames eliminated them. Worth keeping as a method note: the cheap test was wrong 27%
of the time, and it was the *second*, independent check that caught it — not a
tighter version of the first.

## What this retires, and what it does not

**Retired:**
- The descrambler is faithful to real Konami data, not merely to the RTL.
- minimp3 decodes this game's files, at the one rate that matters: every file is
  44100 Hz stereo, exactly what the fabric's fixed 44100 drain expects. **No
  resampler is needed** — and the service's "wrong sample rate" warning should never
  fire on ddrsbm.
- The 2N−1 last-byte rule and the resumability of chunked pulls are exercised over
  ~67 MB of real data rather than 45 KB of synthetic windows.

**Not retired:**
- **Visibility.** That the HPS's mmap of `0x32000000` sees what the fabric sees is
  still untested. The `dump=1` path answers it.
- **Ring placement (must-fix #2).** Still open; the boot probe answers it.
- **Word alignment on hardware.** The disc data is aligned by construction here; a
  one-word slip in the live path is exactly the failure this cannot see, which is why
  the `dump=1` byte-compare stays mandatory.
- **The 2N−1 boundary is still MAME-oracle-derived, not silicon-derived.** Both sides
  implement it, so if real DIO silicon emits 2N, both are wrong together.

## A useful side effect

`tools/s573_oracle/` is now a standing regression test that needs no board: change
the descrambler and 52 real songs either still decode or they do not. Before this,
the only check available was agreement with a model transliterated from the same
source.
