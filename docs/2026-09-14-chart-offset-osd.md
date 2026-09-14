# 573 Chart Offset (OSD O[106:102]): calibrating arrow/music sync outside the fabric

**Date:** 2026-09-14 (after ddrusa became playable)
**Symptom:** on every title tested (ddrsbm, ddrs2k, dsem, ddrusa) the player reports
arrows *marginally early* against the music -- "99.9% there", estimated ~1 ms.

## What was checked first: the fabric is exact

DDR times its chart off the k573dio MP3 sample counter (`0xca/0xcc`, MAME
`get_counter` = PCM position at 44100/s). So the arrows are only as accurate as that
counter's relationship to the sound leaving the core.

* `s573_mp3_pcm.v` emits `pcm_sample_tick` in the SAME cycle it pops a real sample at
  the **drain** of the 512-sample elastic buffer, and `s573_audio_mix.v` is purely
  combinational (`assign out_l = sat16(sum_l)`). The counter therefore tracks the
  sample actually leaving the core to within one sample: **23 us**.
* The documented ~12 ms early chart (docs/2026-09-12-ddr-playable.md: "credit was paid
  when the reader *fetched* a beat, but the beat then sits in the 512-sample elastic
  buffer ~11.6 ms before the DAC") is the buffer-INPUT-vs-OUTPUT version of exactly this
  error, and is fixed. STATUS.md listed it "deployed but not yet heard"; ddrusa is the
  first hearing.

So whatever residual the player perceives is downstream of the core -- the MiSTer
framework audio output path (analog sigma-delta / I2S) and, marginally, display -- and
cannot be removed by the RTL. It CAN be cancelled, because the counter is precisely the
quantity the game uses.

## The knob

`O[106:102]` "573 Chart Offset", signed 5-bit **milliseconds**, -16..+15, index 0 =
0 ms = default. In `k573dio.v` the value the GAME reads is
`mp3_pos_rep = counter -/+ |ms|*44` (saturating at 0 when subtracting), used uniformly
for the `0xcc` read, the `0xca` latch and the `0xce` diff reference (so a constant
offset cancels in the diff). The internal drain counter is never modified (no-mask
doctrine).

* **+N ms** reports the position N ms behind the truth -> the game believes the music
  is N ms less far along -> arrows N ms **later**. Use when arrows feel **early**
  (analog audio latency on a CRT/composite rig).
* **-N ms** -> arrows earlier. Use when video is late (HDMI/scaler adds >= a frame).

44 samples/ms is 0.2% low; irrelevant at ms scale.

## Verification

`sim/tb_k573dio.v` gains a section: 0 ms == truthful; +2 ms reads 200-88; +15 ms
saturates at 0 rather than wrapping; -2 ms reads 200+88; -16 ms reads 200+704; the
`0xca` latch is coherent with the shifted `0xcc`; a +3 ms offset cancels in the `0xce`
diff; and returning to 0 reads the untouched truthful count. Nine other benches that
instantiate `k573dio`/`system573_top` tie the new input to 0.

## How to use it

Play a song with a hard, obvious beat. If arrows feel early, step +1 ms at a time
until it feels centred; if it overshoots, back off. Because the fabric is already exact,
the value that feels right IS the measured downstream latency of that particular
output path. Expect 0-3 ms on analog; HDMI users may want a negative value.
