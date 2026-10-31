// -----------------------------------------------------------------------------
// s573_audio_trim.v - user "573 Music Level" trim between the MP3 and SPU paths
//
// WHY (2026-10-30): the core sums the MAS3507D output (after the game's own
// volume matrix, s573_mas_gain.v) and the SPU 1:1. The data sheet fixes what the
// chip does, but the analog ratio between the Digital I/O DAC (AK4309B ->
// CN16 -> main-board CD-DA IN) and the SPU DAC at the board's mixer is not in any
// source we hold (docs/2026-10-30-music-level-and-announcer.md). DDR Extreme
// plays its music at -12 dB in the chip; measured on the core, the test menu's
// SOUND SCALE CHECK 2 (MP3) tone peaks 5.2 dB under SCALE CHECK 1 (SPU). This is
// a listener preference, NOT a hardware model: position 0 is the 1:1 sum the core
// has always had.
//
// sel  music   SPU     (Q12 gains; +6 dB is exact x2, +3/-3 are 10^(+-3/20))
//  0     0 dB   0 dB
//  1    +3 dB   0 dB
//  2    +6 dB   0 dB
//  3    +6 dB  -3 dB   above +6 the SPU comes down instead: at DDR Extreme's
//  4    +6 dB  -6 dB   -12 dB, +12 dB on the music alone would put full-scale
//                      masters at the rails and the 16-bit sum would clip.
//  5-7  as 0
//
// Saturating, registered (1 clk), both channels of both paths with the same
// latency. Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_audio_trim (
    input  wire               clk,
    input  wire               rst,
    input  wire [2:0]         sel,
    input  wire signed [15:0] mp3_l,
    input  wire signed [15:0] mp3_r,
    input  wire signed [15:0] spu_l,
    input  wire signed [15:0] spu_r,
    output reg  signed [15:0] mp3_ol,
    output reg  signed [15:0] mp3_or,
    output reg  signed [15:0] spu_ol,
    output reg  signed [15:0] spu_or
);
    reg [14:0] gm, gs;          // Q12, unsigned
    always @(*) begin
        case (sel)
            3'd1:    begin gm = 15'd5793; gs = 15'd4096; end   // +3 / 0
            3'd2:    begin gm = 15'd8192; gs = 15'd4096; end   // +6 / 0
            3'd3:    begin gm = 15'd8192; gs = 15'd2900; end   // +6 / -3
            3'd4:    begin gm = 15'd8192; gs = 15'd2048; end   // +6 / -6
            default: begin gm = 15'd4096; gs = 15'd4096; end
        endcase
    end

    function signed [15:0] scale;
        input signed [15:0] x;
        input        [14:0] g;
        reg   signed [31:0] p;
        reg   signed [19:0] q;
        begin
            p = x * $signed({1'b0, g});
            q = p[31:12];                                       // floor(p / 4096)
            if (q > 20'sd32767)       scale = 16'sd32767;
            else if (q < -20'sd32768) scale = -16'sd32768;
            else                      scale = q[15:0];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            mp3_ol <= 16'sd0; mp3_or <= 16'sd0; spu_ol <= 16'sd0; spu_or <= 16'sd0;
        end else if (sel == 3'd0 || sel > 3'd4) begin              // bit-exact passthrough
            mp3_ol <= mp3_l; mp3_or <= mp3_r; spu_ol <= spu_l; spu_or <= spu_r;
        end else begin
            mp3_ol <= scale(mp3_l, gm); mp3_or <= scale(mp3_r, gm);
            spu_ol <= scale(spu_l, gs); spu_or <= scale(spu_r, gs);
        end
    end
endmodule
