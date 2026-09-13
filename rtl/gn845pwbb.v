// -----------------------------------------------------------------------------
// gn845pwbb.v - GN845-PWB(B) DDR stage multiplexor (standard 2-player cabinets)
//
// A standard DDR cabinet does not wire the dance-stage sensors straight to the
// JAMMA edge. Each stage hangs off a small multiplexor PCB (GN845-PWB(B)) that
// the game programs over two lamp-output lines and reads back through the
// player's JAMMA direction bits. At boot the game clocks a 13-bit ID pattern out
// to each stage and expects a fixed 22-step reply on the input bits; if the reply
// is wrong it stops with "HARD-WARE ERROR -1N / STAGE PCB INITIALIZE ERROR"
// (dsem on hardware, 2026-09-13 -- the first standard-cab DDR this core ran; the
// Solo titles wire their pads directly and never touch this).
//
// Faithful to MAME konami/ksys573.cpp (ddr_state gn845pwbb_do_w / gn845pwbb_clk_w /
// gn845pwbb_read, BSD-3), transliterated:
//
//   * The lines ride the k573dio lamp outputs. MAME's k573dio output() fans each
//     lamp register's [15:12] nibble out as callback offsets reg*4+{0..3} with
//     the bit remap {0,2,3,1} -- exactly what k573dio.v's set_lamp() produces on
//     `lamp[]`. ddr_output_callback maps offset 4 -> stage0 DO, 7 -> stage0 CLK,
//     12 -> stage1 DO, 15 -> stage1 CLK (0xe0 bits 12/13, 0xe4 bits 12/13), each
//     INVERTED (DO = !data, clk = !data).
//   * On each rising edge of clk: shift = (shift >> 1) | (DO << 12).
//     IDLE: shift == 0x0c90 -> INIT, bit = 0, mask = 0xf9f9.
//     INIT: bit++; if bit < 22 -> mask = {byte(stage0), byte(stage1)} with
//           byte(s) = (~0x06 | tab[bit_s]) & 0xff  (tab indexed by EACH stage's
//           own bit counter, the idle one sitting at 0); else bit = 0, IDLE,
//           mask = 0xffff.
//   * gn845pwbb_read returns pads & mask over IN2's direction nibbles. The 573
//     JAMMA word is {P1, P2} (P1 high byte), and the mask is built the same way
//     (stage0 -> [15:8]), so it is applied to the whole r_jamma word: only bits
//     1/2 and 9/10 can ever be cleared, which are inside MAME's 0x0f0f custom
//     field. Cleared = reads LOW = "pressed" on the active-low lines: that is the
//     PCB's reply.
//
// Gate `en` with the cabinet strap: a Solo title drives those same lamp lines as
// real lamps and must never be able to trip the ID matcher.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module gn845pwbb (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,          // 1 = standard cabinet (stage PCBs present)
    input  wire [31:0] lamp,        // k573dio lamp lines (MAME callback offsets)
    output wire [15:0] stage_mask   // AND mask over the JAMMA word {P1, P2}
);
    localparam ST_IDLE = 1'b0, ST_INIT = 1'b1;

    // MAME `static const int mask[]` (24 entries, indices 0..21 used)
    function [2:0] tab(input [4:0] i);
        case (i)
            5'd1:  tab = 3'd6;  5'd2:  tab = 3'd2;  5'd3:  tab = 3'd4;
            5'd5:  tab = 3'd4;  5'd7:  tab = 3'd4;  5'd9:  tab = 3'd4;
            5'd11: tab = 3'd4;  5'd13: tab = 3'd4;  5'd15: tab = 3'd4;
            5'd17: tab = 3'd4;  5'd19: tab = 3'd4;  5'd21: tab = 3'd4;
            5'd23: tab = 3'd6;
            default: tab = 3'd0;    // 0,4,6,8,...,20,22
        endcase
    endfunction
    function [7:0] mbyte(input [4:0] b);
        mbyte = (~8'h06) | {5'b0, tab(b)};      // (~0x06 | tab[bit]) & 0xff
    endfunction

    wire do0 = ~lamp[4],  ck0 = ~lamp[7];
    wire do1 = ~lamp[12], ck1 = ~lamp[15];

    reg        ck0_q, ck1_q;
    reg [12:0] sh0, sh1;
    reg        st0, st1;
    reg [4:0]  bit0, bit1;
    reg [15:0] mask_r;

    assign stage_mask = en ? mask_r : 16'hffff;

    wire ck0_rise = ck0 & ~ck0_q;
    wire ck1_rise = ck1 & ~ck1_q;
    wire [12:0] sh0_n = {do0, sh0[12:1]};
    wire [12:0] sh1_n = {do1, sh1[12:1]};

    always @(posedge clk) begin
        if (rst) begin
            ck0_q <= 1'b0; ck1_q <= 1'b0;
            sh0 <= 13'd0; sh1 <= 13'd0;
            st0 <= ST_IDLE; st1 <= ST_IDLE;
            bit0 <= 5'd0; bit1 <= 5'd0;
            mask_r <= 16'hffff;
        end else begin
            ck0_q <= ck0; ck1_q <= ck1;
            // The two stages live on different lamp registers, so their clocks
            // never rise in the same cycle; handle stage 0 then stage 1 anyway.
            if (ck0_rise) begin
                sh0 <= sh0_n;
                if (st0 == ST_IDLE) begin
                    if (sh0_n == 13'h0c90) begin
                        st0 <= ST_INIT; bit0 <= 5'd0; mask_r <= 16'hf9f9;
                    end
                end else begin
                    if (bit0 + 5'd1 < 5'd22) begin
                        bit0   <= bit0 + 5'd1;
                        mask_r <= {mbyte(bit0 + 5'd1), mbyte(bit1)};
                    end else begin
                        bit0 <= 5'd0; st0 <= ST_IDLE; mask_r <= 16'hffff;
                    end
                end
            end
            if (ck1_rise) begin
                sh1 <= sh1_n;
                if (st1 == ST_IDLE) begin
                    if (sh1_n == 13'h0c90) begin
                        st1 <= ST_INIT; bit1 <= 5'd0; mask_r <= 16'hf9f9;
                    end
                end else begin
                    if (bit1 + 5'd1 < 5'd22) begin
                        bit1   <= bit1 + 5'd1;
                        mask_r <= {mbyte(bit0), mbyte(bit1 + 5'd1)};
                    end else begin
                        bit1 <= 5'd0; st1 <= ST_IDLE; mask_r <= 16'hffff;
                    end
                end
            end
        end
    end
endmodule
