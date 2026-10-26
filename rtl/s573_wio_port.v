// -----------------------------------------------------------------------------
// s573_wio_port.v - the White I/O reader's card port, on real PS1 cards (SNAC)
//
// The reader's FPGA register at 0xb0000003 (bit 0 CMD, bit 1 CLK, bit 2 /SEL of
// port 0, bit 3 /SEL of port 1 -- pin levels; read: bit 0 DAT, bit 1 the /ACK
// latch, bit 2 /ACK active now) and the /ACK latch clear at 0xb0000005 are taken
// from how Konami's uploaded reader program uses them
// (docs/2026-10-26-white-io-reader.md).  Register writes arrive here posted from
// the HPS (the board's CPU is emulated in MiSTer_System573).
//
// The byte exchange is the program's routine 0x8000560c(byte, ack_timeout_us),
// done here at the pins because a round trip to the HPS per bit would be far
// too slow.  It is the routine, step for step:
//   1. /ACK latch already set -> error
//   2. eight bits, LSB first: CLK low + CMD; wait; sample DAT; CLK high; wait
//   3. latch set before the last bit was sampled -> error
//   4. timeout 0 -> done (the last byte of a command, no /ACK expected)
//   5. wait up to ack_timeout_us for the latch -> none: "no ACK"
//   6. wait 7 us; /ACK still low -> error; else clear the latch -> the byte
// Timing is the routine's own at the board's 66 MHz clock, counted from its
// instructions (one per cycle): CLK low -> DAT sample 139 cycles (2.11 us; 141
// for the last bit), sample -> CLK high 13 (0.20 us), CLK high -> next CLK low
// 153 (2.32 us) -- a ~219 kHz clock, inside psx-spx's ~250 kHz card timing.
//
// SNAC pins (as the PSX core drives a PS1 port adapter, psx/PSX.sv):
// USER_OUT[1] = /SEL port 1, [0] = /SEL port 2, [2] = CMD, [5] = CLK, [3]/[4]/[6]
// = 1 (inputs: /ACK on USER_IN[3], DAT on USER_IN[4]).  Reader port 0 is cabinet
// player 1's slot, so it drives SNAC port 1.  /ACK uses the PSX core's filter:
// low only after four consecutive low samples.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_wio_port #(
    parameter integer CLK_HZ = 33_868_800
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        en,             // drive the SNAC pins
    // HPS ops
    input  wire        reg_we,         // posted write of the card register
    input  wire [7:0]  reg_val,
    input  wire        latch_clr,      // posted write of 0xb0000005
    input  wire        xfer_start,
    input  wire [7:0]  xfer_cmd,
    input  wire [15:0] xfer_timeout_us,
    output reg         busy,
    output reg         done,           // sticky until the next start
    output reg  [1:0]  result,         // 0 byte, 1 no /ACK (-1), 2 error (-2)
    output reg  [7:0]  rx_byte,
    // pins
    output wire [6:0]  user_out,
    input  wire [6:0]  user_in
);
    // cycles at CLK_HZ for a count of 66 MHz board cycles / microseconds
    // (each at least 1, so a slow simulation clock still steps)
    localparam integer T_SAMPLE_  = (139 * (CLK_HZ / 1000) + 32999) / 66000;
    localparam integer T_SAMPLE7_ = (141 * (CLK_HZ / 1000) + 32999) / 66000;
    localparam integer T_TOHIGH_  = (13  * (CLK_HZ / 1000) + 32999) / 66000;
    localparam integer T_HIGH_    = (153 * (CLK_HZ / 1000) + 32999) / 66000;
    localparam integer T_US_      = (CLK_HZ + 500000) / 1000000;
    localparam integer T_SAMPLE   = (T_SAMPLE_  < 1) ? 1 : T_SAMPLE_;
    localparam integer T_SAMPLE7  = (T_SAMPLE7_ < 1) ? 1 : T_SAMPLE7_;
    localparam integer T_TOHIGH   = (T_TOHIGH_  < 1) ? 1 : T_TOHIGH_;
    localparam integer T_HIGH     = (T_HIGH_    < 1) ? 1 : T_HIGH_;
    localparam integer T_US       = (T_US_      < 1) ? 1 : T_US_;

    reg [7:0] creg;                  // the register as last written
    reg       pend_we;
    reg [7:0] pend_val;

    // ---- /ACK and DAT inputs ----
    reg [3:0] ack_s;                 // ack_s[0] newest
    reg [1:0] dat_s;
    reg       ack_low, ack_low_d, latch;
    always @(posedge clk) begin
        ack_s <= {ack_s[2:0], user_in[3]};
        dat_s <= {dat_s[0], user_in[4]};
        ack_low <= (ack_s == 4'b0000);
        ack_low_d <= ack_low;
    end

    // ---- the engine ----
    localparam E_IDLE = 3'd0, E_LOW = 3'd1, E_TOHIGH = 3'd2, E_HIGH = 3'd3,
               E_WAITACK = 3'd4, E_SETTLE = 3'd5;
    reg [2:0]  es;
    reg [2:0]  bitn;
    // (the longest step is T_HIGH, ~79 cycles at 33.9 MHz; the routine's /ACK
    // timeouts are 40 us and 2000 us -- fw 0x8000582c / 0x800058c8 -- so 12 bits)
    reg [7:0]  cnt;                  // cycles in the current step
    reg [11:0] us_left;
    reg [5:0]  us_div;
    reg [7:0]  sh;
    reg        latch_at7;
    reg [11:0] tmo;

    always @(posedge clk) begin
        if (rst) begin
            creg <= 8'hff; pend_we <= 1'b0;
            latch <= 1'b0;
            es <= E_IDLE; busy <= 1'b0; done <= 1'b0; result <= 2'd0; rx_byte <= 8'hff;
        end else begin
            // the latch catches the falling edge of the filtered /ACK
            if (ack_low && !ack_low_d) latch <= 1'b1;

            if (reg_we) begin pend_we <= 1'b1; pend_val <= reg_val; end
            if (es == E_IDLE && pend_we && !reg_we) begin creg <= pend_val; pend_we <= 1'b0; end
            if (latch_clr && es == E_IDLE) latch <= 1'b0;

            case (es)
            E_IDLE: if (xfer_start) begin
                done <= 1'b0; busy <= 1'b1;
                tmo <= (|xfer_timeout_us[15:12]) ? 12'hfff : xfer_timeout_us[11:0];
                sh <= xfer_cmd;
                bitn <= 3'd0;
                if (latch) begin                         // 1. latch already set
                    result <= 2'd2; done <= 1'b1; busy <= 1'b0;
                end else begin
                    creg <= {creg[7:2], 1'b0, xfer_cmd[0]};   // CLK low, CMD = bit 0
                    cnt <= 8'd0;
                    es <= E_LOW;
                end
            end
            E_LOW: begin
                cnt <= cnt + 8'd1;
                if (cnt == ((bitn == 3'd7) ? T_SAMPLE7 : T_SAMPLE) - 1) begin
                    rx_byte <= {dat_s[1], rx_byte[7:1]};   // DAT, LSB first
                    if (bitn == 3'd7) latch_at7 <= latch;
                    cnt <= 8'd0;
                    es <= E_TOHIGH;
                end
            end
            E_TOHIGH: begin
                cnt <= cnt + 8'd1;
                if (cnt == T_TOHIGH - 1) begin
                    creg[1] <= 1'b1;                     // CLK high
                    cnt <= 8'd0;
                    if (bitn == 3'd7) begin
                        if (latch_at7) begin              // 3.
                            result <= 2'd2; done <= 1'b1; busy <= 1'b0; es <= E_IDLE;
                        end else if (tmo == 12'd0) begin  // 4.
                            result <= 2'd0; done <= 1'b1; busy <= 1'b0; es <= E_IDLE;
                        end else begin
                            us_left <= tmo; us_div <= 6'd0;
                            es <= E_WAITACK;
                        end
                    end else
                        es <= E_HIGH;
                end
            end
            E_HIGH: begin
                cnt <= cnt + 8'd1;
                if (cnt == T_HIGH - 1) begin
                    bitn <= bitn + 3'd1;
                    sh <= {1'b0, sh[7:1]};
                    creg <= {creg[7:2], 1'b0, sh[1]};    // CLK low, CMD = next bit
                    cnt <= 8'd0;
                    es <= E_LOW;
                end
            end
            E_WAITACK: begin                              // 5.
                if (latch) begin
                    us_left <= 12'd7; us_div <= 6'd0;
                    es <= E_SETTLE;
                end else begin
                    us_div <= us_div + 6'd1;
                    if (us_div == T_US - 1) begin
                        us_div <= 6'd0;
                        us_left <= us_left - 12'd1;
                        if (us_left == 12'd1) begin
                            result <= 2'd1; done <= 1'b1; busy <= 1'b0; es <= E_IDLE;
                        end
                    end
                end
            end
            E_SETTLE: begin                               // 6.
                us_div <= us_div + 6'd1;
                if (us_div == T_US - 1) begin
                    us_div <= 6'd0;
                    us_left <= us_left - 12'd1;
                    if (us_left == 12'd1) begin
                        if (ack_low) result <= 2'd2;
                        else begin result <= 2'd0; latch <= 1'b0; end
                        done <= 1'b1; busy <= 1'b0; es <= E_IDLE;
                    end
                end
            end
            default: es <= E_IDLE;
            endcase
        end
    end

    // SNAC pins (registered outputs avoid glitches on the cable)
    reg [6:0] uo;
    always @(posedge clk)
        uo <= en ? {1'b1, creg[1], 1'b1, 1'b1, creg[0], creg[2], creg[3]} : 7'h7f;
    assign user_out = uo;
endmodule
