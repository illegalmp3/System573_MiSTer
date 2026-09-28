`timescale 1ns/1ps
// =============================================================================
// tb_s573_flash_saver_card.v - the TWO-IMAGE (onboard + PCMCIA card) split in
// s573_flash_saver.v.
//
// Tier 3 puts the 32 MB PCMCIA slot-2 card in the SAME slot-4 save file as the
// 16 MB onboard flash, because MiSTer Main parses at most SIX file/reset items
// per .mgl (mra_loader.h mgl_item_struct item[6]) and dsfdr_install.mgl already
// uses all six -- a seventh item for a separate card save is silently dropped.
// So one file: blocks [0, NUM_BLOCKS) = onboard, blocks
// [NUM_BLOCKS, NUM_BLOCKS+CARD_BLOCKS) = card, with mem_card / wr_card telling
// emu.sv which SDRAM base (FLASH_START vs CARD_START) to add.
//
// Scaled: NUM_BLOCKS=2 (1 KB blocks -> a 2-block "onboard" image) and
// CARD_BLOCKS=3. The block/burst/LBA geometry is identical at any size -- only
// the counts shrink, exactly as tb_s573_flash_saver does.
//
// Asserted here:
//   1. SAVE with card_en=1 writes NUM_BLOCKS+CARD_BLOCKS blocks, and the file is
//      byte-exact: the onboard image first, then the card image.
//   2. Every SDRAM read carries the right image bit AND a word address RE-BASED
//      to that image's word 0 (the off-by-NUM_BLOCKS*512 bug this split invites).
//   3. LOAD with load_blocks = the full file restores BOTH images byte-exact.
//   4. LEGACY LOAD: a 16 MB-equivalent file (load_blocks = NUM_BLOCKS) restores
//      the onboard image and leaves the card image COMPLETELY untouched -- an
//      existing Tier-1/2 .sav must not scribble garbage into the card region.
//   5. card_en=0 is bit-identical to the pre-card engine: exactly NUM_BLOCKS
//      blocks, and the card image bit is never asserted on any port.
// =============================================================================
module tb_s573_flash_saver_card;
    localparam integer NUM_BLOCKS    = 2;
    localparam integer CARD_BLOCKS   = 3;
    localparam integer WORDS_PER_BLK = 512;
    localparam integer FLASH_WORDS   = NUM_BLOCKS  * WORDS_PER_BLK;   // 1024
    localparam integer CARD_WORDS    = CARD_BLOCKS * WORDS_PER_BLK;   // 1536
    localparam integer FILE_WORDS    = FLASH_WORDS + CARD_WORDS;      // 2560
    localparam integer AUTOSAVE_THRESH = 1000000;   // never self-fires here

    reg clk = 0, reset = 1;
    always #5 clk = ~clk;

    reg  save_trigger = 0;
    reg  load_arm     = 0;
    reg  card_en      = 0;
    reg [31:0] load_blocks = 0;
    wire busy, saving, save_done, erase_done, auto_saved;

    wire        sd_rd, sd_wr;
    wire [31:0] sd_lba;
    reg         sd_ack       = 0;
    reg         sd_buff_wr   = 0;
    reg  [8:0]  sd_buff_addr = 0;
    reg  [15:0] sd_buff_dout = 0;
    wire [15:0] sd_buff_din;

    wire        mem_req;
    wire [26:0] mem_addr;
    wire        mem_card;
    reg  [127:0] mem_q     = 0;
    reg         mem_ready  = 0;

    wire        wr_req, wr_busy;
    wire [26:0] wr_addr;
    wire        wr_card;
    wire [15:0] wr_data;
    reg         wr_ack = 0;

    // TWO separate SDRAM images: emu.sv adds FLASH_START for card=0 and
    // CARD_START for card=1, so they are physically disjoint stores.
    reg [15:0] sd_flash [0:FLASH_WORDS-1];
    reg [15:0] sd_card  [0:CARD_WORDS-1];
    reg [15:0] ref_flash[0:FLASH_WORDS-1];
    reg [15:0] ref_card [0:CARD_WORDS-1];
    reg [15:0] savefile [0:FILE_WORDS-1];

    integer errors = 0;
    integer i, j;
    integer sd_wr_cnt = 0;
    integer bad_card_bit = 0;    // a card-image access while card_en=0

    always @(posedge clk) if (sd_wr && !sd_ack) sd_wr_cnt = sd_wr_cnt + 1;
    always @(posedge clk) begin
        if (!card_en && ((mem_req && mem_card) || (wr_req && wr_card)))
            bad_card_bit = bad_card_bit + 1;
    end

    s573_flash_saver #(.NUM_BLOCKS(NUM_BLOCKS), .CARD_BLOCKS(CARD_BLOCKS),
                       .AUTOSAVE_THRESH(AUTOSAVE_THRESH)) dut (
        .clk(clk), .reset(reset),
        .save_trigger(save_trigger), .erase_trigger(1'b0),
        .flash_wr_ack(1'b0), .autosave_en(1'b0), .auto_saved(auto_saved),
        .load_arm(load_arm), .card_en(card_en), .load_blocks(load_blocks),
        .busy(busy), .saving(saving),
        .save_done(save_done), .erase_done(erase_done),
        .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_lba(sd_lba), .sd_ack(sd_ack),
        .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr),
        .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_card(mem_card),
        .mem_q(mem_q), .mem_ready(mem_ready),
        .wr_req(wr_req), .wr_busy(wr_busy), .wr_addr(wr_addr),
        .wr_card(wr_card), .wr_data(wr_data), .wr_ack(wr_ack),
        .xtra_blocks(4'd0), .xtra_rd_req(), .xtra_rd_addr(), .xtra_rd_word(16'd0), .xtra_rd_ack(1'b0),
        .xtra_wr_req(), .xtra_wr_addr(), .xtra_wr_word(), .xtra_wr_ack(1'b0),
        .part_trigger(1'b0), .part_skip(4'd0), .part_started(), .part_done()
    );

    // ---- SDRAM ch4 burst-read model (image-aware, bounds-checked) ------------
    reg [26:0] rd_addr_l = 0;
    reg        rd_card_l = 0;
    reg [2:0]  rd_dly = 0;
    reg        rd_pending = 0;
    always @(posedge clk) begin
        mem_ready <= 1'b0;
        if (mem_req) begin
            rd_addr_l <= mem_addr; rd_card_l <= mem_card;
            rd_dly <= 3'd2; rd_pending <= 1'b1;
            // a re-basing bug shows up here as an out-of-range word index
            if (mem_card && mem_addr >= CARD_WORDS) begin
                $display("FAIL: card read out of range: addr=%0d (card image is %0d words)",
                         mem_addr, CARD_WORDS);
                errors = errors + 1;
            end
            if (!mem_card && mem_addr >= FLASH_WORDS) begin
                $display("FAIL: onboard read out of range: addr=%0d (onboard image is %0d words)",
                         mem_addr, FLASH_WORDS);
                errors = errors + 1;
            end
        end else if (rd_pending) begin
            if (rd_dly != 0) rd_dly <= rd_dly - 3'd1;
            else begin
                for (j = 0; j < 8; j = j + 1)
                    mem_q[j*16 +: 16] <= rd_card_l ? sd_card[rd_addr_l + j]
                                                   : sd_flash[rd_addr_l + j];
                mem_ready  <= 1'b1;
                rd_pending <= 1'b0;
            end
        end
    end

    // ---- SDRAM ch3 word-write model (image-aware, bounds-checked) ------------
    reg [26:0] w_addr_l = 0;
    reg        w_card_l = 0;
    reg [15:0] w_data_l = 0;
    reg [2:0]  w_dly = 0;
    reg        w_pending = 0;
    always @(posedge clk) begin
        wr_ack <= 1'b0;
        if (wr_req) begin
            w_addr_l <= wr_addr; w_card_l <= wr_card; w_data_l <= wr_data;
            w_dly <= 3'd2; w_pending <= 1'b1;
            if (wr_card && wr_addr >= CARD_WORDS) begin
                $display("FAIL: card write out of range: addr=%0d", wr_addr);
                errors = errors + 1;
            end
            if (!wr_card && wr_addr >= FLASH_WORDS) begin
                $display("FAIL: onboard write out of range: addr=%0d", wr_addr);
                errors = errors + 1;
            end
        end else if (w_pending) begin
            if (w_dly != 0) w_dly <= w_dly - 3'd1;
            else begin
                if (w_card_l) sd_card[w_addr_l]  <= w_data_l;
                else          sd_flash[w_addr_l] <= w_data_l;
                wr_ack    <= 1'b1;
                w_pending <= 1'b0;
            end
        end
    end

    // ---- Main/hps_io SD block servicers (as tb_s573_flash_saver) ------------
    integer base, wa, ra;
    task svc_sd_write;
        begin
            base = sd_lba * WORDS_PER_BLK;
            @(negedge clk); sd_ack = 1;
            sd_buff_addr = 0;
            @(posedge clk);
            for (wa = 0; wa < WORDS_PER_BLK; wa = wa + 1) begin
                @(negedge clk);
                savefile[base + wa] = sd_buff_din;
                sd_buff_addr = (wa == WORDS_PER_BLK-1) ? wa[8:0] : (wa[8:0] + 9'd1);
                @(posedge clk);
            end
            @(negedge clk); sd_ack = 0;
            @(posedge clk);
        end
    endtask
    task svc_sd_read;
        begin
            base = sd_lba * WORDS_PER_BLK;
            @(negedge clk); sd_ack = 1;
            for (ra = 0; ra < WORDS_PER_BLK; ra = ra + 1) begin
                @(negedge clk);
                sd_buff_addr = ra[8:0];
                sd_buff_dout = savefile[base + ra];
                sd_buff_wr   = 1;
                @(posedge clk);
                @(negedge clk); sd_buff_wr = 0;
            end
            @(negedge clk); sd_ack = 0;
            @(posedge clk);
        end
    endtask
    task run_save_service(input integer nblocks);
        integer b;
        begin
            for (b = 0; b < nblocks; b = b + 1) begin
                @(posedge clk);
                while (!sd_wr) @(posedge clk);
                svc_sd_write;
            end
        end
    endtask
    task run_load_service(input integer nblocks);
        integer b;
        begin
            for (b = 0; b < nblocks; b = b + 1) begin
                @(posedge clk);
                while (!sd_rd) @(posedge clk);
                svc_sd_read;
            end
        end
    endtask

    task do_save(input integer nblocks);
        begin
            @(negedge clk); save_trigger = 1; @(negedge clk); save_trigger = 0;
            fork
                run_save_service(nblocks);
            join
            while (busy) @(posedge clk);
            repeat (4) @(posedge clk);
        end
    endtask

    // A LOAD during which the mounted image CHANGES SIZE partway through -- which
    // is the normal case on hardware, not an edge case: Main mounts
    // config/<core>.s4 at core init (user_io_init -> parse_config, before
    // mgl_parse) and the .mgl then mounts the real .sav, so img_mounted[4] pulses
    // twice and emu re-latches flash_save_size between them. `shrink_to` is the
    // second mount's block count; the transfer already in flight must still
    // terminate on the count it STARTED with.
    task do_load_remount(input integer nblocks, input integer shrink_to);
        begin
            load_blocks = nblocks;
            fork
                begin
                    @(negedge clk); load_arm = 1;
                    @(posedge clk);
                    while (!busy) @(posedge clk);
                    load_arm = 0;
                    // let the transfer get past the new (smaller) terminal count,
                    // then move it under the FSM's feet
                    while (sd_lba < shrink_to + 1) @(posedge clk);
                    load_blocks = shrink_to;
                end
                run_load_service(nblocks);
            join
            while (busy) @(posedge clk);
            repeat (4) @(posedge clk);
        end
    endtask

    task do_load(input integer nblocks);
        begin
            load_blocks = nblocks;
            fork
                begin
                    @(negedge clk); load_arm = 1;
                    @(posedge clk);
                    while (!busy) @(posedge clk);
                    load_arm = 0;
                end
                run_load_service(nblocks);
            join
            while (busy) @(posedge clk);
            repeat (4) @(posedge clk);
        end
    endtask

    integer diffs;
    initial begin
        // distinct, position-dependent patterns per image
        for (i = 0; i < FLASH_WORDS; i = i + 1) begin
            ref_flash[i] = 16'hF000 | i[11:0];
            sd_flash[i]  = ref_flash[i];
        end
        for (i = 0; i < CARD_WORDS; i = i + 1) begin
            ref_card[i] = 16'hC000 | i[11:0];
            sd_card[i]  = ref_card[i];
        end
        for (i = 0; i < FILE_WORDS; i = i + 1) savefile[i] = 16'h0000;

        repeat (4) @(posedge clk); @(negedge clk); reset = 0; @(negedge clk);

        // ---- 1/2) SAVE with the card fitted: 5 blocks, both images, re-based --
        card_en     = 1;
        load_blocks = NUM_BLOCKS + CARD_BLOCKS;
        sd_wr_cnt   = 0;
        do_save(NUM_BLOCKS + CARD_BLOCKS);
        if (sd_wr_cnt != NUM_BLOCKS + CARD_BLOCKS) begin
            $display("FAIL: SAVE wrote %0d blocks (expected %0d)",
                     sd_wr_cnt, NUM_BLOCKS + CARD_BLOCKS);
            errors = errors + 1;
        end
        diffs = 0;
        for (i = 0; i < FLASH_WORDS; i = i + 1)
            if (savefile[i] !== ref_flash[i]) diffs = diffs + 1;
        if (diffs != 0) begin
            $display("FAIL: onboard half of the .sav differs in %0d words", diffs);
            errors = errors + 1;
        end
        diffs = 0;
        for (i = 0; i < CARD_WORDS; i = i + 1)
            if (savefile[FLASH_WORDS + i] !== ref_card[i]) diffs = diffs + 1;
        if (diffs != 0) begin
            $display("FAIL: card half of the .sav differs in %0d words", diffs);
            errors = errors + 1;
        end

        // ---- 3) full LOAD restores BOTH images --------------------------------
        for (i = 0; i < FLASH_WORDS; i = i + 1) sd_flash[i] = 16'h0000;
        for (i = 0; i < CARD_WORDS;  i = i + 1) sd_card[i]  = 16'h0000;
        do_load(NUM_BLOCKS + CARD_BLOCKS);
        diffs = 0;
        for (i = 0; i < FLASH_WORDS; i = i + 1)
            if (sd_flash[i] !== ref_flash[i]) diffs = diffs + 1;
        for (i = 0; i < CARD_WORDS; i = i + 1)
            if (sd_card[i] !== ref_card[i]) diffs = diffs + 1;
        if (diffs != 0) begin
            $display("FAIL: full LOAD round-trip differs in %0d words", diffs);
            errors = errors + 1;
        end

        // ---- 4) LEGACY LOAD: a short (onboard-only) file leaves the card alone -
        for (i = 0; i < FLASH_WORDS; i = i + 1) sd_flash[i] = 16'h0000;
        for (i = 0; i < CARD_WORDS;  i = i + 1) sd_card[i]  = 16'hDEAD;   // sentinel
        do_load(NUM_BLOCKS);
        diffs = 0;
        for (i = 0; i < FLASH_WORDS; i = i + 1)
            if (sd_flash[i] !== ref_flash[i]) diffs = diffs + 1;
        if (diffs != 0) begin
            $display("FAIL: legacy LOAD did not restore the onboard image (%0d words)", diffs);
            errors = errors + 1;
        end
        diffs = 0;
        for (i = 0; i < CARD_WORDS; i = i + 1)
            if (sd_card[i] !== 16'hDEAD) diffs = diffs + 1;
        if (diffs != 0) begin
            $display("FAIL: legacy LOAD scribbled %0d words into the card image", diffs);
            errors = errors + 1;
        end

        // ---- 5) card_en=0 is the pre-card engine, exactly ---------------------
        for (i = 0; i < FLASH_WORDS; i = i + 1) sd_flash[i] = ref_flash[i];
        for (i = 0; i < FILE_WORDS;  i = i + 1) savefile[i] = 16'h0000;
        card_en      = 0;
        bad_card_bit = 0;
        sd_wr_cnt    = 0;
        do_save(NUM_BLOCKS);
        if (sd_wr_cnt != NUM_BLOCKS) begin
            $display("FAIL: card_en=0 SAVE wrote %0d blocks (expected %0d)",
                     sd_wr_cnt, NUM_BLOCKS);
            errors = errors + 1;
        end
        if (bad_card_bit != 0) begin
            $display("FAIL: card image bit asserted %0d times with card_en=0", bad_card_bit);
            errors = errors + 1;
        end
        diffs = 0;
        for (i = 0; i < FLASH_WORDS; i = i + 1)
            if (savefile[i] !== ref_flash[i]) diffs = diffs + 1;
        if (diffs != 0) begin
            $display("FAIL: card_en=0 SAVE differs in %0d words", diffs);
            errors = errors + 1;
        end
        // ... and nothing past the onboard image was written
        diffs = 0;
        for (i = FLASH_WORDS; i < FILE_WORDS; i = i + 1)
            if (savefile[i] !== 16'h0000) diffs = diffs + 1;
        if (diffs != 0) begin
            $display("FAIL: card_en=0 SAVE wrote %0d words past the onboard image", diffs);
            errors = errors + 1;
        end

        // ---- 6) a second mount mid-LOAD must not hang the transfer -------------
        // THE ddrusa/dsfdr BOOT REGRESSION (2026-09-14). The terminal block count
        // was a live wire off img_size; a second img_mounted[4] pulse moved it
        // below block_cnt, the `==` test never matched, the FSM walked 2^32 blocks
        // with `busy` high, and emu ORs `busy` into the CPU reset hold -- the core
        // loaded and the CPU never left reset. Latching the count at start fixes
        // it; `>=` means even a wrong latch ends early instead of hanging.
        card_en = 1;
        // Re-seed the FILE with a full 5-block image first. Test 5 deliberately
        // left it holding a 2-block card_en=0 save with zeros past it, so without
        // this the load would faithfully restore those zeros and the check would
        // fail for a reason that has nothing to do with the terminal count.
        for (i = 0; i < FLASH_WORDS; i = i + 1) savefile[i] = ref_flash[i];
        for (i = 0; i < CARD_WORDS;  i = i + 1) savefile[FLASH_WORDS + i] = ref_card[i];
        for (i = 0; i < FLASH_WORDS; i = i + 1) sd_flash[i] = 16'h0000;
        for (i = 0; i < CARD_WORDS;  i = i + 1) sd_card[i]  = 16'h0000;
        do_load_remount(NUM_BLOCKS + CARD_BLOCKS, 1);
        diffs = 0;
        for (i = 0; i < FLASH_WORDS; i = i + 1)
            if (sd_flash[i] !== ref_flash[i]) diffs = diffs + 1;
        for (i = 0; i < CARD_WORDS; i = i + 1)
            if (sd_card[i] !== ref_card[i]) diffs = diffs + 1;
        if (diffs != 0) begin
            $display("FAIL: LOAD with a mid-transfer re-mount restored %0d words wrong", diffs);
            errors = errors + 1;
        end
        if (busy !== 1'b0) begin
            $display("FAIL: saver still busy after a mid-transfer re-mount -- this is the hang");
            errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS (s573_flash_saver_card)");
        else             $display("RESULT: FAIL (s573_flash_saver_card, %0d errors)", errors);
        $finish;
    end

    // global timeout so a stalled FSM fails rather than hangs
    initial begin
        #50_000_000;
        $display("RESULT: FAIL (s573_flash_saver_card, TIMEOUT)");
        $finish;
    end
endmodule
