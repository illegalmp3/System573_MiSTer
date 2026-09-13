# ddrusa: the ZS01 packet engine has never existed in hardware

**Date:** 2026-09-13
**Symptom:** `ERROR 121 CASSETTE ERROR (3) / CASSETTE DOES NOT MATCH THIS GAME (G*A44UAA)`
**Status:** root-caused. The fix is a rewrite, not a patch.

## The finding

`rtl/zs01.v` lines 324-379 -- `decrypt_cmd`, `decrypt_data`, the CRC check, the
entire read/write command dispatch and `encrypt_resp`, 54 lines, the whole
security-packet engine -- sit inside a `// synthesis translate_off` block.

Quartus deletes all of it. In the shipped bitstream the ZS01 is:

* a correct response-to-reset (that path is outside the block, so the game's
  cartridge-type probe sees `5a 53 00 01` and correctly identifies a ZS01),
* an I2C shift register that accepts all 12 command bytes and acknowledges them,
* and then **nothing**. No descramble, no CRC, no dispatch, no response.

The cassette image loads correctly into `data[]` and can never be read back out:
the module's own header says so, and the read port is hardwired --
`rd_addr <= 7'd0; // (read port unused in HW; tied for inference)`.

So the game identifies the cassette as a ZS01, issues an authenticated read, gets
nothing back, and reports that the cassette does not match. Which is exactly true.

## Why every instrument said it was fine

* **`make zs01` passes** -- simulation compiles all 54 lines. Simulation and
  hardware were literally running different source. Every ZS01 bench result on
  this project describes code that has never been on the FPGA.
* **The round-trip is structurally blind anyway.** The bench encrypts with its own
  transliteration and decrypts with ours; a self-consistently wrong cipher passes
  it every time. Even fully synthesized, that test could not detect a wrong
  algorithm.
* **The SDA-on-D0 fix (`960920a`) changed nothing visible** -- it was real and
  necessary (the wiring genuinely ignored the data latch), but it fixed the
  delivery of command bits to an engine that does not exist in hardware. A
  correct fix, invisible behind a larger absence.
* **The dump was never the problem.** Verified this session with
  `tools/stage_zs01_u1.py`: RtR `5a530001`, command key byte-identical to
  `zs01.v`'s `COMMAND_KEY`, game code `GKA44`, DS2401 `d202030405060701` found
  byte-reversed at `data[40]`, staged file 4116 B and matching the dump.

## Why it was excluded, and why that reason expired

The block's own comment: unrolled ciphers + CRC + two 112-byte full-array clears,
all in one clock edge -- "Quartus-hostile", justified as safe because "the
security cart is bypassed at BIOS boot (gchgchmp no-security path), so it never
runs there." True for `gchgchmp`. False for `ddrusa`, and for every ZS01 title.

The engineering judgement was right: that code cannot synthesize. What was wrong
was leaving it silently absent rather than unimplemented-and-loud.

## Contrast: why dsem works

`x76f041.v`'s excluded block is 11 lines of convenience -- bulk-clearing small
config arrays on a mass-erase the BIOS never issues at boot. Its actual engine is
fully synthesized, which is why the X76F041 authenticated on hardware first try.

Repo-wide audit of every `translate_off` block: `zs01.v` 324-379 is the **only**
one containing cipher/CRC/packet work. All 13 others are <= 11 lines and benign.

## The fix

Re-implement the engine as a sequential multi-cycle FSM. The timing budget is
generous -- the host clocks I2C far slower than `clk_1x`, and a whole stop/start
plus byte-times separate the command from the response read:

| stage | work | ~clocks |
|---|---|---|
| `decrypt_cmd` | 12 bytes x 7 key rounds, one round/clock | 84 |
| `decrypt_data` | 8 bytes x 7 rounds (when `cmd & 0x04`) | 56 |
| CRC-16 over bytes 0..9 | byte-serial | ~80 |
| `0xFD` erase | 112-byte clear through the single write port | 112 |
| `encrypt_resp` | 12 bytes x 7 rounds | 84 |

`data[]` reads must go through a real `rd_addr` into the registered `data_rdata`
instead of the tied-to-zero port, keeping the M10K template intact.

**And the bench must change with it.** A round-trip against our own cipher is not
a test. The new bench needs stimulus from outside the design -- a recorded real
transaction, or a reference vector -- or it will go green on a wrong algorithm
exactly as the current one does.

## Cost

One more bitstream minimum, and the cipher correctness question is still open
underneath this one: it has never been tested against anything independent.
