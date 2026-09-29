// -----------------------------------------------------------------------------
// s573_tk_nv.v - M48T58 timekeeper NVRAM <-> the slot-4 save file's extra blocks
//
// WHY (ddrextrm NOTE 605 "RTC-RAM cleared", 2026-09-28). Every System 573 game keeps
// its operator settings, bookkeeping and coin counters in the M48T58's 8 KB battery-
// backed SRAM (0x1f620000, ksys573.cpp:977). MAME persists that device as NVRAM, so the
// note appears on the FIRST run only (ksys573.cpp "Note 4: Some games require you to
// press f2 to skip the rtc cleared note"). The core's only save-back for it was the
// ioctl upload the .mra <nvram index="3"> tag drives, and an .mgl launch never fires
// it, so every boot started from a blank timekeeper and the game re-asked for its
// settings. This module lets s573_flash_saver carry the 8 KB image as NINE extra 1 KB
// blocks of the same slot-4 .sav (after the flash image(s) and the cassette block, if
// any): one header block, then the image itself, and it asks the saver for a PARTIAL
// save (those blocks only) once the game has written the timekeeper and then left it
// quiet, or kept it dirty for too long.
//
// Region layout (block k = 1 KB; word w of a block = {byte 2w+1, byte 2w}):
//   block 0        header: [0:7] "573NVTKP" magic, [8] version = 1, [9] type = 1
//                  (M48T58), [10:11] image length little-endian = 8192, rest 0.
//   blocks 1..8    the 8 KB image, byte (k-1)*1024 + b of the timekeeper (MAME .nvm
//                  order; bytes 8184..8191 are the live clock registers on SAVE; on
//                  LOAD they are skipped when the host clock is usable (the clock is
//                  set from MiSTer's RTC) and 8185..8191 are applied when it is not).
// A LOAD applies blocks 1..8 to the m48t58 load port ONLY when the header block
// matched; a blank (all-zero) region -- a freshly grown .sav -- or a legacy file
// without the region leaves whatever the .mgl loaded (e.g. hyperbbc's .22h) untouched.
//
// Save timing: nv_written (the game's EXP1 write strobe into the timekeeper) sets
// `dirty` and restarts a quiet timer; the request goes out when the image has been
// quiet for QUIET_CYC or dirty for AGE_CYC without a gap (a game that writes its
// bookkeeping continuously must still be saved). The saver answers with save_started
// the cycle the partial save begins, which clears `dirty` -- a write landing after
// that (whether or not the snapshot caught it) simply re-arms the next save.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_tk_nv #(
    // clk_1x ~33.8688 MHz: 3.0 s of quiet, or 30 s dirty without a break.
    parameter integer QUIET_CYC = 101_606_400,
    parameter integer AGE_CYC   = 1_016_064_000
)(
    input  wire        clk,
    input  wire        rst,
    // ---- s573_flash_saver SAVE side (addr = {region block 0..8, word 0..511}) ----
    input  wire        xtra_rd_req,
    input  wire [12:0] xtra_rd_addr,
    output reg  [15:0] xtra_rd_word,
    output reg         xtra_rd_ack,
    // ---- s573_flash_saver LOAD side ----
    input  wire        xtra_wr_req,
    input  wire [12:0] xtra_wr_addr,
    input  wire [15:0] xtra_wr_word,
    output reg         xtra_wr_ack,
    // ---- m48t58 save read port (1-cycle registered read, write-priority shared) ----
    output reg  [12:0] sav_addr,
    input  wire [7:0]  sav_dout,
    input  wire        sav_rd_ok,
    // ---- m48t58 image load port (emu muxes this with the ioctl index-3 download) ----
    output reg         load_we,
    output reg  [12:0] load_addr,
    output reg  [7:0]  load_data,
    // ---- dirty tracking -> partial save ----
    // LEVEL: also restore the saved clock bytes 8185..8191 (the parent asserts it when
    // the host has no usable clock -- a MiSTer with no RTC battery and no network
    // reports 1970 -- so the game's clock resumes from the last save, the closest thing
    // to a live battery this setup can offer). The control byte 8184 is never restored.
    input  wire        restore_clock,
    input  wire        nv_written,     // 1-cycle: the game wrote the timekeeper
    output wire        save_req,       // LEVEL: please run a partial save
    input  wire        save_started,   // 1-cycle: the saver began it (clears dirty)
    output reg         restored        // sticky until rst: a saved image was applied
);
    localparam [7:0]  VERSION = 8'd1, TYPE_M48T58 = 8'd1;
    localparam [12:0] RTC_BASE = 13'd8184;
    localparam integer IMG_BLOCKS = 8;

    function [7:0] magic(input [3:0] i);
        case (i)
            4'd0: magic = "5"; 4'd1: magic = "7"; 4'd2: magic = "3"; 4'd3: magic = "N";
            4'd4: magic = "V"; 4'd5: magic = "T"; 4'd6: magic = "K"; default: magic = "P";
        endcase
    endfunction
    // header byte b: the constant the header block must hold there
    function [7:0] hdr(input [9:0] b);
        if (b < 10'd8)        hdr = magic(b[3:0]);
        else if (b == 10'd8)  hdr = VERSION;
        else if (b == 10'd9)  hdr = TYPE_M48T58;
        else if (b == 10'd10) hdr = 8'h00;   // 8192 = 0x2000 little-endian
        else if (b == 10'd11) hdr = 8'h20;
        else                  hdr = 8'd0;
    endfunction

    // ---------------- SAVE: produce word xtra_rd_addr ----------------
    // Image bytes come off the m48t58 save port: present the address, wait one cycle
    // for the registered read, then take the byte if no bus/loader write stole that
    // port cycle (sav_rd_ok), else re-present it. Same fetch timing as
    // s573_nvram_saver (set -> read in flight -> capture).
    localparam [2:0] R_IDLE = 3'd0, R_SET = 3'd1, R_WAIT = 3'd2, R_CAP = 3'd3, R_ACK = 3'd4;
    reg [2:0]  rs;
    reg [3:0]  rblk;
    reg [8:0]  rword;
    reg        rhi;           // 0 = fetching the low byte, 1 = the high byte
    wire [12:0] rbyte = {rblk[2:0] - 3'd1, rword, rhi};   // image byte address (blocks 1..8)
    always @(posedge clk) begin
        xtra_rd_ack <= 1'b0;
        if (rst) begin
            rs <= R_IDLE; rblk <= 4'd0; rword <= 9'd0; rhi <= 1'b0;
            sav_addr <= 13'd0; xtra_rd_word <= 16'd0;
        end else case (rs)
            R_IDLE: if (xtra_rd_req) begin
                rblk  <= xtra_rd_addr[12:9];
                rword <= xtra_rd_addr[8:0];
                rhi   <= 1'b0;
                if (xtra_rd_addr[12:9] == 4'd0) begin
                    // header block: constants, no port access
                    xtra_rd_word <= {hdr({xtra_rd_addr[8:0], 1'b1}), hdr({xtra_rd_addr[8:0], 1'b0})};
                    rs <= R_ACK;
                end else if (xtra_rd_addr[12:9] > IMG_BLOCKS[3:0]) begin
                    xtra_rd_word <= 16'd0;                 // beyond the image: zeros
                    rs <= R_ACK;
                end else begin
                    rs <= R_SET;
                end
            end
            R_SET:  begin sav_addr <= rbyte; rs <= R_WAIT; end
            R_WAIT: rs <= R_CAP;                           // read in flight this cycle
            R_CAP: begin
                if (sav_rd_ok) begin
                    if (rhi) begin xtra_rd_word[15:8] <= sav_dout; rs <= R_ACK; end
                    else     begin xtra_rd_word[7:0]  <= sav_dout; rhi <= 1'b1; rs <= R_SET; end
                end else begin
                    rs <= R_SET;                           // displaced by a write: retry
                end
            end
            R_ACK: begin xtra_rd_ack <= 1'b1; rs <= R_IDLE; end
            default: rs <= R_IDLE;
        endcase
    end

    // ---------------- LOAD: consume word xtra_wr_addr ----------------
    // The header block (region block 0) arrives before any image block, so hdr_ok is
    // final before the first image byte could be applied. Image bytes at or above
    // RTC_BASE are the saved clock registers: skipped (the clock is set from the
    // MiSTer RTC, see m48t58 set_*).
    localparam [1:0] W_IDLE = 2'd0, W_B1 = 2'd1, W_ACK = 2'd2;
    reg [1:0]  ws;
    reg [12:0] wbyte;         // image byte address of the HIGH byte of the word
    reg [7:0]  whi;
    reg        hdr_ok;
    wire [3:0] wblk  = xtra_wr_addr[12:9];
    wire [9:0] wbhdr = {xtra_wr_addr[8:0], 1'b0};          // byte index within the header block
    wire       w_img = (wblk >= 4'd1) && (wblk <= IMG_BLOCKS[3:0]);
    // a byte is applied if it is below the clock, or a clock byte other than control
    // while restore_clock is set
    function apply_ok(input [12:0] b, input rc);
        apply_ok = (b < RTC_BASE) || (rc && (b > RTC_BASE));
    endfunction
    wire [12:0] w_lo = {wblk[2:0] - 3'd1, xtra_wr_addr[8:0], 1'b0};
    always @(posedge clk) begin
        xtra_wr_ack <= 1'b0;
        load_we     <= 1'b0;
        if (rst) begin
            ws <= W_IDLE; hdr_ok <= 1'b0; restored <= 1'b0;
            load_addr <= 13'd0; load_data <= 8'd0; wbyte <= 13'd0; whi <= 8'd0;
        end else case (ws)
            W_IDLE: if (xtra_wr_req) begin
                whi   <= xtra_wr_word[15:8];
                wbyte <= w_lo | 13'd1;
                if (wblk == 4'd0) begin
                    // header block: verify the constant bytes (words 0..7)
                    if (xtra_wr_addr[8:0] == 9'd0)
                        hdr_ok <= (xtra_wr_word[7:0] == hdr(10'd0));  // a new region starts
                    else if (wbhdr < 10'd16)
                        hdr_ok <= hdr_ok & (xtra_wr_word[7:0] == hdr(wbhdr));
                end
`ifndef TK_NV_NO_RESTORE
                else if (hdr_ok && w_img && apply_ok(w_lo, restore_clock)) begin
                    load_we   <= 1'b1;
                    load_addr <= w_lo;
                    load_data <= xtra_wr_word[7:0];
                end
`endif
                ws <= W_B1;
            end
            W_B1: begin                                  // high byte of the word
                if (wblk == 4'd0) begin
                    if ((wbhdr | 10'd1) < 10'd16)
                        hdr_ok <= hdr_ok & (whi == hdr(wbhdr | 10'd1));
                end
`ifndef TK_NV_NO_RESTORE
                else if (hdr_ok && w_img && apply_ok(wbyte, restore_clock)) begin
                    load_we   <= 1'b1;
                    load_addr <= wbyte;
                    load_data <= whi;
                end
                if (hdr_ok && w_img && wbyte == RTC_BASE - 13'd1) restored <= 1'b1;
`endif
                ws <= W_ACK;
            end
            W_ACK: begin xtra_wr_ack <= 1'b1; ws <= W_IDLE; end
            default: ws <= W_IDLE;
        endcase
    end

    // ---------------- dirty tracking ----------------
    localparam integer QW = $clog2(QUIET_CYC + 1);
    localparam integer AW = $clog2(AGE_CYC + 1);
    reg          dirty = 1'b0;
    reg [QW-1:0] quiet = {QW{1'b0}};
    reg [AW-1:0] age   = {AW{1'b0}};
    always @(posedge clk) begin
        if (rst) begin
            dirty <= 1'b0; quiet <= {QW{1'b0}}; age <= {AW{1'b0}};
        end else begin
            if (dirty && age != AGE_CYC[AW-1:0]) age <= age + 1'b1;
            if (quiet != QUIET_CYC[QW-1:0])      quiet <= quiet + 1'b1;
            if (save_started) begin dirty <= 1'b0; age <= {AW{1'b0}}; end
            // a write in the same cycle as the start wins: it may have missed the snapshot
            if (nv_written) begin
                if (!dirty || save_started) age <= {AW{1'b0}};
                dirty <= 1'b1;
                quiet <= {QW{1'b0}};
            end
        end
    end
    assign save_req = dirty && ((quiet == QUIET_CYC[QW-1:0]) || (age == AGE_CYC[AW-1:0]));
endmodule
