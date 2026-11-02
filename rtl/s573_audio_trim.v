// -----------------------------------------------------------------------------
// s573_audio_trim.v - user "573 Music Level" trim on the MP3 path
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
// 2026-11-01 (Ricky, after testing the 3 dB-step version): 0..+6 dB in 1 dB steps,
// music only (the SPU-reduction positions are gone). sel = n -> n dB, gain Q12
// round(4096 * 10^(n/20)); 7 = passthrough. Floor, saturating at the 16-bit rails
// (the 2026-07-31 notes measured masters reaching +1.2 dBFS at unity, so the top
// settings can clip on loud passages of titles that play near 0 dB in the chip).
// Registered, one clock. Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_audio_trim (
    input  wire               clk,
    input  wire               rst,
    input  wire [2:0]         sel,
    input  wire signed [15:0] mp3_l,
    input  wire signed [15:0] mp3_r,
    output reg  signed [15:0] mp3_ol,
    output reg  signed [15:0] mp3_or
);
    reg [14:0] gm;              // Q12, unsigned
    always @(*) begin
        case (sel)
            3'd1:    gm = 15'd4596;     // +1 dB
            3'd2:    gm = 15'd5157;     // +2 dB
            3'd3:    gm = 15'd5786;     // +3 dB
            3'd4:    gm = 15'd6492;     // +4 dB
            3'd5:    gm = 15'd7284;     // +5 dB
            3'd6:    gm = 15'd8173;     // +6 dB
            default: gm = 15'd4096;     // 0 dB
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
            if (q > 20'sd32767)       scale = 16'h7FFF;
            else if (q < -20'sd32768) scale = 16'h8000;
            else                      scale = q[15:0];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            mp3_ol <= 16'sd0; mp3_or <= 16'sd0;
        end else if (sel == 3'd0 || sel == 3'd7) begin          // bit-exact passthrough
            mp3_ol <= mp3_l; mp3_or <= mp3_r;
        end else begin
            mp3_ol <= scale(mp3_l, gm); mp3_or <= scale(mp3_r, gm);
        end
    end
endmodule
