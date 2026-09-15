# Tier 3: PCMCIA linear flash card — source-grounded design

Status: DESIGN (no RTL written yet). Target title: **ddr4m** (DDR 4th Mix, G*A33 VER. AAA).
Every claim below is cited to MAME `mame0288` sources the user supplied in
`dumps/mame573/` (`ksys573.cpp`, `bus/pccard/pccard.{h,cpp}`,
`bus/pccard/linflash.{h,cpp}`, `machine/intelfsh.{h,cpp}`) or to this repo's RTL.
Nothing here is inferred from "how it probably works".

---

## 1. What ddr4m actually needs (the delta from a working Tier-2 title)

`ksys573.cpp:6542` — `GAME(2000, ddr4m, sys573, ddr3mp, ddr, ddr_state, ...)`.

`ddr3mp` (L2779-2788):
```
k573d(config);                                  // digital I/O board  -> DONE
m_k573dio->output_callback() = ddr_output_callback;
pccard2_32mb(config);                           // <-- THE ONLY NEW HARDWARE
cassxzi(config);                                // X76F041 install + ZS01 game -> DONE (dsfdr)
KONAMI_573_MEMORY_CARD_READER(config, "k573mcr", ...);   // JVS memcard reader -> open question
```

Compare `dsfdr` (L2833-2839), which is **already installed and playable** on hardware:
```
k573d(config); ddr_output_callback; cassxzi(config);
```

So ddr4m = dsfdr **+ a 32 MB PCMCIA card in slot 2** + the JVS memory-card reader.
The ROM sets confirm it: `ddr4m.zip` and `dsfdr.zip` are byte-for-byte the same shape
(bios, `digital-id.bin`, `h8a01/h8b01`, a `gea33aa.u1`/`.u6` X76F041 install cassette and a
`gca33aa.u1`/`.u6` ZS01 game cassette) except ddr4m additionally carries `885a01.bin` —
a file that appears **nowhere in ksys573.cpp**, i.e. it belongs to the `k573mcr` device,
not to the mainboard.

`ROM_START(ddr4m)` (L4149-4166) declares **no** `pccard*` ROM regions: the card starts
blank and the install CD (`a33aaa02.chd`, present in `dumps/mame573/`) writes it.

### R1 — the JVS memory-card reader: RESOLVED, low risk (k573mcr.cpp, 2026-09-14)
`KONAMI_573_MEMORY_CARD_READER` is in `ddr3mp` but not in `dsfdr`. With the source in
hand the answer is clear enough to proceed without it:

* `k573mcr_device : jvs_device` — it is a **JVS bus peripheral**, not mainboard hardware.
  `device_id()` returns `"KONAMI CO.,LTD.;White I/O;Ver1.0;White I/O PCB"`.
* `885a01.bin` (the extra file in `ddr4m.zip` vs `dsfdr.zip`) is its own ROM:
  `ROM_START(k573mcr) ROM_REGION(0x080000,"tmpr3904") ROM_LOAD("885a01.bin", ...)`.
  It is the reader's TMPR3904 firmware, downloaded over JVS by the game
  (`handle_message` 0x70 buffer write / 0x70 0x02 set-exec / 0x73 execute).
* Everything it does is **player-facing, not boot-gating**: PS1 memory-card block
  read/write (`0x76 0x74` / `0x76 0x75`), a GE885-JB security dongle read (`0x72`),
  and PSX controller ports (`0x77`, explicitly "Only used by Guitar Freaks").
* Our `s573_io.v` already reports JVS sense = 1 (`r_misc[3]`, "no I/O board attached"),
  and every DDR title tested so far (dsem, ddrusa, dsfdr) takes the graceful-skip path
  on that and runs from JAMMA inputs. There is no reason ddr4m's bootloader would treat
  a missing *memory-card* reader differently from a missing I/O board.

**Decision: build and test the card path without the reader.** If ddr4m dead-ends with a
JVS / "White I/O" complaint, the reader is an ordinary JVS device we can add afterwards —
and `k573mcr.cpp` is now in `dumps/mame573/` when that day comes. Note MAME's own comment
at `case 0xf0` (the bootloader initialises the JVS device, then the game re-initialises it
and throws "JVS SUBS RESET ERROR" unless the device resets) — a warning about the *order*
of JVS resets, worth remembering if we ever do implement it.

---

## 2. How the 573 addresses a PCMCIA card (authoritative)

### 2.1 The bank window
`ksys573.cpp:966` — the CPU sees one 4 MB window:
```
map(0x1f000000, 0x1f3fffff).m(m_flashbank, FUNC(address_map_bank_device::amap16));
```
`ksys573.cpp:2584` — `ADDRESS_MAP_BANK(config, m_flashbank).set_map(&flashbank_map)
                       .set_options(ENDIANNESS_LITTLE, 16, 32, 0x400000);`
→ stride 0x400000 **bytes**.

`ksys573.cpp:1149` — `m_flashbank->set_bank( m_control & 0x3f );` (raw, no shift;
`control` = the register at `0x1f500000`).

`flashbank_map` (L982-995):
| flashbank byte range | device | bank values |
|---|---|---|
| `0x0000000-0x0ffffff` | onboard 29F016A pairs 31m/31l/31j/31h | 0-3 |
| `0x4000000-0x7ffffff` | `pccard1` | 16-31 |
| `0x8000000-0xbffffff` | `pccard2` | 32-47 |

This matches `rtl/s573_flash.v` today (onboard = `bank < 4`, index `bank[1:0]`;
everything else reads 0xFFFF). **ddr4m uses pccard2 → banks 32-47.**

### 2.2 Inside the card
`pccard.h` — `read_memory(offs_t offset, u16 mem_mask)`; `offset` is a **word** offset
(the map is 16-bit wide).

`linflash.cpp` — `linear_flash_pccard_device` ctor:
`m_space_config("memory", ENDIANNESS_LITTLE, 16, 26, 0, amap)` and
`read_memory()` → `m_space->read_word(offset * 2, mem_mask)`.

`linear_flash_pccard_8bit_device<N>::amap` (linflash.cpp):
```
map.global_mask((N * 0x00400000) - 1);
for i in 0..N-1:
  map(0x400000*i, 0x400000*(i+1)-1).rw(m_l[i], intelfsh8::read/write).umask16(0x00ff);
  map(0x400000*i, 0x400000*(i+1)-1).rw(m_u[i], intelfsh8::read/write).umask16(0xff00);
```
`fujitsu_32mb_flash_card_device : linear_flash_pccard_29f017a_device<8>` → **N = 8 chip
pairs**, each pair = one low (`.nL`) + one high (`.nU`) x8 die.
`linear_flash_pccard_29f017a_device<N>::device_add_mconfig` instantiates
`FUJITSU_29F016A` for both lanes.
`intelfsh.cpp:201` — `fujitsu_29f016a_device : intelfsh8_device(..., 0x200000, MFG_FUJITSU, 0xad)`
→ **2 MB per die, maker 0x04, device 0xAD**.

So: 8 pairs x (2 MB + 2 MB) = **32 MB**, `global_mask = 0x1FFFFFF`.

### 2.3 The resulting address arithmetic (the thing to implement)
Card byte address = `(offset * 2) & 0x1FFFFFF`, where
`offset = (flashbank_addr - 0x8000000) / 2 = ((bank - 32) * 0x400000 + win_byte) / 2`.

In core terms, with `win_addr` = 16-bit word offset in the 4 MB window (`[20:0]`):

```
card_word[23:0] = { bank[2:0], win_addr[20:0] }      // 16 M words = 32 MB
chip_pair       = card_word[23:21]  ( == bank[2:0] )  // 0..7
```
`bank[3]` is the 64 MB-window mirror (`global_mask`) — **ignore it**, banks 40-47 alias
banks 32-39. Decode `pccard2 = (bank[5:4] == 2'b10)`.

Note the pleasing consequence: **one bank value == one chip pair**, exactly as onboard
(`bank[1:0]` == one onboard pair). The per-pair busy/erase bookkeeping in
`s573_flash.v` generalises from 4 pairs to 8 with no structural change.

### 2.4 Command set and sector geometry — identical to onboard
The card's dies are the same part as the onboard flash (`FUJITSU_29F016A`), so
`rtl/flash_nor.v`'s AMD/Fujitsu FSM, the dual-lane autoselect IDs
(`MFR=0x0404`, `DEV=0xADAD`), and the sector geometry all carry over **unchanged**:

`intelfsh.cpp` FM_ERASEAMD3 / `0x30` sector erase, default branch (29F016A sets neither
`m_sector_is_4k`, `m_sector_is_16k`, nor a boot-sector flag):
```
memset(&m_data[base & ~0xffff], 0xff, 64*1024);   // 64 KB per x8 die
```
Two dies per 16-bit word → **128 KB per 16-bit sector**, which is exactly the
`win_addr[20:16]` sector index `s573_flash.v` already uses. 32 sectors per pair,
256 sectors per card.

Chip erase `0x10` wipes `m_size` = 2 MB per die = **one pair = 4 MB of window**, again
the same span as onboard (`ERASE_CHIP_WORDS = 2097152`).

### 2.5 Card-detect line — a real bug we should fix while here
`ksys573.cpp:3197-3198` (port `IN1`, read at `0x1f400004`):
```
PORT_BIT(0x04000000, IP_ACTIVE_HIGH, IPT_CUSTOM) PORT_READ_LINE_MEMBER(pccard_cd_r<0>)
PORT_BIT(0x08000000, IP_ACTIVE_HIGH, IPT_CUSTOM) PORT_READ_LINE_MEMBER(pccard_cd_r<1>)
```
`m_pccard_cd[]` initialises to `{1,1}` (L549) and `linear_flash_pccard_device::device_start()`
calls `m_cd1_cb(0)`. So on the wire:

**0 = card INSERTED, 1 = slot EMPTY.**

`rtl/emu.sv:2401` drives `.pcmcia_present(2'b00)`, and `s573_io.v:116` places those two
bits straight into `r_misc[11:10]` (= `0x1f400006[11:10]` = `IN1` bits 26/27). So the core
**currently tells every game that both cards are inserted**, while `docs/MEMORY_MAP.md:81`
and `PLATFORM.md:88` claim it reports them absent. Harmless for Tier 1/2 (nothing reads it)
but the doc and the signal name are both wrong. Rename to `pcmcia_cd_n`-style semantics
(or keep the name and drive `2'b11` when no card is enabled) and fix both docs.

---

## 3. Where the 32 MB lives

### 3.1 Rejected: DDR3
DDR3 has room (0x34000000-0x35FFFFFF is clear of every user listed in PLATFORM.md's
"DDR3 map"), but `s573_ddram_arb.v` gives the PSX master **absolute** priority — a client
op only starts when the PSX side is completely quiescent (`psx_idle`). That is fine for
the DIO sample RAM (audio-rate streaming) but a PCMCIA read **stalls the CPU** via the
EXP1 wait handshake, so starving it behind VRAM/GPU traffic is a correctness-adjacent
latency risk, and it would cost a third arbiter client plus a DDR3-speaking saver.

### 3.2 Chosen: SDRAM at 0x02000000
Current SDRAM map (`rtl/emu.sv:868-880`):
| base | size | user |
|---|---|---|
| `0x00000000` | 8 MB decode (4 MB aliased, `S573_RAM4MB`) | PSX main RAM |
| `0x00800000` | 512 KB | BIOS |
| `0x01000000` | 16 MB | 573 onboard flash |
| `0x02000000` | **free** | |

Put the card at **`CARD_START = 0x02000000`, 32 MB, ending at 0x03FFFFFF.**

`psx/rtl/sdram.sv` addresses a chip with `{BA[1:0], A[12:0], col[9:0]}` = 25 word bits =
**64 MB per chip**, with `addr[26]` selecting the second chip. `0x03FFFFFF` is entirely
inside **chip 0**, so this needs **no** second-chip support — only an SDRAM module of
**64 MB or larger**. Ricky's DE10-Nano has the 128 MB module, so this is satisfied today;
the core should read `sdram_sz` (already wired, `emu.sv:665`) and refuse to enable the card
on a 32 MB module rather than silently wrapping (which is exactly the failure that moved
the onboard flash down to 0x01000000 in the first place — see the comment at `emu.sv:869`).

This choice reuses, unmodified, every proven piece of plumbing: the ch3 single-word
write-back, the ch4 128-bit burst line-fill, `s573_ch4_arb`, and `s573_flash_saver`.

---

## 4. RTL plan (lean — the fitter is at ~83 % ALM / 97 % LAB)

**Do not instantiate a second `s573_flash`.** Generalise the existing one.

1. **`rtl/s573_flash.v`** — widen the flat word address from 23 bits
   (`{bank[1:0], win_addr[20:0]}`) to 24 bits plus a region bit:
   - `internal  = (bank[5:2] == 4'b0000)`  (unchanged)
   - `is_card2  = (bank[5:4] == 2'b10)`
   - `sel       = internal | is_card2`
   - `pair[2:0] = internal ? {1'b0, bank[1:0]} : bank[2:0]`
   - `flat_word = internal ? {1'b0, bank[1:0], win_addr[20:0]}   // 24b, region 0
                           : {bank[2:0],        win_addr[20:0]}` // 24b, region 1
   - line-buffer tag gains the region bit; `er_busy` / `er_sector` / `er_chip_r` /
     `er_tgl` go from 4 entries to 4+8 = **12** (one per chip pair across both regions).
   - `flash_mem_addr` / `flash_wr_addr` gain one bit and a region flag; the parent adds
     `FLASH_START` or `CARD_START`.
   - Everything else — `flash_nor` command FSM, program write-through + ch3 write-back,
     the erase walker, the AMD status/`flash_ready` logic — is untouched.
2. **`rtl/emu.sv`** — `localparam [26:0] CARD_START = 27'h0200_0000;` and select the base
   from the region flag on the ch3/ch4 address adders. Drive `pcmcia_present` from the
   "card enabled" OSD bit with the corrected polarity (§2.5).
3. **`rtl/s573_flash_saver.v`** — parameter only: `NUM_BLOCKS` 16384 → 49152 when the card
   is enabled, and the block index picks `FLASH_START` (blocks 0-16383) or `CARD_START`
   (blocks 16384-49151). The FSM is size-agnostic by construction (its own header says so).
4. **OSD** — one new bit: `573 PCMCIA Card, Off, 32MB (slot 2)`. Off keeps today's exact
   behaviour and today's 16 MB `.sav`.

### Why one combined `.sav` and not a second mount slot
`hps_io` is `VDNUM(5)` (slots 0-4; 4 = flash save). A separate card save needs slot 5 —
but Main parses **at most six** file/reset items per `.mgl`
(`mra_loader.h mgl_item_struct item[6]`, quoted in `mgl/dsfdr_install.mgl`), and
`dsfdr_install.mgl` already uses exactly six. A seventh item is **silently dropped**.
So: with the card enabled, slot 4's file is **48 MB** (16 MB flash then 32 MB card); with it
off, 16 MB as today. `tools/stage_ddr4m.sh` creates the right size. *(Verify the six-item
cap against the Main source before relying on it — it is quoted from our own doc, not read
from Main in this session.)*

---

## 5. Order of work (simulation before any build)

| # | Step | State |
|---|---|---|
| 1 | `rtl/s573_flash.v`: generalise the flat address to `{pair_idx, win_addr[20:0]}` + a region bit, `card_en` input, `flash_mem_card` / `flash_wr_card` outputs, per-pair erase state widened 4 → 12 (`pu = {region,pair}`) | **DONE** |
| 2 | `rtl/system573_top.v` + `rtl/emu.sv`: pass the new ports through; `card_en` tied to 0 in emu so the current build is behaviourally identical | **DONE** |
| 3 | `sim/tb_s573_flash_pccard.v` + Makefile entry + the `S573_FLASH_NO_PCCARD` RED reference | **DONE** |
| 4 | Run it GREEN / RED, plus the full suite | **DONE 2026-09-14: PASS; RED = 25 failures; suite 55/55** |
| 5 | `rtl/s573_flash_saver.v`: one 48 MB slot-4 image — `card_en` + `load_blocks` inputs, `mem_card`/`wr_card` outputs, blocks ≥ `NUM_BLOCKS` re-based into the card image | **DONE** |
| 6 | `sim/tb_s573_flash_saver_card.v`: the two-image split (save/load round trip, a legacy short file leaving the card alone, `card_en=0` bit-identical) | **DONE** |
| 7 | `rtl/emu.sv`: `CARD_START = 27'h0200_0000`, base select on the ch3/ch4 adders, OSD `O[107] 573 PCMCIA Card`, corrected `pcmcia_present` polarity, 48 MB save geometry | **DONE (not sim-covered — emu.sv is Quartus-only)** |
| 8 | `tools/stage_ddr4m.sh`, `mgl/ddr4m_install.mgl`, `mgl/ddr4m_console.mgl` | **DONE** |
| 9 | Run `make -C sim` again (the saver change touches a shipped module) | **DONE 2026-09-14: 56/56 ALL TESTS PASSED** |
| 10 | Quartus build (watch LAB% — build-573.ps1 warns at >=98%; the pre-Tier-3 build was 34,814/41,910 ALM, 97% LAB) | pending |
| 11 | Hardware: `ddr4m_install.mgl` (X76F041 install cassette) → card install → `ddr4m_console.mgl` (ZS01) | |

A MAME oracle run of the ddr4m install against `a33aaa02.chd` would give us a golden
32 MB card image to byte-diff our `.sav` against, the same way
`out/ddrsbm.sav.golden-installed` served the onboard flash. Worth doing at step 6/7.

---

## 6. Facts still unverified (do not build on these)
- The `sdram_sz` word's encoding is not established anywhere in this tree, so the
  ≥64 MB SDRAM requirement is documented and opt-in rather than gated in RTL.
  `sdram_sz[7:0]` is already in the flash debug readback — read the real value off
  the board, then the gate can be written against a measured number.
- The six-item `.mgl` cap is quoted from our own docs, not re-read from Main this session.
- Whether ddr4m's installer probes the card-detect bits at `0x1f400006[11:10]` before
  erasing — worth a MAME `-log` run or a disassembly pass.
- Whether a 48 MB auto-save completes inside the watchdog budget (the 16 MB save already
  "spans seconds"; the CPU is deliberately not paused, so this should scale, but measure).
