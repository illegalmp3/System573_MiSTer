# dsfdr `ERROR 184 / CD-ROM ドライブエラー`, decoded from the game's binary

First result of the dsfdr install test, and the important half of it is what did
*not* appear: **no cassette error.** The X76F041 install cassette cleared
identification, the BIOS booted `PSX.EXE` off the disc, and the game drew its own
error screen. So the whole install path up to the drive check works.

## What 184 is

`ERROR 184` is not a disc problem, not a mount problem, and not a content mismatch.
It is a **short INQUIRY transfer**, and the game's own code says so in three steps.

`PSX.EXE 0x8031fad0` — the INQUIRY helper:

```
8031fb18  addiu v0,zero,18     ; CDB[0] = 0x12  INQUIRY
8031fb1c  sb    v0,16(sp)
8031fb20  addiu v0,zero,96     ; CDB[4] = 0x60  allocation length = 96
8031fb24  sb    v0,20(sp)
8031fb38  sw    s1,4576(s0)    ; ... and 96 recorded as the expected count
8031fb3c  jal   0x8031d470     ; issue the packet
8031fb44  bgez  v0,0x8031fb90  ; >= 0 -> return it
8031fb8c  addiu s0,zero,-8     ; timeout -> -8
```

`PSX.EXE 0x8031483c` — the caller:

```
8031483c  jal   0x8031fad0     ; INQUIRY into sp+16
80314844  bgez  v0,0x80314858  ; success -> carry on
8031484c  jal   <show_error>
80314850  addiu a0,zero,184    ; <== ERROR 184
```

The `bgez` is the whole story: **184 fires before a single response byte is
examined.** Only if INQUIRY succeeds does the game go on to compare content, at
`0x803148dc` (bytes 8..31 against `"MATSHITACD-ROM CR-589   "`) and at `0x80314918`
(bytes 32..35 against a table of accepted drive firmware revisions).

`rtl/atapi.v` served a **hardcoded 36 bytes** for INQUIRY and put 36 in the byte
count registers. The library wanted 96, saw 36, returned negative.

## And the check immediately behind it

The revision table at `0x80340be4` has exactly three entries:

| entry | string |
|---|---|
| 0 | `GS0N` |
| 1 | `kona` |
| 2 | `GSCA` |

Our INQUIRY reported `"1.0b"`, which is in none of them. Fixing only the length
would have moved the failure one step along and cost another bitstream — the
instrument-gate mistake, transplanted into a game's control flow.

## MAME settles both, and it is the right authority here

`src/devices/bus/ata/cr589.cpp`. The base ATAPI CD-ROM clamps INQUIRY:

```cpp
// t10mmc::ExecCommand
m_transfer_length = SCSILengthFromUINT8( &command[4] );
if (m_transfer_length > 36) m_transfer_length = 36;
```

and `matsushita_cr589_device::ExecCommand` overrides that case *specifically* to
drop the clamp:

```cpp
case T10SPC_CMD_INQUIRY:
    m_transfer_length = SCSILengthFromUINT8( &command[4] );   // no clamp
```

Its `ReadData` memsets the buffer, lets the base fill the 36-byte page, then
overwrites bytes 8..35 with the 28-byte identity from nvram, whose default is:

```cpp
memcpy(&buffer[identity_offset], "MATSHITACD-ROM CR-589   GS0N", 28);
```

So: honour the allocation length, revision `GS0N`, and everything past byte 35
reads zero. That is not a guess about a real drive — it is the model every one of
these titles is known to run against.

## The fix

`rtl/atapi.v`:

* INQUIRY transfers exactly `CDB[4]` bytes, with 0 meaning 256 per SPC, instead of
  a hardcoded 36. `resp_byte`'s index widened from 6 to 9 bits — at 6 bits byte 64
  would have aliased back onto byte 0, so a 96-byte response would have repeated
  the header in the middle of the page.
* Revision bytes 32..35 are `GS0N`.
* Bytes 36..255 read 0, from the function's existing default.

Bytes 0..7 are deliberately **left alone** (`05 80 00 21 1f 00 00 00`). MAME's base
page has `05 80 05 02 1f ...`, but nothing any 573 title checks reads those bytes,
three titles take a credit against what is there now, and this is not the build to
find out otherwise.

`sim/tb_atapi_inquiry.v` pins it at three allocation lengths: 96 (dsfdr), **36 (the
BIOS POST path — the regression guard for the three playable titles)** and 0/256,
checking the byte-count registers, the 28-byte identity, the 24-byte concatenation
the game actually memcmps, and the zero padding.

## This is on ddrusa's path too

`a44uaa02.chd`'s `PSX.EXE` carries the identical table — `GS0N`, `kona`, `GSCA` —
and the same helper. ddrusa reports the cassette error first, so the drive check
has not been reached yet there; it would have been the next wall.

`hyperbbc`/`hypbbc2p` (2000) contain none of these strings, which is consistent
with them booting and running attract on the current drive model.

## Tooling

`tools/chd_extract.py` (new) decompresses a v3/v4 zlib CD CHD and pulls files out of
its ISO9660 root, so reading a title's binary is one command:

```
tools/chd_extract.py dumps/mame573/a37jaa02.chd --get PSX.EXE -o /tmp/psx.exe
```

Decoding `ERROR 121` from ddrusa's binary settled in an afternoon what four
bitstreams could not, and this error took an hour by the same route. The tool is
checked in so that stays the cheap option.
