// -----------------------------------------------------------------------------
// s573_mas_gain.v - MAS3507D baseband volume matrix (L->L and R->R terms)
//
// The MP3 PCM reaching the fabric is the HPS decoder's raw output, i.e. what the
// MAS3507D's decoder produces BEFORE its output volume matrix. This applies that
// matrix at the point of playback (the drain side), so a game's volume change --
// including the mute it uses around fades -- lands when it would on the board,
// not when the HPS happened to decode the frame (up to a ring's depth earlier).
//
// Sources (docs/2026-10-23-hw-audit-573in1-sources.md, F9):
//  * MAS3507D data sheet (Micronas, preliminary), 3.7.3 "Baseband Volume Matrix":
//    D1:$7f8 LL, $7f9 LR, $7fa RL, $7fb RR, default $80000; Table 3-19: 20-bit
//    two's complement, -524288/524288 .. 524287/524288 = -1.0 .. 1.0-2^-19;
//    Fig. 3-2: each coefficient feeds the output through a "-1" stage; Table
//    3-20: stereo (default) = LL = RR = -1.0; Table 3-21: 0 dB = $80000,
//    -20 dB = $F3333 ... So output = -coef * input: $80000 = unity.
//  * ddr4m's own table (game exe 0x800df160, 101 entries, -100..0 dB) is exactly
//    -10^(dB/20) * 2^19 in 20-bit two's complement, -100 dB stored as 0 (mute).
//    Its volume call (0x80098338) writes LL = RR = level, LR = RL = -100 dB.
//  * MAME mas3507d.cpp instead uses 10^((dB + 6) / 20), i.e. +6 dB on every
//    setting (unity plays at 2x). Neither source above has that term.
//
// LR/RL (cross terms) are not captured by mas3507d_i2c.v; ddr4m always writes
// them as 0. Before the game's first matrix write (gain_stb never seen since
// reset) the matrix is the chip's reset default, unity.
//
// One clock of latency; output registered in the PCM's clock domain.
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_mas_gain (
    input  wire               clk,
    input  wire               rst,
    input  wire [19:0]        gain_ll,    // D1:$7f8 as written
    input  wire [19:0]        gain_rr,    // D1:$7fb as written
    input  wire               gain_stb,   // a matrix write completed
    input  wire signed [15:0] in_l,
    input  wire signed [15:0] in_r,
    output reg  signed [15:0] out_l,
    output reg  signed [15:0] out_r
);
    reg seen;
    always @(posedge clk)
        if (rst) seen <= 1'b0; else if (gain_stb) seen <= 1'b1;

    // effective linear gain in Q19: -signed20(coef); unity (2^19) until written
    wire signed [20:0] c_ll = {gain_ll[19], gain_ll};
    wire signed [20:0] c_rr = {gain_rr[19], gain_rr};
    wire signed [20:0] g_l  = seen ? -c_ll : 21'sd524288;
    wire signed [20:0] g_r  = seen ? -c_rr : 21'sd524288;

    wire signed [36:0] p_l = in_l * g_l;
    wire signed [36:0] p_r = in_r * g_r;
    wire signed [17:0] q_l = p_l[36:19];        // floor(p / 2^19), range +-32768
    wire signed [17:0] q_r = p_r[36:19];

    function signed [15:0] sat16(input signed [17:0] v);
        sat16 = (v > 18'sd32767) ? 16'sd32767 : (v < -18'sd32768) ? -16'sd32768 : v[15:0];
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            out_l <= 16'sd0; out_r <= 16'sd0;
        end else begin
            out_l <= sat16(q_l);
            out_r <= sat16(q_r);
        end
    end
endmodule
