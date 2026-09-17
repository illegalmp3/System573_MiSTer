`timescale 1ns/1ps
// =============================================================================
// tb_s573_cass_nv.v - ZS01 cassette NVRAM persistence through the slot-4 save
// (ddrextrm ERROR 175, 2026-09-16).
//
// REAL modules: s573_flash_saver (scaled 2 onboard + 3 card blocks), s573_cass_nv,
// s573_seccart -> zs01. The cassette is the real ddrusa .u1, and its state is changed
// by replaying the 13 golden wire vectors (tools/zs01_ref.py -- a MAME zs01.cpp
// transcription sharing no code with the RTL), three of which are WRITEs. The expected
// NVRAM after them is the model's (secdata/ddrusa_zs01_nv_after.hex), i.e. what MAME
// would write to its nvram file.
//
//   1. SAVE with the card fitted writes 2+3+1 blocks; block 5 is the cassette block:
//      magic/version/type/length header and the 140 post-write NVRAM bytes.
//   2. "Power cycle": reset, the .mgl re-loads the PRISTINE .u1 (dump != written state).
//   3. LOAD of the 6-block file restores the cassette to the written state, byte-exact.
//      RED under CASS_NV_NO_RESTORE.
//   4. Legacy 5-block file (no cassette block): the pristine .u1 stands, no load writes.
//   5. A blank (all-zero) cassette block: the pristine .u1 stands, no load writes.
//   6. ERASE writes the cassette block as zeros.
// =============================================================================
module tb_s573_cass_nv;
    localparam integer NUM_BLOCKS  = 2;
    localparam integer CARD_BLOCKS = 3;
    localparam integer WPB         = 512;
    localparam integer FLASH_WORDS = NUM_BLOCKS * WPB;
    localparam integer CARD_WORDS  = CARD_BLOCKS * WPB;
    localparam integer FILE_BLOCKS = NUM_BLOCKS + CARD_BLOCKS + 1;
    localparam integer FILE_WORDS  = FILE_BLOCKS * WPB;
    localparam integer XBASE       = (NUM_BLOCKS + CARD_BLOCKS) * WPB;   // word index of block 5

    reg clk = 0; always #5 clk = ~clk;
    reg reset = 1;          // saver reset
    reg crst  = 1;          // cassette/system reset

    // ---------------- cassette ----------------
    reg [7:0] dl  = 8'b0000_0100;
    reg       io0 = 1'b0;
    reg        T_we = 0; reg [12:0] T_addr = 0; reg [7:0] T_data = 0;   // tb .u1 loader
    reg        S_we = 0; reg [2:0]  S_addr = 0; reg [7:0] S_data = 0;
    wire [63:0] sec_dbg; wire sec_io0; wire [7:0] sec_in; wire sec_drdy, sec_irdy;
    wire [7:0] dump_addr, dump_data; wire nv_wr;
    wire       N_we; wire [12:0] N_addr; wire [7:0] N_data;
    integer    n_we_cnt = 0;
    always @(posedge clk) if (N_we) n_we_cnt = n_we_cnt + 1;
    // emu.sv mux: the .u1 download or the NV restore (never both at once)
    wire        L_we   = T_we | N_we;
    wire [12:0] L_addr = N_we ? N_addr : T_addr;
    wire [7:0]  L_data = N_we ? N_data : T_data;

    s573_seccart #(.DS_CLK_HZ(1_000_000)) cass (
        .clk(clk), .rst(crst), .cart_type(2'd2),
        .latch_we(1'b1), .d_latch(dl), .io0_dir(io0),
        .load_eep_we(L_we), .load_eep_addr(L_addr), .load_eep_data(L_data),
        .load_ser_we(S_we), .load_ser_addr(S_addr), .load_ser_data(S_data),
        .sec_dbg(sec_dbg), .sec_cs_n(), .sec_rst_line(), .sec_scl_line(),
        .sec_sda_line(), .sec_ds_line(), .sec_zs01_state(), .sec_rtr_edges(),
        .sec_in_rtr(), .sec_rtr_emit(),
        .sec_io0(sec_io0), .sec_in(sec_in), .sec_drdy(sec_drdy), .sec_irdy(sec_irdy),
        .zs01_dump_addr(dump_addr), .zs01_dump_data(dump_data), .zs01_nv_wr(nv_wr)
    );

    // ---------------- NV glue ----------------
    wire xtra_en, x_rd_req, x_rd_ack, x_wr_req, x_wr_ack, restored;
    wire [8:0] x_rd_addr, x_wr_addr; wire [15:0] x_rd_word, x_wr_word;
    reg  [7:0] tb_dump_addr = 0; reg tb_dump = 0;
    wire [7:0] nv_dump_addr;
    assign dump_addr = tb_dump ? tb_dump_addr : nv_dump_addr;
    s573_cass_nv nv (
        .clk(clk), .rst(crst), .cart_type(2'd2), .xtra_en(xtra_en),
        .xtra_rd_req(x_rd_req), .xtra_rd_addr(x_rd_addr), .xtra_rd_word(x_rd_word), .xtra_rd_ack(x_rd_ack),
        .xtra_wr_req(x_wr_req), .xtra_wr_addr(x_wr_addr), .xtra_wr_word(x_wr_word), .xtra_wr_ack(x_wr_ack),
        .dump_addr(nv_dump_addr), .dump_data(dump_data),
        .load_we(N_we), .load_addr(N_addr), .load_data(N_data), .restored(restored)
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
        .xtra_en(xtra_en), .xtra_rd_req(x_rd_req), .xtra_rd_addr(x_rd_addr), .xtra_rd_word(x_rd_word), .xtra_rd_ack(x_rd_ack),
        .xtra_wr_req(x_wr_req), .xtra_wr_addr(x_wr_addr), .xtra_wr_word(x_wr_word), .xtra_wr_ack(x_wr_ack)
    );

    // SDRAM models (two images)
    reg [15:0] sd_flash [0:FLASH_WORDS-1];
    reg [15:0] sd_card  [0:CARD_WORDS-1];
    reg [15:0] savefile [0:FILE_WORDS-1];
    integer errors = 0, i, j, k;
    reg [26:0] ra_l; reg rc_l; reg [2:0] rd_dly; reg rd_p = 0;
    always @(posedge clk) begin
        mem_ready <= 1'b0;
        if (mem_req) begin ra_l <= mem_addr; rc_l <= mem_card; rd_dly <= 2; rd_p <= 1; end
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
    integer sd_wr_cnt = 0;
    always @(posedge clk) if (sd_wr && !sd_ack) sd_wr_cnt = sd_wr_cnt + 1;

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

    // ---------------- ZS01 host driver (as tb_zs01_cmd) ----------------
    task tk; begin repeat (3) @(posedge clk); end endtask
    task sda(input v); begin io0 = ~v; tk; end endtask
    task scl(input v); begin dl[1] = v; tk; end endtask
    task i2c_start; begin scl(0); sda(1); scl(1); sda(0); scl(0); end endtask
    task send_byte(input [7:0] d); integer q; begin
        for (q = 7; q >= 0; q = q - 1) begin scl(0); sda(d[q]); scl(1); end
        scl(0); sda(1); scl(1); scl(0);
    end endtask
    task read_byte(output [7:0] d); integer q; begin
        d = 8'h00;
        for (q = 7; q >= 0; q = q - 1) begin scl(0); sda(1); scl(1); d[q] = sec_io0; end
        scl(0); sda(0); scl(1); scl(0); sda(1);
    end endtask

    reg [7:0] u1 [0:139]; reg [7:0] u6 [0:7]; reg [7:0] vec [0:1023]; reg [7:0] nvgold [0:139];
    reg [7:0] rb8; reg [7:0] resp [0:11];
    integer v, bad, fh;

    task load_u1; begin
        for (k = 0; k < 140; k = k + 1) begin @(negedge clk); T_we = 1; T_addr = k[12:0]; T_data = u1[k]; end
        @(negedge clk); T_we = 0;
        for (k = 0; k < 8; k = k + 1) begin @(negedge clk); S_we = 1; S_addr = k[2:0]; S_data = u6[k]; end
        @(negedge clk); S_we = 0;
    end endtask
    // compare the whole cassette NVRAM (via the dump port) with a 140-byte reference
    task dump_diff(input integer want_gold, output integer nbad); reg [7:0] w; begin
        nbad = 0; tb_dump = 1;
        for (k = 0; k < 140; k = k + 1) begin
            @(negedge clk); tb_dump_addr = k[7:0]; repeat (3) @(posedge clk); #1;
            w = want_gold ? nvgold[k] : u1[k];
            if (dump_data !== w) nbad = nbad + 1;
        end
        tb_dump = 0;
    end endtask
    function [7:0] fbyte(input integer b); fbyte = savefile[XBASE + b/2] >> (8 * (b % 2)); endfunction

    initial begin
        fh = $fopen("secdata/ddrusa_zs01_nv_after.hex", "r");
        if (fh == 0) begin $display("tb_s573_cass_nv: ddrusa fixtures absent -- SKIPPED"); $display("RESULT: PASS (s573_cass_nv)"); $finish; end
        $fclose(fh);
        $readmemh("secdata/ddrusa_u1.hex", u1, 0, 139);
        $readmemh("secdata/ddrusa_u6.hex", u6);
        $readmemh("secdata/ddrusa_zs01_vectors.hex", vec);
        $readmemh("secdata/ddrusa_zs01_nv_after.hex", nvgold);
        for (i = 0; i < FLASH_WORDS; i = i + 1) sd_flash[i] = 16'hF000 | i[11:0];
        for (i = 0; i < CARD_WORDS;  i = i + 1) sd_card[i]  = 16'hC000 | i[11:0];
        for (i = 0; i < FILE_WORDS;  i = i + 1) savefile[i] = 16'h0000;

        repeat (4) @(posedge clk);
        load_u1;
        @(negedge clk); crst = 0; reset = 0; repeat (4) @(posedge clk);

        // ---- change the cassette the way a game does: the golden wire vectors ----
        dl[2] = 1'b0; io0 = 1'b0; dl[1] = 1'b0; tk;
        for (v = 0; v < vec[0]; v = v + 1) begin
            i2c_start;
            for (k = 0; k < 12; k = k + 1) send_byte(vec[1 + 24*v + k]);
            repeat (1000) @(posedge clk);
            for (k = 0; k < 12; k = k + 1) read_byte(resp[k]);
        end
        dl[2] = 1'b1; tk;
        dump_diff(1, bad);
        if (bad != 0) begin $display("FAIL: setup -- cassette state after the vectors differs from the MAME model in %0d bytes", bad); errors = errors + 1; end

        // ---- 1. SAVE: 6 blocks, block 5 = header + written NVRAM ----
        do_save(FILE_BLOCKS);
        if (sd_wr_cnt != FILE_BLOCKS) begin $display("FAIL: SAVE wrote %0d blocks (expected %0d)", sd_wr_cnt, FILE_BLOCKS); errors = errors + 1; end
        bad = 0;
        for (k = 0; k < 8; k = k + 1) if (fbyte(k) !== ((64'h3537334E56434153 >> (8*(7-k))) & 64'hff)) bad = bad + 1;
        if (fbyte(8) !== 8'd1 || fbyte(9) !== 8'd2 || fbyte(10) !== 8'd140 || fbyte(11) !== 8'd0) bad = bad + 1;
        if (bad != 0) begin $display("FAIL: cassette block header wrong (%0d)", bad); errors = errors + 1; end
        bad = 0;
        for (k = 0; k < 140; k = k + 1) if (fbyte(16 + k) !== nvgold[k]) bad = bad + 1;
        if (bad != 0) begin $display("FAIL: cassette block image differs from the MAME NVRAM in %0d bytes", bad); errors = errors + 1; end
        bad = 0;
        for (k = 156; k < 1024; k = k + 1) if (fbyte(k) !== 8'd0) bad = bad + 1;
        if (bad != 0) begin $display("FAIL: %0d non-zero bytes past the cassette image", bad); errors = errors + 1; end
        for (i = 0; i < FLASH_WORDS; i = i + 1) if (savefile[i] !== (16'hF000 | i[11:0])) bad = bad + 1;
        for (i = 0; i < CARD_WORDS;  i = i + 1) if (savefile[FLASH_WORDS + i] !== (16'hC000 | i[11:0])) bad = bad + 1;
        if (bad != 0) begin $display("FAIL: flash/card half of the save disturbed (%0d)", bad); errors = errors + 1; end

        // ---- 2. power cycle: reset, pristine .u1 re-loaded ----
        @(negedge clk); crst = 1; reset = 1; repeat (4) @(posedge clk);
        load_u1;
        @(negedge clk); crst = 0; reset = 0; repeat (4) @(posedge clk);
        dump_diff(1, bad);
        if (bad == 0) begin $display("FAIL: setup -- the pristine .u1 equals the written state; the test cannot discriminate"); errors = errors + 1; end

        // ---- 3. LOAD the 6-block file: the cassette comes back ----
        n_we_cnt = 0;
        do_load(FILE_BLOCKS);
        dump_diff(1, bad);
        if (bad != 0) begin $display("FAIL: LOAD did not restore the cassette -- %0d of 140 bytes still differ (ERROR 175 on hardware)", bad); errors = errors + 1; end
        if (!restored) begin $display("FAIL: restored flag not set after a valid cassette block"); errors = errors + 1; end
        if (n_we_cnt != 140) begin $display("FAIL: restore issued %0d load writes (expected 140)", n_we_cnt); errors = errors + 1; end

        // ---- 4. legacy 5-block file: the .u1 stands ----
        @(negedge clk); crst = 1; reset = 1; repeat (4) @(posedge clk);
        load_u1;
        @(negedge clk); crst = 0; reset = 0; repeat (4) @(posedge clk);
        n_we_cnt = 0;
        do_load(FILE_BLOCKS - 1);
        dump_diff(0, bad);
        if (bad != 0 || n_we_cnt != 0) begin $display("FAIL: legacy load touched the cassette (%0d bytes, %0d writes)", bad, n_we_cnt); errors = errors + 1; end

        // ---- 5. blank cassette block: the .u1 stands ----
        for (i = XBASE; i < FILE_WORDS; i = i + 1) savefile[i] = 16'h0000;
        n_we_cnt = 0;
        do_load(FILE_BLOCKS);
        dump_diff(0, bad);
        if (bad != 0 || n_we_cnt != 0) begin $display("FAIL: a blank cassette block was applied (%0d bytes, %0d writes)", bad, n_we_cnt); errors = errors + 1; end

        // ---- 6. ERASE zeroes the cassette block ----
        for (i = XBASE; i < FILE_WORDS; i = i + 1) savefile[i] = 16'h5555;
        do_erase(FILE_BLOCKS);
        bad = 0;
        for (i = XBASE; i < FILE_WORDS; i = i + 1) if (savefile[i] !== 16'h0000) bad = bad + 1;
        if (bad != 0) begin $display("FAIL: ERASE left %0d non-zero words in the cassette block", bad); errors = errors + 1; end

        if (errors == 0) $display("RESULT: PASS (s573_cass_nv)");
        else             $display("RESULT: FAIL (s573_cass_nv, %0d errors)", errors);
        $finish;
    end
    initial begin #3_000_000_000; $display("RESULT: FAIL (s573_cass_nv, TIMEOUT)"); $finish; end
endmodule
