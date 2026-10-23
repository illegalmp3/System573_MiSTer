// -----------------------------------------------------------------------------
// s573_audio_mix.v - 2-channel saturating audio mixer (SPU + HPS MP3 PCM)
//
// P4b(b), fabric slice 3. The PSX SPU output (sound_out_left/right) currently
// drives AUDIO_L/R directly at emu.sv:1520-1521. The Digital I/O MP3 path adds a
// second stereo source (s573_mp3_pcm's drained PCM). This module sums them with
// SIGNED SATURATION so a loud SPU + loud MP3 clip cleanly at the 16-bit rails
// instead of wrapping (a wrap would be an audible full-scale glitch).
//
// Enables (2026-10-23, sources in docs/2026-10-23-hw-audit-573in1-sources.md F7):
//   spu_en = 0x1f400000 bit 7, "SPU DAC output enable (0 = muted)" (psx-spx);
//            573in1 main.cpp sets it, ddr4m's game sets bits 7:5 = 111 at init.
//   mp3_en = Digital I/O 0x1f6400f4 bit 15, DAC reset (0 = reset) (psx-spx);
//            ddr4m's MP3 init writes 0, inits the MAS3507D, then pulses
//            0x8000/0/0x8000 and leaves it at 0x8000.
// Bit 6 (external input enable) is NOT applied: psx-spx measured it as an
// attenuator and it does not reach GuitarFreaks-style separate MP3 jacks.
//
// Purely combinational; both inputs are signed 16-bit, output signed 16-bit
// (AUDIO_S = 1). When the MP3 channel is idle/underrun, s573_mp3_pcm drives its
// PCM to 0, so this reduces to a passthrough of the SPU -- game SFX unaffected.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_audio_mix (
    input  wire signed [15:0] spu_l,   // PSX SPU L
    input  wire signed [15:0] spu_r,   // PSX SPU R
    input  wire signed [15:0] mp3_l,   // HPS MP3 PCM L (0 when idle/underrun)
    input  wire signed [15:0] mp3_r,   // HPS MP3 PCM R
    input  wire               spu_en,  // 0x1f400000 bit 7 (1 = SPU DAC on)
    input  wire               mp3_en,  // DIO 0xf4 bit 15 (1 = DAC out of reset)
    output wire signed [15:0] out_l,
    output wire signed [15:0] out_r
);
    // 17-bit signed sum, then clamp to the 16-bit rails [-32768, 32767].
    wire signed [15:0] spu_lg = spu_en ? spu_l : 16'sd0;
    wire signed [15:0] spu_rg = spu_en ? spu_r : 16'sd0;
    wire signed [15:0] mp3_lg = mp3_en ? mp3_l : 16'sd0;
    wire signed [15:0] mp3_rg = mp3_en ? mp3_r : 16'sd0;
    wire signed [16:0] sum_l = spu_lg + mp3_lg;
    wire signed [16:0] sum_r = spu_rg + mp3_rg;

    function signed [15:0] sat16;
        input signed [16:0] v;
        begin
            if (v > 17'sd32767)       sat16 = 16'sd32767;
            else if (v < -17'sd32768) sat16 = -16'sd32768;
            else                      sat16 = v[15:0];
        end
    endfunction

    assign out_l = sat16(sum_l);
    assign out_r = sat16(sum_r);
endmodule
