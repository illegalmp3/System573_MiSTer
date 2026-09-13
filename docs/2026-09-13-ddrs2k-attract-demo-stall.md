# ddrs2k: attract gameplay demo stalls (CD load throughput) -- 2026-09-13

DDR Solo 2000 is playable: a full credit of three songs plays with audio, in
sync, and flash persists. The one defect found on hardware is confined to the
**attract-mode gameplay demonstration** -- the auto-played song (I'm Alive on
attract loop 1, Temple of Love on loop 2) sounds for ~2 s, cuts off, and the
demo never starts before the game moves to the next attract screen. The same
songs play in full during a real credit.

## What the log shows (cdtrace binary, 2026-09-13)

Every attract BGM clip plays fine. They are SMALL windows at NON-ZERO DIO-RAM
addresses (e.g. epoch 13 start=0x00dea346, len ~265 KB) -- fully preloaded.

The demo songs are the FULL 1.4 MB gameplay songs, loaded to DIO-RAM address 0
(epoch 46 start=0x00000000 end=0x0015bdc3; epoch 101 the same shape). Both
stalled identically:

    decode STALL (bytes not loaded yet -- rewinding the pull)
      at cur=0x3dc2 (15810 of 1424835 bytes, 0 played) raw: 3ae1 3ae2 3ae3 3ae4

`3ae1 3ae2 3ae3 3ae4` is the incrementing POST memory-test fill, i.e. DIO RAM
at address 0 still held boot-time garbage when the game enabled streaming. The
service correctly refused to decode it and rewound, waiting for real data that
did not arrive before the game gave up (epoch 47 DRAIN OFF via ENABLES ~20 s
later).

## The data path is NOT the problem (proved offline)

Extracted /DAT/M0V4R1BV.DAT (the I'm Alive audio, 1,424,834 B) from the disc and
ran it through support/s573/s573_descramble.c with the exact keys the game
programmed for that window (62a5/6503/0029, default scheme):

    descrambled 1,424,833 bytes; first MPEG frame sync at offset 12

Valid MP3, right keys, right scheme. The descrambler, key derivation, and word
alignment are all correct for this title. The only thing missing on hardware was
the song bytes being present in DIO RAM when streaming was enabled.

## Root cause: CD read throughput, exposed by the demo's watchdog

The cdtrace heartbeat measured the demo loading M0V4R1BV.DAT as **24
single-sector (2352 B) reads per second = ~56 KB/s**. At that rate a 1.4 MB song
takes ~25 s to load. A real 2x CD-ROM is ~300 KB/s (~5 s). The attract demo has
a fixed ~20 s patience window (it watches the DIO frame counter, which cannot
advance until real MPEG data is streaming); it times out and aborts before the
slow load reaches DIO RAM address 0.

A real credit has no such watchdog -- it waits at READY as long as the load
needs -- which is why the identical 1.4 MB window plays there.

The game appears to issue multi-sector READ(12) (the gate-5 oracle saw len=64
storms) but the fabric CD path (atapi.v / s573_cdimg.v -> Main psx_read_cd) is
delivering one sector per service tick. Raising that to the buffered multi-sector
rate the BIOS actually asked for is the fix; it is an RTL/Main change needing a
bitstream build, and s573_cdimg is on the delicate gate-5 reset path, so it wants
its own careful pass rather than a rushed edit.

## Severity / call

Cosmetic: attract-mode gameplay demo only. ddrs2k is fully playable end to end.
Marked a known issue; the CD-throughput fix is queued as a follow-up, not a
Tier-1 blocker. The "brief click/pop at song start" the operator noted is the
same fill-pattern-before-real-data window at a song's first beat, mostly (not
wholly) suppressed by the rewind; it rides along with the same fix. The "~1 ms
early on some songs, perfect on others" is per-song chart offset, not a core
issue.
