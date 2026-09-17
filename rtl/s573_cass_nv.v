// -----------------------------------------------------------------------------
// s573_cass_nv.v - ZS01 security-cassette NVRAM <-> the slot-4 save file's extra block
//
// WHY (ddrextrm ERROR 175, 2026-09-16). MAME treats the ZS01 as NVRAM: zs01.cpp
// nvram_read/nvram_write persist {response-to-reset, command key, data key, config
// registers, 112 data bytes} -- the .u1 layout. A DDR Extreme install WRITES the
// cassette (5 accepted WRITE packets to sector 7 were logged on hardware) and records
// the matching install in flash. The core re-loads the pristine .u1 on every launch,
// so after a power cycle the flash install and the cassette disagree and the game
// stops with ERROR 175 "cassette does not match this unit". This module lets
// s573_flash_saver carry the cassette state as ONE extra 1 KB block after the flash
// image(s) in the same slot-4 .sav (MiSTer Main parses at most six .mgl items and the
// launchers already use all six, so there is no separate file to give it).
//
// Block layout (bytes; a word w = {byte 2w+1, byte 2w}, the WIDE sd_buff order):
//   [0:7]   "573NVCAS" magic
//   [8]     format version = 1
//   [9]     cart type = 2 (ZS01)
//   [10:11] image length, little-endian = 140
//   [16:155] the 140-byte image, .u1 / MAME nvram order
//   everything else 0.
// A LOAD applies the image to the ZS01 load port ONLY if magic, version, type and
// length all match -- a blank (all-zero) block, a legacy file without the block, or an
// ERASE leave the .u1 that the .mgl loaded untouched.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_cass_nv (
    input  wire        clk,
    input  wire        rst,
    input  wire [1:0]  cart_type,      // 2 = ZS01 -> the extra block is carried
    output wire        xtra_en,
    // ---- s573_flash_saver SAVE side ----
    input  wire        xtra_rd_req,
    input  wire [8:0]  xtra_rd_addr,
    output reg  [15:0] xtra_rd_word,
    output reg         xtra_rd_ack,
    // ---- s573_flash_saver LOAD side ----
    input  wire        xtra_wr_req,
    input  wire [8:0]  xtra_wr_addr,
    input  wire [15:0] xtra_wr_word,
    output reg         xtra_wr_ack,
    // ---- ZS01 dump port (2-clock latency) ----
    output reg  [7:0]  dump_addr,
    input  wire [7:0]  dump_data,
    // ---- ZS01 load port (emu muxes this with the .u1 download) ----
    output reg         load_we,
    output reg  [12:0] load_addr,
    output reg  [7:0]  load_data,
    output reg         restored        // sticky until rst: a saved cassette image was applied
);
    localparam [7:0] VERSION = 8'd1, TYPE_ZS01 = 8'd2;
    localparam [7:0] IMG_LEN = 8'd140;
    localparam integer IMG_OFF = 16;

    assign xtra_en = (cart_type == 2'd2);

    function [7:0] magic(input [3:0] i);
        case (i)
            4'd0: magic = "5"; 4'd1: magic = "7"; 4'd2: magic = "3"; 4'd3: magic = "N";
            4'd4: magic = "V"; 4'd5: magic = "C"; 4'd6: magic = "A"; default: magic = "S";
        endcase
    endfunction
    // header byte b (b < 16): the constant the block must hold there
    function [7:0] hdr(input [9:0] b);
        if (b < 10'd8)        hdr = magic(b[3:0]);
        else if (b == 10'd8)  hdr = VERSION;
        else if (b == 10'd9)  hdr = TYPE_ZS01;
        else if (b == 10'd10) hdr = IMG_LEN;
        else                  hdr = 8'd0;
    endfunction
    function is_img(input [9:0] b);
        is_img = (b >= IMG_OFF) && (b < IMG_OFF + 140);
    endfunction

    // ---------------- SAVE: produce word xtra_rd_addr ----------------
    localparam [2:0] R_IDLE = 3'd0, R_LO = 3'd1, R_HI = 3'd2, R_ACK = 3'd3;
    reg [2:0]  rs;
    reg [1:0]  rwait;
    reg [9:0]  rb;          // byte index being produced
    always @(posedge clk) begin
        xtra_rd_ack <= 1'b0;
        if (rst) begin
            rs <= R_IDLE; rwait <= 2'd0; rb <= 10'd0; dump_addr <= 8'd0; xtra_rd_word <= 16'd0;
        end else case (rs)
            R_IDLE: if (xtra_rd_req) begin
                rb        <= {xtra_rd_addr, 1'b0};
                dump_addr <= xtra_rd_addr * 2 - IMG_OFF;   // only used when is_img
                rwait     <= 2'd3;
                rs        <= R_LO;
            end
            R_LO: if (rwait != 2'd0) rwait <= rwait - 2'd1; else begin
                xtra_rd_word[7:0] <= is_img(rb) ? dump_data : (rb < 10'd16 ? hdr(rb) : 8'd0);
                rb        <= rb + 10'd1;
                dump_addr <= rb + 10'd1 - IMG_OFF;
                rwait     <= 2'd3;
                rs        <= R_HI;
            end
            R_HI: if (rwait != 2'd0) rwait <= rwait - 2'd1; else begin
                xtra_rd_word[15:8] <= is_img(rb) ? dump_data : (rb < 10'd16 ? hdr(rb) : 8'd0);
                rs <= R_ACK;
            end
            R_ACK: begin xtra_rd_ack <= 1'b1; rs <= R_IDLE; end
            default: rs <= R_IDLE;
        endcase
    end

    // ---------------- LOAD: consume word xtra_wr_addr ----------------
    // Header words 0..5 arrive before any image word (16..155 = words 8..77), so the
    // verdict is final before the first image byte could be applied.
    localparam [1:0] W_IDLE = 2'd0, W_B1 = 2'd1, W_ACK = 2'd2;
    reg [1:0]  ws;
    reg [9:0]  wb;
    reg [7:0]  whi;
    reg        hdr_ok;
    always @(posedge clk) begin
        xtra_wr_ack <= 1'b0;
        load_we     <= 1'b0;
        if (rst) begin
            ws <= W_IDLE; hdr_ok <= 1'b0; restored <= 1'b0; load_addr <= 13'd0; load_data <= 8'd0;
        end else case (ws)
            W_IDLE: if (xtra_wr_req) begin
                wb  <= {xtra_wr_addr, 1'b0} + 10'd1;
                whi <= xtra_wr_word[15:8];
                // low byte of this word
                if (xtra_wr_addr == 9'd0)
                    hdr_ok <= (xtra_wr_word[7:0] == hdr(10'd0));           // a new block starts
                else if ({xtra_wr_addr, 1'b0} < 10'd16)
                    hdr_ok <= hdr_ok & (xtra_wr_word[7:0] == hdr({xtra_wr_addr, 1'b0}));
`ifndef CASS_NV_NO_RESTORE
                else if (hdr_ok && is_img({xtra_wr_addr, 1'b0})) begin
                    load_we   <= 1'b1;
                    load_addr <= {xtra_wr_addr, 1'b0} - IMG_OFF;
                    load_data <= xtra_wr_word[7:0];
                end
`endif
                ws <= W_B1;
            end
            W_B1: begin                                  // high byte of the word
                if (wb < 10'd16)
                    hdr_ok <= hdr_ok & (whi == hdr(wb));
`ifndef CASS_NV_NO_RESTORE
                else if (hdr_ok && is_img(wb)) begin
                    load_we   <= 1'b1;
                    load_addr <= wb - IMG_OFF;
                    load_data <= whi;
                    if (wb == IMG_OFF + 139) restored <= 1'b1;
                end
`endif
                ws <= W_ACK;
            end
            W_ACK: begin xtra_wr_ack <= 1'b1; ws <= W_IDLE; end
            default: ws <= W_IDLE;
        endcase
    end
endmodule
