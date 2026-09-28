`timescale 1ns/1ps
// =============================================================================
// tb_s573_tk_nv.v - M48T58 timekeeper persistence through the slot-4 save
// (ddrextrm NOTE 605 "RTC-RAM cleared", 2026-09-28).
//
// REAL modules: s573_flash_saver (scaled 2 onboard + 3 card blocks, card fitted),
// s573_tk_nv, m48t58. The cassette block (region block 0) is a TB stub so the
// extra-block MUX emu.sv builds (cassette first, timekeeper region after it) is
// exercised: xtra_blocks = 1 + 9 = 10, file = 2 + 3 + 10 = 15 blocks.
//
//   1. Full SAVE writes 15 blocks: block 5 = the cassette stub, block 6 = the header,
//      blocks 7..14 = the 8 KB image (bytes 8184..8191 = the live clock registers).
//   2. "Power cycle": the timekeeper is zeroed (as the M10K powers up blank).
//   3. LOAD of the 15-block file restores bytes 0..8183 byte-exact (8184 load writes,
//      the clock bytes are NOT applied), `restored` set. RED under TK_NV_NO_RESTORE.
//   4. Legacy 6-block file (no region): nothing applied.
//   5. Blank (all-zero) region: nothing applied.
//   6. PARTIAL save: a game write, then quiet -> save_req; the saver rewrites ONLY
//      blocks 6..14 (the cassette block and the flash are not touched, no SDRAM read),
//      the new byte is in the file, dirty is cleared (no second request until the
//      next write). A game writing DURING the partial save (port-cycle steals) still
//      yields a coherent block.
//   7. A game that never stops writing is saved by the AGE path.
//   8. Host clock: a set during rst lands; the first set after rst re-syncs ONCE; a
//      later set is ignored; the game's own clock write stands.
//   9. ERASE zeroes the region.
// =============================================================================
module tb_s573_tk_nv;
    localparam integer NUM_BLOCKS  = 2;
    localparam integer CARD_BLOCKS = 3;
    localparam integer WPB         = 512;
    localparam integer FLASH_WORDS = NUM_BLOCKS * WPB;
    localparam integer CARD_WORDS  = CARD_BLOCKS * WPB;
    localparam integer XTRA        = 10;                       // 1 cassette + 9 timekeeper
    localparam integer FILE_BLOCKS = NUM_BLOCKS + CARD_BLOCKS + XTRA;
    localparam integer FILE_WORDS  = FILE_BLOCKS * WPB;
    localparam integer XBASE       = (NUM_BLOCKS + CARD_BLOCKS) * WPB;   // word index of block 5
    localparam integer TKBASE      = XBASE + WPB;                        // block 6 = header
    localparam integer IMGBASE     = TKBASE + WPB;                       // block 7 = image byte 0
    localparam integer QUIET       = 2000;
    localparam integer AGE         = 40000;

    reg clk = 0; always #5 clk = ~clk;
    reg reset = 1;          // saver + tk_nv reset (emu saver_reset)
    reg rst   = 1;          // core reset (m48t58 rst)

    // ---------------- timekeeper ----------------
    reg  [12:0] addr = 0; reg [7:0] din = 0; reg we = 0; wire [7:0] dout;
    reg         T_we = 0; reg [12:0] T_addr = 0; reg [7:0] T_data = 0;   // tb "ioctl" loader
    wire        N_we; wire [12:0] N_addr; wire [7:0] N_data;              // tk_nv restore
    integer     n_we_cnt = 0;
    always @(posedge clk) if (N_we) n_we_cnt = n_we_cnt + 1;
    wire        L_we   = T_we | N_we;
    wire [12:0] L_addr = N_we ? N_addr : T_addr;
    wire [7:0]  L_data = N_we ? N_data : T_data;
    wire [12:0] sav_addr; wire [7:0] sav_dout; wire sav_rd_ok;
    reg         set_valid = 0, set_stb = 0; reg [55:0] set_data = 0;
    m48t58 #(.CLK_FREQ_HZ(1)) tk (
        .clk(clk), .rst(rst), .addr(addr), .din(din), .we(we), .dout(dout),
        .nvram_we(L_we), .nvram_addr(L_addr), .nvram_din(L_data),
        .sav_addr(sav_addr), .sav_dout(sav_dout), .sav_rd_ok(sav_rd_ok),
        .set_valid(set_valid), .set_stb(set_stb), .set_data(set_data)
    );

    // ---------------- NV glue (emu.sv mux, cassette = stub) ----------------
    wire x_rd_req, x_rd_ack, x_wr_req, x_wr_ack;
    wire [12:0] x_rd_addr, x_wr_addr; wire [15:0] x_rd_word, x_wr_word;
    wire tk_rd_req, tk_rd_ack, tk_wr_req, tk_wr_ack; wire [15:0] tk_rd_word;
    wire rd_is_cass = (x_rd_addr[12:9] == 4'd0);
    wire wr_is_cass = (x_wr_addr[12:9] == 4'd0);
    wire [7:0] x_lo = x_rd_addr[7:0];
    reg  cass_rd_ack = 0, cass_wr_ack = 0; reg [15:0] cass_rd_word = 0; reg [1:0] cd = 0;
    integer cass_wr_cnt = 0;
    always @(posedge clk) begin
        cass_rd_ack <= 0; cass_wr_ack <= 0;
        if (x_rd_req & rd_is_cass) begin cd <= 2; cass_rd_word <= 16'hCA00 | {8'd0, x_lo}; end
        else if (cd != 0) begin cd <= cd - 1; if (cd == 1) cass_rd_ack <= 1; end
        if (x_wr_req & wr_is_cass) begin cass_wr_ack <= 1; cass_wr_cnt = cass_wr_cnt + 1; end
    end
    assign tk_rd_req = x_rd_req & ~rd_is_cass;
    assign tk_wr_req = x_wr_req & ~wr_is_cass;
    assign x_rd_word = rd_is_cass ? cass_rd_word : tk_rd_word;
    assign x_rd_ack  = cass_rd_ack | tk_rd_ack;
    assign x_wr_ack  = cass_wr_ack | tk_wr_ack;
    wire [12:0] tk_rd_a = {x_rd_addr[12:9] - 4'd1, x_rd_addr[8:0]};
    wire [12:0] tk_wr_a = {x_wr_addr[12:9] - 4'd1, x_wr_addr[8:0]};
    wire save_req, part_started, part_done, restored;
    reg  nv_written = 0;
    s573_tk_nv #(.QUIET_CYC(QUIET), .AGE_CYC(AGE)) nv (
        .clk(clk), .rst(reset),
        .xtra_rd_req(tk_rd_req), .xtra_rd_addr(tk_rd_a), .xtra_rd_word(tk_rd_word), .xtra_rd_ack(tk_rd_ack),
        .xtra_wr_req(tk_wr_req), .xtra_wr_addr(tk_wr_a), .xtra_wr_word(x_wr_word), .xtra_wr_ack(tk_wr_ack),
        .sav_addr(sav_addr), .sav_dout(sav_dout), .sav_rd_ok(sav_rd_ok),
        .load_we(N_we), .load_addr(N_addr), .load_data(N_data),
        .nv_written(nv_written), .save_req(save_req), .save_started(part_started), .restored(restored)
    );

    // ---------------- saver ----------------
    reg  save_trigger = 0, erase_trigger = 0, load_arm = 0;
    reg  [31:0] load_blocks = 0;
    wire busy, saving, save_done, erase_done, auto_saved;
    wire sd_rd, sd_wr; wire [31:0] sd_lba;
    reg  sd_ack = 0, sd_buff_wr = 0; reg [8:0] sd_buff_addr = 0; reg [15:0] sd_buff_dout = 0;
    wire [15:0] sd_buff_din;
    wire mem_req; wire [26:0] mem_addr; wire mem_card; reg [127:0] mem_q = 0; reg mem_ready = 0;
    wire wr_req, wr_busy; wire [26:0] wr_addr; wire wr_card; wire [15:0] wr_data; reg wr_ack = 0;
    s573_flash_saver #(.NUM_BLOCKS(NUM_BLOCKS), .CARD_BLOCKS(CARD_BLOCKS), .AUTOSAVE_THRESH(1000000)) dut (
        .clk(clk), .reset(reset),
        .save_trigger(save_trigger), .erase_trigger(erase_trigger),
        .flash_wr_ack(1'b0), .autosave_en(1'b0), .auto_saved(auto_saved),
        .load_arm(load_arm), .card_en(1'b1), .load_blocks(load_blocks),
        .busy(busy), .saving(saving), .save_done(save_done), .erase_done(erase_done),
        .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_lba(sd_lba), .sd_ack(sd_ack),
        .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr),
        .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_card(mem_card), .mem_q(mem_q), .mem_ready(mem_ready),
        .wr_req(wr_req), .wr_busy(wr_busy), .wr_addr(wr_addr), .wr_card(wr_card), .wr_data(wr_data), .wr_ack(wr_ack),
        .xtra_blocks(4'd10), .xtra_rd_req(x_rd_req), .xtra_rd_addr(x_rd_addr), .xtra_rd_word(x_rd_word), .xtra_rd_ack(x_rd_ack),
        .xtra_wr_req(x_wr_req), .xtra_wr_addr(x_wr_addr), .xtra_wr_word(x_wr_word), .xtra_wr_ack(x_wr_ack),
        .part_trigger(save_req), .part_skip(4'd1), .part_started(part_started), .part_done(part_done)
    );

    reg [15:0] sd_flash [0:FLASH_WORDS-1];
    reg [15:0] sd_card  [0:CARD_WORDS-1];
    reg [15:0] savefile [0:FILE_WORDS-1];
    integer errors = 0, i, j, k;
    reg [26:0] ra_l; reg rc_l; reg [2:0] rd_dly; reg rd_p = 0;
    integer mem_req_cnt = 0;
    always @(posedge clk) begin
        mem_ready <= 1'b0;
        if (mem_req) begin mem_req_cnt = mem_req_cnt + 1; ra_l <= mem_addr; rc_l <= mem_card; rd_dly <= 2; rd_p <= 1; end
        else if (rd_p) begin
            if (rd_dly != 0) rd_dly <= rd_dly - 1;
            else begin
                for (j = 0; j < 8; j = j + 1) mem_q[j*16 +: 16] <= rc_l ? sd_card[ra_l + j] : sd_flash[ra_l + j];
                mem_ready <= 1'b1; rd_p <= 0;
            end
        end
    end
    reg [26:0] wa_l; reg wc_l; reg [15:0] wd_l; reg [2:0] w_dly; reg w_p = 0;
    always @(posedge clk) begin
        wr_ack <= 1'b0;
        if (wr_req) begin wa_l <= wr_addr; wc_l <= wr_card; wd_l <= wr_data; w_dly <= 2; w_p <= 1; end
        else if (w_p) begin
            if (w_dly != 0) w_dly <= w_dly - 1;
            else begin
                if (wc_l) sd_card[wa_l] <= wd_l; else sd_flash[wa_l] <= wd_l;
                wr_ack <= 1'b1; w_p <= 0;
            end
        end
    end
    integer sd_wr_cnt = 0, lba_min = 99, lba_max = 0;
    always @(posedge clk) if (sd_wr && !sd_ack) begin
        sd_wr_cnt = sd_wr_cnt + 1;
        if (sd_lba < lba_min) lba_min = sd_lba; if (sd_lba > lba_max) lba_max = sd_lba;
    end

    integer base, wa, rr;
    task svc_sd_write; begin
        base = sd_lba * WPB;
        @(negedge clk); sd_ack = 1; sd_buff_addr = 0; @(posedge clk);
        for (wa = 0; wa < WPB; wa = wa + 1) begin
            @(negedge clk); savefile[base + wa] = sd_buff_din;
            sd_buff_addr = (wa == WPB-1) ? wa[8:0] : (wa[8:0] + 9'd1);
            @(posedge clk);
        end
        @(negedge clk); sd_ack = 0; @(posedge clk);
    end endtask
    task svc_sd_read; begin
        base = sd_lba * WPB;
        @(negedge clk); sd_ack = 1;
        for (rr = 0; rr < WPB; rr = rr + 1) begin
            @(negedge clk); sd_buff_addr = rr[8:0]; sd_buff_dout = savefile[base + rr]; sd_buff_wr = 1;
            @(posedge clk); @(negedge clk); sd_buff_wr = 0;
        end
        @(negedge clk); sd_ack = 0; @(posedge clk);
    end endtask
    task do_save(input integer n); integer b; begin
        sd_wr_cnt = 0;
        @(negedge clk); save_trigger = 1; @(negedge clk); save_trigger = 0;
        for (b = 0; b < n; b = b + 1) begin @(posedge clk); while (!sd_wr) @(posedge clk); svc_sd_write; end
        while (busy) @(posedge clk); repeat (4) @(posedge clk);
    end endtask
    task do_erase(input integer n); integer b; begin
        sd_wr_cnt = 0;
        @(negedge clk); erase_trigger = 1; @(negedge clk); erase_trigger = 0;
        for (b = 0; b < n; b = b + 1) begin @(posedge clk); while (!sd_wr) @(posedge clk); svc_sd_write; end
        while (busy) @(posedge clk); repeat (4) @(posedge clk);
    end endtask
    task do_load(input integer n); integer b; begin
        load_blocks = n;
        fork
            begin @(negedge clk); load_arm = 1; @(posedge clk); while (!busy) @(posedge clk); load_arm = 0; end
            for (b = 0; b < n; b = b + 1) begin @(posedge clk); while (!sd_rd) @(posedge clk); svc_sd_read; end
        join
        while (busy) @(posedge clk); repeat (8) @(posedge clk);
    end endtask
    // service whatever partial save is running or requested, until the module is quiet
    task drain; begin
        while (busy || save_req) begin svc_partial(9); repeat (QUIET * 2) @(posedge clk); end
    end endtask
    // service a partial save that the module starts on its own (n blocks)
    task svc_partial(input integer n); integer b; begin
        sd_wr_cnt = 0; lba_min = 99; lba_max = 0; mem_req_cnt = 0;
        for (b = 0; b < n; b = b + 1) begin @(posedge clk); while (!sd_wr) @(posedge clk); svc_sd_write; end
        while (busy) @(posedge clk); repeat (4) @(posedge clk);
    end endtask

    // ---- game bus ----
    task gwr(input [12:0] a, input [7:0] d); begin
        @(negedge clk); addr = a; din = d; we = 1; nv_written = 1;
        @(negedge clk); we = 0; nv_written = 0;
    end endtask
    task grd(input [12:0] a, output [7:0] d); begin
        @(negedge clk); addr = a; repeat (2) @(posedge clk); #1; d = dout;
    end endtask
    task tload(input [12:0] a, input [7:0] d); begin
        @(negedge clk); T_we = 1; T_addr = a; T_data = d; @(negedge clk); T_we = 0;
    end endtask
    function [7:0] pat(input integer b); pat = (b * 7 + 3) & 8'hff; endfunction
    function [7:0] fbyte(input integer w0, input integer b); fbyte = savefile[w0 + b/2] >> (8 * (b % 2)); endfunction

    reg [7:0] rb; integer bad, h, t0; reg fired;
    // a game writing byte 4001 every 9 cycles while a partial save runs (test 6)
    reg hammer_on = 0;
    reg part_seen = 0;      // sticky: the saver began a partial save (test 7 samples slowly)
    always @(posedge clk) if (part_started) part_seen <= 1;
    always @(posedge hammer_on) begin
        for (h = 0; h < 400; h = h + 1) begin
            @(negedge clk); addr = 13'd4001; din = 8'h5A; we = 1; nv_written = 1;
            @(negedge clk); we = 0; nv_written = 0;
            repeat (7) @(posedge clk);
        end
        hammer_on = 0;
    end
    initial begin
        for (i = 0; i < FLASH_WORDS; i = i + 1) sd_flash[i] = 16'hF000 | i[11:0];
        for (i = 0; i < CARD_WORDS;  i = i + 1) sd_card[i]  = 16'hC000 | i[11:0];
        for (i = 0; i < FILE_WORDS;  i = i + 1) savefile[i] = 16'h0000;

        repeat (4) @(posedge clk);
        @(negedge clk); rst = 0; reset = 0; repeat (4) @(posedge clk);
        // the game fills its NVRAM and sets the clock (1998-11-27 Fri 12:34:56, stopped)
        for (k = 0; k < 8184; k = k + 1) gwr(k[12:0], pat(k));
        gwr(13'd8184, 8'h80);   // write freeze
        gwr(13'd8185, 8'hD6); gwr(13'd8186, 8'h34);   // STOP bit set: the clock holds gwr(13'd8187, 8'h12);
        gwr(13'd8188, 8'h06); gwr(13'd8189, 8'h27); gwr(13'd8190, 8'h11); gwr(13'd8191, 8'h98);
        gwr(13'd8184, 8'h00);
        // the writes above made it dirty: let the module's own partial save run and finish
        while (!save_req) @(posedge clk);
        svc_partial(9);

        // ---- 1. full SAVE ----
        do_save(FILE_BLOCKS);
        if (sd_wr_cnt != FILE_BLOCKS) begin $display("FAIL: SAVE wrote %0d blocks (expected %0d)", sd_wr_cnt, FILE_BLOCKS); errors = errors + 1; end
        bad = 0;
        for (k = 0; k < WPB; k = k + 1) if (savefile[XBASE + k] !== (16'hCA00 | k[7:0])) bad = bad + 1;
        if (bad != 0) begin $display("FAIL: cassette block (region block 0) wrong in %0d words", bad); errors = errors + 1; end
        bad = 0;
        for (k = 0; k < 8; k = k + 1) if (fbyte(TKBASE, k) !== ((64'h3537334E56544B50 >> (8*(7-k))) & 64'hff)) bad = bad + 1;
        if (fbyte(TKBASE, 8) !== 8'd1 || fbyte(TKBASE, 9) !== 8'd1 || fbyte(TKBASE, 10) !== 8'h00 || fbyte(TKBASE, 11) !== 8'h20) bad = bad + 1;
        for (k = 12; k < 1024; k = k + 1) if (fbyte(TKBASE, k) !== 8'd0) bad = bad + 1;
        if (bad != 0) begin $display("FAIL: timekeeper header block wrong (%0d)", bad); errors = errors + 1; end
        bad = 0;
        for (k = 0; k < 8184; k = k + 1) if (fbyte(IMGBASE, k) !== pat(k)) bad = bad + 1;
        if (bad != 0) begin $display("FAIL: image differs from the timekeeper in %0d bytes", bad); errors = errors + 1; end
        // clock bytes: ctrl 00, then the set time (ticking at 1 Hz = every clk here, so
        // only the date part is stable enough to check)
        if (fbyte(IMGBASE, 8184) !== 8'h00 || fbyte(IMGBASE, 8185) !== 8'hD6 || fbyte(IMGBASE, 8189) !== 8'h27 || fbyte(IMGBASE, 8190) !== 8'h11 || fbyte(IMGBASE, 8191) !== 8'h98) begin
            $display("FAIL: saved clock bytes %02h %02h %02h %02h", fbyte(IMGBASE, 8184), fbyte(IMGBASE, 8189), fbyte(IMGBASE, 8190), fbyte(IMGBASE, 8191)); errors = errors + 1; end
        bad = 0;
        for (i = 0; i < FLASH_WORDS; i = i + 1) if (savefile[i] !== (16'hF000 | i[11:0])) bad = bad + 1;
        for (i = 0; i < CARD_WORDS;  i = i + 1) if (savefile[FLASH_WORDS + i] !== (16'hC000 | i[11:0])) bad = bad + 1;
        if (bad != 0) begin $display("FAIL: flash/card half of the save disturbed (%0d)", bad); errors = errors + 1; end

        // ---- 2. power cycle: blank timekeeper ----
        @(negedge clk); rst = 1; reset = 1; repeat (4) @(posedge clk);
        for (k = 0; k < 8184; k = k + 1) tload(k[12:0], 8'h00);
        @(negedge clk); reset = 0; repeat (4) @(posedge clk);       // core still in reset (LOAD runs there)
        grd(13'd100, rb);
        if (rb !== 8'h00) begin $display("FAIL: setup -- timekeeper not blank (%02h)", rb); errors = errors + 1; end

        // ---- 3. LOAD restores the image ----
        n_we_cnt = 0; cass_wr_cnt = 0;
        do_load(FILE_BLOCKS);
        @(negedge clk); rst = 0; repeat (4) @(posedge clk);
        bad = 0;
        for (k = 0; k < 8184; k = k + 1) begin grd(k[12:0], rb); if (rb !== pat(k)) bad = bad + 1; end
        if (bad != 0) begin $display("FAIL: LOAD did not restore the timekeeper -- %0d of 8184 bytes differ (NOTE 605 on hardware)", bad); errors = errors + 1; end
        if (!restored) begin $display("FAIL: restored flag not set"); errors = errors + 1; end
        if (n_we_cnt != 8184) begin $display("FAIL: restore issued %0d load writes (expected 8184: clock bytes skipped)", n_we_cnt); errors = errors + 1; end
        if (cass_wr_cnt != WPB) begin $display("FAIL: cassette block got %0d words (expected %0d)", cass_wr_cnt, WPB); errors = errors + 1; end
        grd(13'd8191, rb);
        if (rb !== 8'h00) begin $display("FAIL: LOAD applied the saved clock year (%02h); the clock must come from the host", rb); errors = errors + 1; end
        if (save_req) begin $display("FAIL: a LOAD marked the timekeeper dirty"); errors = errors + 1; end

        // ---- 4. legacy 6-block file (no region) ----
        @(negedge clk); rst = 1; reset = 1; repeat (4) @(posedge clk);
        for (k = 0; k < 8184; k = k + 1) tload(k[12:0], 8'h00);
        @(negedge clk); reset = 0; repeat (4) @(posedge clk);
        n_we_cnt = 0;
        do_load(NUM_BLOCKS + CARD_BLOCKS + 1);
        if (n_we_cnt != 0 || restored) begin $display("FAIL: legacy load touched the timekeeper (%0d writes)", n_we_cnt); errors = errors + 1; end

        // ---- 5. blank region ----
        for (i = TKBASE; i < FILE_WORDS; i = i + 1) savefile[i] = 16'h0000;
        n_we_cnt = 0;
        do_load(FILE_BLOCKS);
        if (n_we_cnt != 0 || restored) begin $display("FAIL: a blank region was applied (%0d writes)", n_we_cnt); errors = errors + 1; end
        @(negedge clk); rst = 0; repeat (4) @(posedge clk);

        // ---- 6. partial save ----
        for (k = 0; k < 8184; k = k + 1) gwr(k[12:0], pat(k));    // (game re-initialises)
        for (i = XBASE; i < XBASE + WPB; i = i + 1) savefile[i] = 16'hBEEF;   // sentinel: must survive
        for (i = 0; i < FLASH_WORDS + CARD_WORDS; i = i + 1) savefile[i] = 16'h1234;
        // the module fires on its own once quiet
        while (!save_req) @(posedge clk);
        svc_partial(9);
        if (lba_min != 6 || lba_max != 14 || sd_wr_cnt != 9) begin $display("FAIL: partial save wrote LBAs %0d..%0d (%0d blocks), expected 6..14", lba_min, lba_max, sd_wr_cnt); errors = errors + 1; end
        if (mem_req_cnt != 0) begin $display("FAIL: partial save read SDRAM (%0d bursts)", mem_req_cnt); errors = errors + 1; end
        bad = 0;
        for (i = XBASE; i < XBASE + WPB; i = i + 1) if (savefile[i] !== 16'hBEEF) bad = bad + 1;
        for (i = 0; i < FLASH_WORDS + CARD_WORDS; i = i + 1) if (savefile[i] !== 16'h1234) bad = bad + 1;
        if (bad != 0) begin $display("FAIL: partial save touched %0d words outside the timekeeper region", bad); errors = errors + 1; end
        bad = 0;
        for (k = 0; k < 8184; k = k + 1) if (fbyte(IMGBASE, k) !== pat(k)) bad = bad + 1;
        if (bad != 0) begin $display("FAIL: partial save image wrong in %0d bytes", bad); errors = errors + 1; end
        if (save_done) begin $display("FAIL: partial save pulsed save_done (toast)"); errors = errors + 1; end
        // dirty cleared: no new request while idle
        repeat (QUIET * 2) @(posedge clk);
        if (save_req) begin $display("FAIL: save_req re-asserted with no new write"); errors = errors + 1; end
        // one changed byte -> another partial save carrying it; the game keeps writing
        // ANOTHER byte during the save (port steals -> retries)
        gwr(13'd4000, 8'hA5);
        while (!save_req) @(posedge clk);
        hammer_on = 1;
        svc_partial(9);
        while (hammer_on) @(posedge clk);
        if (fbyte(IMGBASE, 4000) !== 8'hA5) begin $display("FAIL: partial save missed the changed byte (%02h)", fbyte(IMGBASE, 4000)); errors = errors + 1; end
        bad = 0;
        for (k = 0; k < 8184; k = k + 1) if (k != 4000 && k != 4001 && fbyte(IMGBASE, k) !== pat(k)) bad = bad + 1;
        if (bad != 0) begin $display("FAIL: image torn by concurrent writes in %0d bytes", bad); errors = errors + 1; end
        if (fbyte(IMGBASE, 4001) !== 8'h5A && fbyte(IMGBASE, 4001) !== pat(4001)) begin $display("FAIL: byte written during the save is neither old nor new (%02h)", fbyte(IMGBASE, 4001)); errors = errors + 1; end
        // the writes during the save re-armed a later one (byte 4001 = 5A must reach the file)
        // (the writes were quiet for QUIET before the first save finished, so the
        // re-armed save may already be running -- service either way)
        while (!(busy || save_req)) @(posedge clk);
        svc_partial(9);
        if (fbyte(IMGBASE, 4001) !== 8'h5A) begin $display("FAIL: write racing the snapshot was lost (%02h)", fbyte(IMGBASE, 4001)); errors = errors + 1; end

        // ---- 7. never-quiet game: AGE path ----
        drain;
        begin : ager
            fired = 0; t0 = 0; part_seen = 0;
            for (h = 0; h < AGE / 100 + 50; h = h + 1) begin
                gwr(13'd10, h[7:0]);
                repeat (96) @(posedge clk);
                if (part_seen && !fired) begin fired = 1; t0 = h; end
            end
            if (!fired) begin $display("FAIL: a continuously written timekeeper never requested a save"); errors = errors + 1; end
            else if (t0 * 100 > AGE + 2500) begin $display("FAIL: AGE request came late (%0d cycles)", t0 * 100); errors = errors + 1; end
        end
        drain;

        // ---- 8. host clock ----
        @(negedge clk); rst = 1; repeat (4) @(posedge clk);
        @(negedge clk); set_valid = 1; set_data = {8'h26, 8'h09, 8'h28, 8'h02, 8'h13, 8'h05, 8'h30}; set_stb = 1;
        @(negedge clk); set_stb = 0;
        repeat (4) @(posedge clk);
        @(negedge clk); rst = 0; repeat (2) @(posedge clk);
        grd(13'd8191, rb); if (rb !== 8'h26) begin $display("FAIL: clock set during reset lost (year %02h)", rb); errors = errors + 1; end
        grd(13'd8188, rb); if (rb !== 8'h02) begin $display("FAIL: day-of-week %02h", rb); errors = errors + 1; end
        // first reading after reset re-syncs once
        @(negedge clk); set_data = {8'h26, 8'h09, 8'h28, 8'h02, 8'h13, 8'h06, 8'h00}; set_stb = 1; @(negedge clk); set_stb = 0;
        grd(13'd8186, rb); if (rb !== 8'h06) begin $display("FAIL: first post-reset set not applied (min %02h)", rb); errors = errors + 1; end
        // the game sets the clock; a later host reading must NOT override it
        gwr(13'd8184, 8'h80); gwr(13'd8187, 8'h20); gwr(13'd8184, 8'h00);
        @(negedge clk); set_data = {8'h26, 8'h09, 8'h28, 8'h02, 8'h13, 8'h07, 8'h00}; set_stb = 1; @(negedge clk); set_stb = 0;
        grd(13'd8187, rb); if (rb !== 8'h20) begin $display("FAIL: second host set overrode the game's clock (hour %02h)", rb); errors = errors + 1; end
        grd(13'd8186, rb); if (rb == 8'h07) begin $display("FAIL: second host set applied (min %02h)", rb); errors = errors + 1; end
        drain;

        // ---- 9. ERASE zeroes the region ----
        for (i = XBASE; i < FILE_WORDS; i = i + 1) savefile[i] = 16'h5555;
        do_erase(FILE_BLOCKS);
        bad = 0;
        for (i = XBASE; i < FILE_WORDS; i = i + 1) if (savefile[i] !== 16'h0000) bad = bad + 1;
        if (bad != 0) begin $display("FAIL: ERASE left %0d non-zero words in the extra blocks", bad); errors = errors + 1; end

        if (errors == 0) $display("RESULT: PASS (s573_tk_nv)");
        else             $display("RESULT: FAIL (s573_tk_nv, %0d errors)", errors);
        $finish;
    end
    initial begin #3_000_000_000; $display("RESULT: FAIL (s573_tk_nv, TIMEOUT)"); $finish; end
endmodule
