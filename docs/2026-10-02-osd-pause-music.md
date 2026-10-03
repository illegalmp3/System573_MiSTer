# OSD pause: MP3 music kept playing -- 2026-10-02/03

## Symptom (hardware, every DDR title)
Opening the MiSTer OSD pauses the game, and SPU sound effects stop, but MP3
music keeps playing. Closing the OSD mid-song leaves music and arrows out of sync.

## Cause
The PSX core's pause (`emu.sv` `paused` -> psx_top `.pause`; `isPaused <= pausing`,
psx/rtl/psx_top.vhd:786) freezes the CPU, GPU and SPU. The 573 digital-board MP3
path is ours and sits outside that: `rtl/s573_mp3_pcm.v` drained its elastic
buffer at 44.1 kHz whenever `drain_en` was set, regardless of pause. The HPS
decoder kept refilling it, so music ran on, and `pcm_sample_tick` kept advancing
the game's 0xca/0xcc playback-position counter while the game stood still.

## Fix
`s573_mp3_pcm` gets a `hold` input, wired to `isPaused` in `emu.sv`. While held,
no sample is drained, no `pcm_sample_tick` is issued, and the 44.1 kHz phase
accumulator keeps its value, so playback resumes on the exact sample it stopped
on. The HPS side needs no change: the buffer fills, `wr_full` back-pressures the
ring, and the decoder idles until the drain resumes.

## Evidence
- `sim/tb_s573_mp3_pcm.v` phase H: pause for 40 sample periods mid-stream; no
  samples or ticks during the pause, sequence continues unbroken afterwards.
  RED with `-DPCM_NO_PAUSE_HOLD`, GREEN without (job 234). Suite 65/65.
- Build (job 241, SEED 5): 36,637 ALMs, LABs 4,140/4,191, worst setup 0.596 ns,
  worst hold 0.079 ns, all corners met. rbf md5 e80849080178471ea340f39bbbceefe5.

## Build notes
Five attempts were needed. Jobs 235 (seed 5) and 236 (seed 6) died with Quartus
access violations in the router / placer. Job 238, byte-identical inputs to 236,
completed -- so the crashes are not deterministic -- but missed hold by 0.050 ns on
clk_1x; job 240 (seed 7) missed hold by 0.062 ns. Job 241 (seed 5 again) closed.
The device is at 99 % LAB use, so hold margin is seed-sensitive.

The build PC (i9-14900KF, BIOS 1812, microcode 0x12B) logged 41 WHEA id 19
"Processor Core / Cache Hierarchy Error" corrected machine checks in 30 days
(jobs 237/239). Nondeterministic crashes on identical inputs plus those events
point at the machine rather than the project.

## Hardware test
1. ddrextrm: open the OSD mid-song; music stops with the arrows; close it; music
   resumes in sync.
2. ddr3mj: same.
3. Select Music: open the OSD during a preview; it pauses and resumes.
