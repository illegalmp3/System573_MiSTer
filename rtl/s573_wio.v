// -----------------------------------------------------------------------------
// s573_wio.v - the White I/O memory card reader's fabric half
//
// A Dance Dance Revolution cabinet's card reader is a separate board, Konami
// GE885-PWB(A) (TX3904 CPU, its own boot ROM 885a01, a Xilinx FPGA, two PS1
// card slots), on the 573's JVS port. The 573 reaches it through its H8/3644
// JVS MCU. The board's CPU and its program -- uploaded by the game -- run in
// MiSTer_System573 on the HPS (support/s573/wio*.c); what has to be here is
//   * the 573's JVS MCU, register for register (s573_jvs_mcu.v, psx-spx), and
//   * for real cards on SNAC, the reader's card byte exchange at the pins
//     (s573_wio_port.v).
// The HPS reaches both over CMD_573_WIO, a sub-channel of the 573 SPI mailbox
// (s573_hps_ext.v forwards each word of command 0x6F here; same-word response:
// `dout` must be valid, combinationally, at the strobe of the word it answers).
//
// CMD_573_WIO protocol (one op per transaction):
//   word0 (cmd)  up: status {attached, osd_en, waiting, port_busy, port_done,
//                            port_result[1:0], 0, req_seq[7:0]}
//   word1        dn: {op, arg}   up: {xfer_cnt[3:0], 00, port_result[1:0], rx_byte}
//   op 00 NOP
//   op 01 ATTACH   arg[0]: the board emulation is running (gates the MCU and pins)
//   op 02 SENSE    arg[0]: the board's JVS sense output (PIO1 bit 29)
//   op 03 CARDREG  arg: the card register 0xb0000003 as the board's CPU wrote it
//   op 04 LATCHCLR the /ACK latch clear 0xb0000005
//   op 05 XFER     arg: command byte; word2 dn: /ACK timeout in us -> starts the
//                  byte exchange (routine 0x8000560c); poll NOP for the result
//   op 06 GETREQ   word2 up: request length (bytes); word3 up: its req_seq;
//                  word4.. up: the request, two bytes per word, little endian
//   op 07 PUTRESP  word2 dn: response length (bytes); word3 dn: the req_seq it
//                  answers; word4.. dn: the response, two bytes per word. The
//                  word that completes it commits it; a shorter transaction
//                  commits nothing.
//
// osd_en = 0 (OSD "573 Card Reader" Off) or no ATTACH from the HPS: the JVS bits
// read the constants they always did and the SNAC pins stay released.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_wio #(
    parameter integer CLK_HZ = 33_868_800
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        osd_en,         // OSD: a reader is fitted
    input  wire        snac_en,        // OSD: a card slot is on SNAC

    // ---- 573 side (s573_io / bus) ----
    input  wire        mcu_rst_n,      // 0x1f400000 bit 8
    input  wire        jvs_wr,         // 0x1f680000 write strobe
    input  wire [15:0] jvs_wdata,
    input  wire        jvs_clr,        // 0x1f520000 write strobe
    output wire [1:0]  jvs_status,
    output wire [1:0]  jvs_error,
    output wire        jvs_irdy,
    output wire        jvs_drdy,
    output wire        jvs_sense,
    output wire [15:0] jvs_rdata,

    // ---- HPS: CMD_573_WIO words (s573_hps_ext) ----
    input  wire        stb,            // one word of the command, idx 0 = the command word
    input  wire [9:0]  idx,
    input  wire [15:0] din,
    output reg  [15:0] dout,           // combinational: the answer to this word

    // ---- SNAC ----
    output wire [6:0]  user_out,
    input  wire [6:0]  user_in
);
    reg        attached;
    reg        sense_r;
    reg  [7:0] op;
    wire       en = osd_en & attached;

    // ---- MCU ----
    reg  [7:0] req_raddr;
    wire [15:0] req_rword;
    wire [7:0] req_seq;
    wire [8:0] req_len;
    wire       waiting;
    reg        resp_we, resp_commit;
    reg  [7:0] resp_waddr;
    reg  [15:0] resp_wword;
    reg  [8:0] resp_len;
    reg  [7:0] resp_seq;

    s573_jvs_mcu u_mcu (
        .clk(clk), .rst(rst), .en(en),
        .mcu_rst_n(mcu_rst_n), .wr_data(jvs_wr), .wdata(jvs_wdata), .clr_irdy(jvs_clr),
        .status(jvs_status), .error(jvs_error), .irdy(jvs_irdy), .drdy(jvs_drdy),
        .sense(jvs_sense), .rdata(jvs_rdata),
        .req_seq(req_seq), .req_len(req_len), .req_raddr(req_raddr), .req_rword(req_rword),
        .resp_we(resp_we), .resp_waddr(resp_waddr), .resp_wword(resp_wword),
        .resp_commit(resp_commit), .resp_len(resp_len), .resp_seq(resp_seq),
        .sense_in(sense_r), .waiting(waiting));

    // ---- card port ----
    reg        p_reg_we, p_latch_clr, p_start;
    reg  [7:0] p_reg_val, p_cmd;
    reg [15:0] p_tmo;
    wire       p_busy, p_done;
    wire [1:0] p_result;
    wire [7:0] p_rx;
    reg  [3:0] xfer_cnt;
    reg        p_done_d;

    s573_wio_port #(.CLK_HZ(CLK_HZ)) u_port (
        .clk(clk), .rst(rst), .en(en & snac_en),
        .reg_we(p_reg_we), .reg_val(p_reg_val), .latch_clr(p_latch_clr),
        .xfer_start(p_start), .xfer_cmd(p_cmd), .xfer_timeout_us(p_tmo),
        .busy(p_busy), .done(p_done), .result(p_result), .rx_byte(p_rx),
        .user_out(user_out), .user_in(user_in));

    // ---- the answer to each word ----
    always @(*) begin
        case (idx)
        10'd0:   dout = {attached, osd_en, waiting, p_busy, p_done, p_result, 1'b0, req_seq};
        10'd1:   dout = {xfer_cnt, 2'b00, p_result, p_rx};
        10'd2:   dout = (op == 8'h06) ? {7'd0, req_len} : 16'h0000;
        10'd3:   dout = (op == 8'h06) ? {8'd0, req_seq} : 16'h0000;
        default: dout = (op == 8'h06) ? req_rword : 16'h0000;
        endcase
    end

    wire [9:0] resp_words = {1'b0, resp_len} + 10'd1;      // (len + 1) / 2 in [9:1]

    always @(posedge clk) begin
        p_reg_we <= 1'b0; p_latch_clr <= 1'b0; p_start <= 1'b0;
        resp_we <= 1'b0; resp_commit <= 1'b0;
        p_done_d <= p_done;
        if (p_done && !p_done_d) xfer_cnt <= xfer_cnt + 4'd1;

        if (rst) begin
            attached <= 1'b0; sense_r <= 1'b1; op <= 8'h00; xfer_cnt <= 4'd0;
            req_raddr <= 8'd0;
        end else if (stb) begin
            case (idx)
            10'd0: op <= 8'h00;
            10'd1: begin
                op <= din[15:8];
                case (din[15:8])
                8'h01: attached <= din[0];
                8'h02: sense_r <= din[0];
                8'h03: begin p_reg_we <= 1'b1; p_reg_val <= din[7:0]; end
                8'h04: p_latch_clr <= 1'b1;
                8'h05: p_cmd <= din[7:0];
                8'h06: req_raddr <= 8'd0;
                default: ;
                endcase
            end
            10'd2: begin
                if (op == 8'h05) begin p_tmo <= din; p_start <= 1'b1; end
                if (op == 8'h07) resp_len <= din[8:0];
            end
            10'd3: if (op == 8'h07) resp_seq <= din[7:0];
            default: begin
                if (op == 8'h06) req_raddr <= req_raddr + 8'd1;
                if (op == 8'h07 && idx - 10'd4 < {1'b0, resp_words[9:1]}) begin
                    resp_we <= 1'b1;
                    resp_waddr <= idx[7:0] - 8'd4;
                    resp_wword <= din;
                    if (idx - 10'd4 == {1'b0, resp_words[9:1]} - 10'd1) resp_commit <= 1'b1;
                end
            end
            endcase
        end
    end
endmodule
