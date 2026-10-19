# Analog System 573 (GX700-PWB(F)) titles -- feasibility (2026-10-18)

Question: can the core run the "analog" 573 titles -- DDR 1st Mix and 2nd Mix
and their relatives? Sources: dumps/mame573/ksys573.cpp (machine configs, the
GX700-PWB(F) handlers, ddr_output_callback, cr589_config), the two analog discs
already in dumps/mame573 (884jaa02, 910jaa02), Main_MiSTer support/psx/psx.cpp.

## Which titles

MAME machine configs built on `k573a` (konami573 + the GX700-PWB(F) at
0x1f640000), DDR-engine titles first:

| set(s) | title | extra hardware | in the core today? |
|---|---|---|---|
| ddrja, ddrjb, ddrj, ddru, ddra, dstagea | DDR (1st Mix) / Dancing Stage | X76F041 cassette | yes |
| dstage, dsftkd | Dancing Stage Internet Ranking / feat. TRUE KiSS DESTiNATiON | X76F100 + DS2401 | yes |
| ddr2m, ddr2mc | DDR 2nd Mix / 2nd Mix with beatmaniaIIDX CLUB | X76F041 | yes |
| ddr2mc2 | 2nd Mix ... CLUB VERSiON 2 | X76F041, JVS memory card reader | reader no (= memory-card roadmap) |
| dsfdcta | Dancing Stage feat. Dreams Come True (JAA) | 2x X76F100, slot-2 32 MB card | yes |
| ddr2ml*, ddrbocd | 2nd Mix Link Ver / Best of Cool Dancers | PCMCIA **slot 1** 16 MB (+ reader) | no: s573_flash.v models slot 2 only |
| gtrfrks*, gtrfrk2m*, drmn*/pcnfrk* | Guitar Freaks 1st/2nd, DrumMania 1st | guitar / drum inputs | different controllers, later |

## What is different from the Digital I/O titles

1. **Music is CD-DA (Red Book) from the drive.** Both local analog discs are one
   MODE1_RAW data track + 32 AUDIO tracks (884jaa02: 156,917 audio frames = 34.9
   min; 910jaa02: 31.1 min). MAME routes the CR-589's cdda to the speakers
   (`cr589_config`); the main board has a CD-DA input (CN12). dsftkd's PSX.EXE
   carries `cdda_step : uncorrect operation.` The core has no CD audio: atapi.v
   answers unknown opcodes (PLAY AUDIO 0x45/0x47, PAUSE/RESUME 0x4B, STOP 0x4E,
   READ SUB-CHANNEL 0x42) with CHECK CONDITION. **This is the main work.**
2. **GX700-PWB(F)**: write-only output latches at 0x1f640040/44/48/4c, each
   fanned out through the bit order {7,6,1,0,5,4,3,2} to output lines
   offset*8+i; reads return 0 (MAME gx700pwbf_io_r/w, gx700pwbf_output).
   `init_ddr` hands these lines to the SAME `ddr_output_callback` the digital
   board uses (4/7 = P1 stage DO/CLK, 12/15 = P2), so rtl/gn845pwbb.v is reused
   unchanged. Small.
3. Everything else (BIOS, cassettes, timekeeper, slot-2 card, stage handshake,
   ISO data reads) is already in the core.

## Delivery path for the audio

Main already serves CD-DA for multi-track images: psx.cpp reads 2352-byte
sectors from CHD or cue/bin, byte-swaps CHD audio ("CHD requires byteswap of
audio data"), and sends per-track start + an audio flag in the disk_t blob,
which rtl/s573_cdtoc.v already parses. So the analog titles need no change to
the MiSTer executable (and not the MP3 one at all); the FPGA side needs:
ATAPI audio commands + play state (current MSF for READ SUB-CHANNEL), a
75-sector/s audio-sector fetch over the existing s573_cdimg sd-block channel,
a small sample FIFO, and a third input to s573_audio_mix.

## Space

The current bitstream is 38,903 ALM (93 %), 4,181 / 4,191 LABs. CD-DA will not
fit next to the Digital I/O + MP3 machinery, and the analog titles never touch
it. Plan: a second bitstream from the same tree, `Konami_System_573_Analog.rbf`,
with k573dio / MP3 / mas3507d compiled out and the GX700-PWB(F) + CD-DA in. Each
launcher already names its rbf, so the user just picks the title.

## Plan (sources and sim first, per project rule)

1. MAME ground truth: ATAPI command trace of dsftkd (and ddr2m once dumped)
   through attract, song select and a full song -- which audio commands, how
   often READ SUB-CHANNEL is polled and what the game does with the position
   (arrow sync).
2. Static check of the EXE's CD library for the packet builders (as done for
   ddrs2k, docs/2026-09-12-ddrs2k-cdrom-initialize-error.md).
3. RTL in sim: atapi.v audio commands + CD-DA streamer + GX700-PWB(F); testbench
   replaying the MAME trace against 884jaa02.
4. Analog rbf build; hardware test dsftkd -> dsfdcta -> ddr2m / 1st Mix.
5. Later: PCMCIA slot 1 (Link Ver, Best of Cool Dancers), memory card reader.

Dumps on hand: dsftkd and dsfdcta (zips + CHDs). Needed from the user: ddr2m,
ddrja (1st Mix) and any other analog sets he wants.
