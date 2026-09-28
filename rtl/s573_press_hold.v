// -----------------------------------------------------------------------------
// s573_press_hold.v - minimum press width for the JAMMA inputs
//
// WHY. A System 573 reads its panels and buttons as plain JAMMA levels (MAME
// ksys573.cpp: IN2 0x1f400008 IP_ACTIVE_LOW bits, sampled by the game once a
// frame); a real switch closure lasts tens of milliseconds, so a 60 Hz poll never
// misses one. On MiSTer the closure travels USB -> Linux evdev -> Main's loop ->
// SPI -> `joystick_*`. Main services evdev from its main loop, and that loop was
// measured (2026-09-27, ddrextrm gameplay, s573mp3 "poll: loop max") stalling for
// 25-83 ms in most seconds. A tap whose press AND release both queue up during a
// stall is delivered as two SPI updates microseconds apart: the core sees a
// pulse shorter than one frame and the game samples right over it -- the
// "occasional random dropped arrow". This module guarantees every press is
// visible for at least HOLD_MS, timed from the PRESS EDGE only:
//   * a press shorter than HOLD_MS is extended to HOLD_MS;
//   * a press longer than HOLD_MS passes through unchanged (release not delayed);
//   * the press edge itself is combinational -- zero added latency.
// The stall's LATENCY is not fixable here (that is Main's loop); this makes the
// press survive it. Parameterised per bit; 32 ms = two frames covers the 60 Hz
// sample period with margin and is far below any physical re-press interval.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_press_hold #(
    parameter integer W       = 12,           // bits stretched (game inputs)
    parameter integer CLK_HZ  = 33_868_800,   // clk_1x
    parameter integer HOLD_MS = 32            // minimum visible press, 1..63 ms
)(
    input  wire         clk,
    input  wire         rst,
    input  wire [W-1:0] in,                   // active-high (MiSTer joy bits)
    output wire [W-1:0] out
);
    localparam integer TICK_DIV = CLK_HZ / 1000;   // 1 kHz tick

    reg [15:0] tdiv = 16'd0;
    reg        tick = 1'b0;
    always @(posedge clk) begin
        tick <= 1'b0;
        if (rst) tdiv <= 16'd0;
        else if (tdiv == TICK_DIV - 1) begin tdiv <= 16'd0; tick <= 1'b1; end
        else tdiv <= tdiv + 16'd1;
    end

    reg [W-1:0] in_q = {W{1'b0}};
    always @(posedge clk) in_q <= rst ? {W{1'b0}} : in;

    genvar i;
    generate for (i = 0; i < W; i = i + 1) begin : g
        reg [5:0] hold = 6'd0;                // ms of guaranteed visibility left
        always @(posedge clk) begin
            if (rst)                    hold <= 6'd0;
            else if (in[i] & ~in_q[i])  hold <= HOLD_MS[5:0];   // press edge: arm
            else if (tick && hold != 0) hold <= hold - 6'd1;
        end
        assign out[i] = in[i] | (hold != 6'd0);
    end endgenerate
endmodule
