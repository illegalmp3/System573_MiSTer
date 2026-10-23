// -----------------------------------------------------------------------------
// s573_wio_snac.v - the White I/O's memory card port, as a byte engine on the
//                   MiSTer SNAC (PS1 controller port) pins.
//
// The real board bit-bangs the PS1 card protocol from its CPU through an FPGA
// register (fw 0x8000560c / 0x80005580 / 0x800055b8 / 0x800055e0; register
// 0xb0000003: bit0 = DAT in / CMD out, bit1 = CLK out / ACK latch in, bits 2/3 =
// port selects; 0xb0000005 write = clear the ACK latch). The HPS runs that
// firmware's algorithm (support/s573/s573_whiteio.c) and uses this module for the
// three primitives the firmware's own helpers implement:
//
//   SELECT   (0x80005580(port,1); delay 40; clear latch; 0x80005580(port,0); delay 10)
//   DESELECT (delay 5; 0x80005580(port,1))
//   XFER     one byte, LSB first. Per bit: CLK low + CMD = bit, wait, sample DAT,
//            CLK high, wait (0x42-iteration loops). Then: ACK latch already set ->
//            line error; ack_mode 0 -> done; else wait for the latch up to the
//            timeout (0x28 normal, 0x7d0 long); seen -> wait 7, ACK still low ->
//            line error, else clear the latch and done.
//
// TIMING IS NOT DERIVED FROM HARDWARE. The firmware's delay helper scales its
// argument by 33/2 timer ticks and builds milliseconds as 1000 units, which reads
// as 1 unit = 1 us with a 16.5 MHz timer; the per-half-bit loop is then ~4 us at
// an assumed 33 MHz CPU (125 kHz). Those are the defaults below; all are
// parameters. A PS1 card is clocked by the host and accepts this rate (the PS1
// itself runs at 250 kHz, psx-spx).
//
// Pin levels match the PSX core's SNAC wiring (emu.sv): sel_n / clk / cmd driven,
// dat / ack_n sampled (open-drain lines pulled up off-board).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_wio_snac #(
    parameter integer CLK_HZ   = 33868800,
    parameter integer HALF_US  = 4,       // half a bit
    parameter integer T_SHORT  = 40,      // us, ack_mode 1
    parameter integer T_LONG   = 2000,    // us, ack_mode 2
    parameter integer T_SEL1   = 40,      // us, deselected before the latch clear
    parameter integer T_SEL2   = 10,      // us, selected before the first byte
    parameter integer T_DESEL  = 5,       // us, after the last byte
    parameter integer T_ACKCHK = 7        // us, after the latch is seen
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       en,                 // SNAC owned by the White I/O
    // command (one-cycle start)
    input  wire       start,
    input  wire [1:0] op,                 // 0 SELECT, 1 DESELECT, 2 XFER
    input  wire       port,
    input  wire [1:0] ack_mode,
    input  wire [7:0] tx,
    output reg        busy,
    output reg  [7:0] rx,
    output reg        ack_seen,           // XFER: latch seen (or not waited for)
    output reg        line_err,           // XFER: 0x8000560c's -2 cases
    // pins
    output reg  [1:0] sel_n,
    output reg        clk_o,
    output reg        cmd_o,
    input  wire       dat_i,
    input  wire       ack_n_i
);
    localparam integer KHZ = CLK_HZ / 1000;
    localparam integer C_HALF  = HALF_US  * KHZ / 1000, C_SHORT = T_SHORT * KHZ / 1000,
                       C_LONG  = T_LONG   * KHZ / 1000, C_SEL1  = T_SEL1  * KHZ / 1000,
                       C_SEL2  = T_SEL2   * KHZ / 1000, C_DESEL = T_DESEL * KHZ / 1000,
                       C_ACHK  = T_ACKCHK * KHZ / 1000;

    // synchronisers; /ACK also glitch-filtered the way emu.sv's PSX SNAC path does
    // (low only after several consecutive low samples)
    reg [2:0] ds; reg [4:0] as;
    always @(posedge clk) begin ds <= {ds[1:0], dat_i}; as <= {as[3:0], ack_n_i}; end
    wire dat = ds[2], ack_n = |as[4:1];
    reg  ack_n_d, latch;
    wire ack_fall = ack_n_d & ~ack_n;

    localparam [3:0] S_IDLE = 0, S_SEL1 = 1, S_SEL2 = 2, S_DES = 3, S_LO = 4, S_HI = 5,
                     S_AWAIT = 6, S_ACHK = 7;
    reg [3:0]  st;
    reg [22:0] cnt;                              // up to T_LONG us
    reg [2:0]  bitn;
    reg [7:0]  sh, rxs;
    reg        prt;
    reg [1:0]  am;

    always @(posedge clk) begin
        ack_n_d <= ack_n;
        if (rst || !en) begin
            st <= S_IDLE; busy <= 1'b0; sel_n <= 2'b11; clk_o <= 1'b1; cmd_o <= 1'b1;
            latch <= 1'b0; rx <= 8'hff; ack_seen <= 1'b0; line_err <= 1'b0; cnt <= 23'd0;
        end else begin
            if (ack_fall) latch <= 1'b1;
            if (cnt != 23'd0) cnt <= cnt - 23'd1;
            case (st)
            S_IDLE: if (start) begin
                busy <= 1'b1; prt <= port; am <= ack_mode; sh <= tx;
                case (op)
                2'd0: begin sel_n <= 2'b11; cnt <= C_SEL1; st <= S_SEL1; end
                2'd1: begin cnt <= C_DESEL; st <= S_DES; end
                default: begin
                    ack_seen <= 1'b0; line_err <= 1'b0;
                    if (latch) begin line_err <= 1'b1; busy <= 1'b0; end   // latch set before the byte
                    else begin bitn <= 3'd0; clk_o <= 1'b0; cmd_o <= tx[0]; cnt <= C_HALF; st <= S_LO; end
                end
                endcase
            end
            S_SEL1: if (cnt == 0) begin
                latch <= 1'b0; sel_n <= prt ? 2'b01 : 2'b10; cnt <= C_SEL2; st <= S_SEL2;
            end
            S_SEL2: if (cnt == 0) begin busy <= 1'b0; st <= S_IDLE; end
            S_DES:  if (cnt == 0) begin sel_n <= 2'b11; busy <= 1'b0; st <= S_IDLE; end
            S_LO: if (cnt == 0) begin
                rxs <= {dat, rxs[7:1]};                  // sampled at the end of the low phase
                clk_o <= 1'b1; cnt <= C_HALF; st <= S_HI;
            end
            S_HI: if (cnt == 0) begin
                if (bitn != 3'd7) begin
                    bitn <= bitn + 3'd1; clk_o <= 1'b0; cmd_o <= sh[bitn + 3'd1];
                    cnt <= C_HALF; st <= S_LO;
                end else begin
                    rx <= rxs; cmd_o <= 1'b1;
                    if (latch) begin line_err <= 1'b1; busy <= 1'b0; st <= S_IDLE; end
                    else if (am == 2'd0) begin ack_seen <= 1'b1; busy <= 1'b0; st <= S_IDLE; end
                    else begin cnt <= (am == 2'd2 ? C_LONG : C_SHORT); st <= S_AWAIT; end
                end
            end
            S_AWAIT: begin
                if (latch || ack_fall) begin cnt <= C_ACHK; st <= S_ACHK; end
                else if (cnt == 0) begin ack_seen <= 1'b0; busy <= 1'b0; st <= S_IDLE; end
            end
            S_ACHK: if (cnt == 0) begin
                if (!ack_n) line_err <= 1'b1; else begin ack_seen <= 1'b1; latch <= 1'b0; end
                busy <= 1'b0; st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
