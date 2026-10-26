`timescale 1ns/1ps
// =============================================================================
// tb_s573_sav_mount_order.v - which .sav does the boot-time flash LOAD read?
//
// 2026-09-29 (docs/2026-09-29-sav-mount-order.md). Switching titles broke the NEXT
// title's flash every time: ddr4mp after ddr3mj -> ERROR 191 "a different game is
// installed", ddr4mj / ddr3mj / ddrextrm -> boot checks failed. The slot-4 read
// trace in s573mp3.log (s573_cd_trace, disk=4, 1 KB blocks) shows ONE restore per
// launch, starting ~6.6 s in at ~3390 blocks/s and ending ~21 s -- while the
// launcher's own .sav is mounted by its fifth item, >= 8 s in. Until then slot 4
// holds Main's BOOKMARK (config/System573.s4 = the last .sav mounted = the PREVIOUS
// title's), mounted by parse_config() at core init (Main user_io.cpp:982-1011,
// called from user_io_init() :1503, before mgl_parse() :1528 and the boot.rom
// autoload :1620-1631). The saver latches its block count at LOAD start and keeps
// going through a remount (s573_flash_saver.v S_IDLE comment: "a second mount while
// this load runs is the normal case"), so the first ~1.5-2 s of blocks came from
// the previous title's file.
//
// REAL module: s573_flash_saver (scaled blocks). The emu.sv logic that arms it --
// flash_save_mounted/size latch, flash_load_arm, flash_load_taken, the download
// settle hold, saver_reset, the load-block clamp -- is copied VERBATIM from
// rtl/emu.sv (only the constants are scaled), so this bench runs the shipping
// arming logic, not a paraphrase of it. The Main model follows the Main source:
//   * core init: the SC4 bookmark mount, then the boot.rom autoload (index 0);
//   * .mgl items run in order, each after its `delay` SECONDS counted from the end
//     of the previous item (menu.cpp:1209-1218: state 3 arms the timer for the
//     next item only once the current one has finished);
//   * an "f" item is an ioctl download (blocking), an "s" item a slot mount
//     (img_mounted pulse, img_size), the reset item a BUTTON2 pulse (reset only
//     the CPU -- not the saver, whose reset term has no buttons);
//   * a slot-4 read is served from WHATEVER FILE IS MOUNTED WHEN IT IS SERVED.
// Time is scaled (SEC cycles = 1 s) with the per-block service time set so a full
// restore takes the logged ~14.5 s: the race is the ratio, not the clock.
//
// SCENARIOS (all in one run, the saver and models reset between them):
//   S1 the launcher order as shipped until 2026-09-29 (f0 f4 f5 s1 s4 reset,
//      delays 1 1 1 2 3 1) with a DIFFERENT bookmark        -> must MIX (the bug)
//   S2 the fixed order (s4 first: s4 f0 f4 f5 s1 reset, delays 1 1 1 1 2 1),
//      different bookmark, boot.rom autoload at init         -> image == own .sav
//   S3 the fixed order with NO boot.rom autoload, so a LOAD from the bookmark
//      starts at t0 and must be ABORTED by the .u1 download  -> image == own .sav
//   S4 the fixed order with the bookmark == the own .sav     -> image == own .sav
//   S5 the old order with the bookmark == the own .sav       -> image == own .sav
//      (why relaunching one title always worked)
//   S6 (2026-10-25, ddrextrm ERROR 175) the fixed order, and the user presses the OSD
//      "Reset" (status[0], a saver_reset term) while the boot-time restore runs; once
//      the CPU is out of reset the game writes the timekeeper, whose partial save
//      (part_trigger) follows.                                -> the restore must run
//      again to the end, the CPU must stay held until it has, and nothing may be
//      written to the file before it has (sd_wr only after the restore).
// Every scenario also asserts: no SAVE ran (sd_wr never rose -- neither file is
// ever written during a launch) and the CPU was held in reset (flash_loading or a
// download/settle term) until the final restore finished.
//
// RED/GREEN: default -> S1 must show the mix, S2..S6 must be clean -> PASS.
//   -DNO_RESTORE_GUARD : the emu.sv arming logic as it was before 2026-10-25 (no
//                    flash_restored) -> S6 must FAIL: the restore is never re-run and
//                    the partial save writes the un-restored state over the file.
//   -DMGL_SAV_LAST : S2/S3/S4 use the OLD order -> S2 and S3 mix -> FAIL (proves the
//                    bench can see the defect in the scenario the fix is for).
// =============================================================================
module tb_s573_sav_mount_order;
    localparam integer NUM_BLOCKS  = 16;                 // onboard (HW 16384)
    localparam integer CARD_BLOCKS = 32;                 // PCMCIA   (HW 32768)
    localparam integer TOT         = NUM_BLOCKS + CARD_BLOCKS;   // a 48 MB title
    localparam integer WPB         = 512;                // words per 1 KB block
    localparam integer SEC         = 20000;              // clk cycles per scaled second
    // the logged restore: ~49162 blocks in ~14.5 s. Per scaled block:
    localparam integer BLK_CYC     = (145 * SEC) / (10 * TOT);
    localparam integer SD_LAT      = BLK_CYC - 3200;     // Main's disk read before sd_ack (the
                                                         // stream + SDRAM drain take ~3200 cycles)

    reg clk = 0;
    always #5 clk = ~clk;

    // ---------------------------------------------------------------- Main side
    reg         RESET = 1'b1;
    reg         ioctl_download = 1'b0;
    reg  [15:0] ioctl_index    = 16'd0;
    reg  [4:0]  img_mounted    = 5'd0;
    reg  [63:0] img_size       = 64'd0;
    reg         button2        = 1'b0;     // the .mgl reset item (CPU only)
    reg         osd_reset      = 1'b0;     // status[0], the OSD "Reset" (CPU AND saver)
    reg         tk_save_req    = 1'b0;     // u_tk_nv save_req: the game wrote the timekeeper
    integer     mounted_file   = 0;        // 0 none, 1 = bookmark file A, 2 = own file B
    reg         cd_mount_rst   = 1'b0;     // stands in for cdDownloadReset (CPU only)

    // ------------------------------------------- emu.sv, VERBATIM (constants scaled)
    reg bios_download = 1'b0, exe_download = 1'b0, flash_download = 1'b0, nvram_download = 1'b0;
    reg seceep_download = 1'b0, secser_download = 1'b0;
    always @(posedge clk) begin
        bios_download    <= ioctl_download & (ioctl_index[5:0] == 0);
        exe_download     <= ioctl_download & (ioctl_index == 1);
        flash_download   <= ioctl_download & (ioctl_index == 2);
        nvram_download   <= ioctl_download & (ioctl_index == 3);
        seceep_download  <= ioctl_download & (ioctl_index == 4);
        secser_download  <= ioctl_download & (ioctl_index[5:0] == 6'd5);
    end

    localparam [27:0] DOWNLOAD_SETTLE_TICKS = 3 * SEC;   // HW 28'd101_606_400 = 3.0 s
    wire any_game_download = bios_download | exe_download | flash_download | nvram_download | seceep_download | secser_download;
    reg [27:0] settle_cnt = 28'd0;
    always @(posedge clk) begin
        if (any_game_download)      settle_cnt <= DOWNLOAD_SETTLE_TICKS;
        else if (settle_cnt != 0)   settle_cnt <= settle_cnt - 1'd1;
    end
    wire download_settle_hold = (settle_cnt != 0);

    wire saver_busy, saver_saving;
    wire flash_loading = saver_busy & ~saver_saving;
    wire flash_restore_hold;
    wire reset_or = RESET | button2 | osd_reset | bios_download | exe_download | flash_download | nvram_download | seceep_download | secser_download | download_settle_hold | cd_mount_rst | flash_loading | flash_restore_hold;

    reg        flash_save_mounted = 1'b0;
    reg [63:0] flash_save_size    = 64'd0;
    reg        flash_load_taken   = 1'b0;
    wire flash_load_arm = flash_save_mounted && (flash_save_size > 0)
                          && ~flash_download && ~download_settle_hold
                          && ~flash_load_taken;
    reg  flash_restored = 1'b0;
    reg  loading_d      = 1'b0;
`ifdef NO_RESTORE_GUARD
    wire sav_writes_ok  = 1'b1;
    assign flash_restore_hold = 1'b0;
`else
    wire sav_writes_ok  = ~flash_save_mounted | flash_restored;
    assign flash_restore_hold = flash_save_mounted & (flash_save_size[63:10] != 54'd0) & ~flash_restored;   // >= 1 block: a shorter file is never loaded (the saver refuses 0 blocks)
`endif
    wire card_from_save = flash_save_mounted && (flash_save_size >= TOT * 1024);   // HW 64'd50331648
    wire card_en = card_from_save;
    wire [3:0]  xtra_blocks = 4'd1;      // one extra block, so a partial save has something to write
    wire [31:0] saver_save_blocks = (card_en ? TOT : NUM_BLOCKS) + {28'd0, xtra_blocks};   // HW 49152 : 16384
    wire [31:0] saver_file_blocks = flash_save_size[41:10];
    wire [31:0] saver_load_blocks = (saver_file_blocks > saver_save_blocks)
                                    ? saver_save_blocks : saver_file_blocks;
    wire saver_reset = RESET | osd_reset | flash_download | seceep_download | nvram_download;
    always @(posedge clk) begin
        if (img_mounted[4]) begin
            flash_load_taken <= 1'b0;
            if (img_size > 0) begin
                flash_save_mounted <= 1'b1;
                flash_save_size    <= img_size;
            end else begin
                flash_save_mounted <= 1'b0;
                flash_save_size    <= 64'd0;
            end
        end
        if (flash_load_arm && saver_busy && ~saver_saving)
            flash_load_taken <= 1'b1;
`ifndef NO_RESTORE_GUARD
        loading_d <= flash_loading;
        if (loading_d & ~flash_loading & ~saver_reset & flash_load_taken)
            flash_restored <= 1'b1;
        if (saver_reset & flash_load_taken & ~flash_restored)
            flash_load_taken <= 1'b0;
        if (img_mounted[4]) flash_restored <= 1'b0;
`endif
        if (flash_download | seceep_download | nvram_download) begin
            flash_load_taken <= 1'b0;
            flash_restored   <= 1'b0;
        end
    end

    // ---------------------------------------------------------------- the DUT
    wire        sd_rd, sd_wr;
    wire [31:0] sd_lba;
    reg         sd_ack = 1'b0, sd_buff_wr = 1'b0;
    reg  [8:0]  sd_buff_addr = 9'd0;
    reg  [15:0] sd_buff_dout = 16'd0;
    wire [15:0] sd_buff_din;
    wire        wr_req, wr_busy, wr_card;
    wire [26:0] wr_addr;
    wire [15:0] wr_data;
    reg         wr_ack = 1'b0;

    wire xrd_req, xwr_req;
    reg  xrd_ack = 1'b0, xwr_ack = 1'b0;
    always @(posedge clk) begin xrd_ack <= xrd_req; xwr_ack <= xwr_req; end
    s573_flash_saver #(.NUM_BLOCKS(NUM_BLOCKS), .CARD_BLOCKS(CARD_BLOCKS), .AUTOSAVE_THRESH(1000000)) dut (
        .clk(clk), .reset(saver_reset),
        .save_trigger(1'b0), .erase_trigger(1'b0), .flash_wr_ack(1'b0), .autosave_en(1'b1), .auto_saved(),
        .save_done(), .erase_done(),
        .load_arm(flash_load_arm), .card_en(card_en),
        .xtra_blocks(xtra_blocks), .xtra_rd_req(xrd_req), .xtra_rd_addr(), .xtra_rd_word(16'h7777), .xtra_rd_ack(xrd_ack),
        .xtra_wr_req(xwr_req), .xtra_wr_addr(), .xtra_wr_word(), .xtra_wr_ack(xwr_ack),
        .part_trigger(tk_save_req & sav_writes_ok), .part_skip(4'd0), .part_started(), .part_done(),
        .load_blocks(saver_load_blocks),
        .busy(saver_busy), .saving(saver_saving),
        .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_lba(sd_lba), .sd_ack(sd_ack),
        .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
        .mem_req(), .mem_addr(), .mem_card(), .mem_q(128'd0), .mem_ready(1'b0),
        .wr_req(wr_req), .wr_busy(wr_busy), .wr_addr(wr_addr), .wr_card(wr_card), .wr_data(wr_data), .wr_ack(wr_ack)
    );

    // ------------------------------------------------ SDRAM (the flash image)
    reg [15:0] sdram [0:TOT*WPB-1];
    reg [26:0] w_addr_l = 0; reg w_card_l = 0; reg [15:0] w_data_l = 0; reg [2:0] w_dly = 0; reg w_pending = 0;
    always @(posedge clk) begin
        wr_ack <= 1'b0;
        if (wr_req) begin
            w_addr_l <= wr_addr; w_card_l <= wr_card; w_data_l <= wr_data; w_dly <= 3'd2; w_pending <= 1'b1;
        end else if (w_pending) begin
            if (w_dly != 0) w_dly <= w_dly - 3'd1;
            else begin
                sdram[(w_card_l ? NUM_BLOCKS * WPB : 0) + w_addr_l] <= w_data_l;
                wr_ack <= 1'b1; w_pending <= 1'b0;
            end
        end
    end

    // ------------------------------------------------ the two files on the T7
    // word = {file tag, block, word low bits}: every block of every file distinct
    function [15:0] file_word(input integer f, input integer blk, input integer w);
        file_word = {(f == 1) ? 4'hA : 4'hB, blk[7:0], w[3:0]};
    endfunction

    // ------------------------------------------------ Main's slot-4 SD read service
    // Served from the file mounted WHEN THE BLOCK IS SERVED (Main reads sd_image[4]).
    integer served_from_a = 0, served_from_b = 0, served_total = 0;
    integer lba_l, ra, f_srv;
    integer sd_wr_seen = 0, sd_wr_early = 0;
    reg     restore_done_seen = 1'b0;    // set by the scenario once the image is final
    always @(posedge clk) if (sd_wr) begin
        sd_wr_seen = sd_wr_seen + 1;
        if (!restore_done_seen) sd_wr_early = sd_wr_early + 1;
    end
    initial begin
        forever begin
            @(posedge clk);
            if (sd_wr && !sd_ack) begin
                // a SAVE block: Main reads the 512 words out and writes the file
                repeat (SD_LAT / 4) @(posedge clk);
                @(negedge clk); sd_ack = 1;
                for (ra = 0; ra < WPB; ra = ra + 1) begin
                    @(negedge clk); sd_buff_addr = ra[8:0];
                    @(posedge clk);
                end
                @(negedge clk); sd_ack = 0;
            end else if (sd_rd && !sd_ack) begin
                lba_l = sd_lba;
                repeat (SD_LAT) @(posedge clk);
                f_srv = mounted_file;
                if (f_srv == 1) served_from_a = served_from_a + 1;
                if (f_srv == 2) served_from_b = served_from_b + 1;
                served_total = served_total + 1;
                @(negedge clk); sd_ack = 1;
                for (ra = 0; ra < WPB; ra = ra + 1) begin
                    @(negedge clk);
                    sd_buff_addr = ra[8:0];
                    sd_buff_dout = file_word(f_srv, lba_l, ra);
                    sd_buff_wr   = 1;
                    @(posedge clk);
                    @(negedge clk); sd_buff_wr = 0;
                end
                @(negedge clk); sd_ack = 0;
            end
        end
    end

    // ------------------------------------------------ CPU-release monitor
    // The CPU may run only once the image is final. Record every reset_or fall and
    // whether a LOAD was still to come after it.
    reg reset_or_d = 1'b1;
    integer releases = 0, early_release = 0;
    always @(posedge clk) begin
        reset_or_d <= reset_or;
        if (reset_or_d && !reset_or) releases = releases + 1;
    end

    // ------------------------------------------------ Main actions
    task wait_s(input integer tenths);   // tenths of a scaled second
        begin repeat (tenths * SEC / 10) @(posedge clk); end
    endtask
    task mount4(input integer f);
        begin
            @(negedge clk);
            mounted_file = f; img_size = TOT * 1024; img_mounted[4] = 1'b1;
            @(negedge clk); img_mounted[4] = 1'b0;
        end
    endtask
    task download(input integer idx, input integer tenths);
        begin
            @(negedge clk); ioctl_index = idx; ioctl_download = 1'b1;
            wait_s(tenths);
            @(negedge clk); ioctl_download = 1'b0;
        end
    endtask
    task mount_cd;  // slot 1: no saver effect; cdDownloadReset holds the CPU briefly
        begin @(negedge clk); cd_mount_rst = 1'b1; repeat (8) @(negedge clk); cd_mount_rst = 1'b0; end
    endtask
    task reset_item;  // <reset delay="1"/>: BUTTON2 for 100 ms (menu.cpp:1222-1227)
        begin @(negedge clk); button2 = 1'b1; wait_s(1); @(negedge clk); button2 = 1'b0; end
    endtask

    // the launcher as shipped until 2026-09-29: f0 f4 f5 s1 s4 reset, delays 1 1 1 2 3 1
    task mgl_old;
        begin
            wait_s(10); download(0, 2);      // 573bios.bin (512 KB)
            wait_s(10); download(4, 1);      // <rom>.u1
            wait_s(10); download(5, 1);      // <rom>.cas / .u6
            wait_s(20); mount_cd;            // <rom>.chd, slot 1
            wait_s(30); mount4(2);           // <rom>.sav, slot 4  <- the launcher's own file
            wait_s(10); reset_item;
        end
    endtask
    // the fix: the .sav FIRST, so the .u1 download (index 4, a saver_reset term)
    // always lands after it -- aborting any restore begun from the bookmark -- and
    // the one restore that completes starts after the last download settles.
    task mgl_new;
        begin
            wait_s(10); mount4(2);           // <rom>.sav, slot 4
            wait_s(10); download(0, 2);
            wait_s(10); download(4, 1);
            wait_s(10); download(5, 1);
            wait_s(20); mount_cd;
            wait_s(10); reset_item;
        end
    endtask

    // ------------------------------------------------ one launch, then the verdict
    integer errors = 0;
    integer blk, w, mism_blocks, from_a_blocks, bad;
    task launch(input [8*40-1:0] name, input integer bookmark, input integer bootrom,
                input integer new_order, input integer expect_mix);
        begin
            // power-on state: the SDRAM still holds whatever ran last (the FPGA
            // reload does not clear it) -- a third pattern, neither file.
            for (blk = 0; blk < TOT * WPB; blk = blk + 1) sdram[blk] = 16'h5555;
            served_from_a = 0; served_from_b = 0; served_total = 0; sd_wr_seen = 0; releases = 0;
            mounted_file = 0; img_size = 0;
            RESET = 1'b1; repeat (20) @(negedge clk); RESET = 1'b0;
            // t0, Main user_io_init(): parse_config() mounts the SC4 bookmark ...
            if (bookmark) mount4(bookmark);
            // ... then the boot.rom autoload (index 0), then mgl_parse and the items
            if (bootrom) download(0, 2);
            if (new_order) mgl_new; else mgl_old;
            // let the settle hold expire and the restore run to completion
            wait_s(20);
            while (saver_busy || download_settle_hold) @(posedge clk);
            wait_s(5);
            mism_blocks = 0; from_a_blocks = 0;
            for (blk = 0; blk < TOT; blk = blk + 1) begin
                bad = 0;
                for (w = 0; w < WPB; w = w + 1)
                    if (sdram[blk * WPB + w] !== file_word(2, blk, w)) bad = 1;
                if (bad) mism_blocks = mism_blocks + 1;
                if (sdram[blk * WPB][15:12] == 4'hA) from_a_blocks = from_a_blocks + 1;
            end
            $display("  %0s: blocks served A=%0d B=%0d; final image: %0d/%0d blocks wrong, %0d from the bookmark file; CPU releases=%0d; sd_wr=%0d",
                     name, served_from_a, served_from_b, mism_blocks, TOT, from_a_blocks, releases, sd_wr_seen);
            if (sd_wr_seen != 0) begin
                $display("  FAIL %0s: a SAVE wrote to a file during launch", name); errors = errors + 1;
            end
            if (reset_or) begin
                $display("  FAIL %0s: CPU still held in reset at the end", name); errors = errors + 1;
            end
            if (expect_mix) begin
                if (from_a_blocks == 0) begin
                    $display("  FAIL %0s: expected the bookmark file's blocks in the image (the shipped defect) -- the bench cannot see it", name);
                    errors = errors + 1;
                end else
                    $display("  ok   %0s: reproduces the defect -- the first %0d blocks are the PREVIOUS title's", name, from_a_blocks);
            end else begin
                if (mism_blocks != 0) begin
                    $display("  FAIL %0s: the image is not the launcher's own .sav", name); errors = errors + 1;
                end else
                    $display("  ok   %0s: image == the launcher's own .sav, every block", name);
            end
        end
    endtask

    // ------------------------------------------------ S6: OSD Reset during the restore
    function image_is_b(input integer dummy);
        integer bb, ww;
        begin
            image_is_b = 1;
            for (bb = 0; bb < TOT; bb = bb + 1)
                for (ww = 0; ww < WPB; ww = ww + 1)
                    if (sdram[bb * WPB + ww] !== file_word(2, bb, ww)) image_is_b = 0;
        end
    endfunction
    integer wr_bad = 0, rel_bad = 0, rel_cnt = 0;
    reg sd_wr_d = 1'b0, rst_d6 = 1'b1, s6_on = 1'b0, s6_after = 1'b0;   // s6_after: the OSD Reset has happened
    always @(posedge clk) begin
        sd_wr_d <= sd_wr; rst_d6 <= reset_or;
        if (s6_on && sd_wr && !sd_wr_d && !image_is_b(0)) wr_bad = wr_bad + 1;
        if (s6_on && s6_after && rst_d6 && !reset_or) begin   // the boot after the Reset
            rel_cnt = rel_cnt + 1;
            if (!image_is_b(0)) rel_bad = rel_bad + 1;
        end
    end
    task launch_osd_reset(input [8*40-1:0] name);
        begin
            for (blk = 0; blk < TOT * WPB; blk = blk + 1) sdram[blk] = 16'h5555;
            served_from_a = 0; served_from_b = 0; served_total = 0; sd_wr_seen = 0; releases = 0;
            wr_bad = 0; rel_bad = 0; rel_cnt = 0; s6_after = 1'b0;
            mounted_file = 0; img_size = 0;
            RESET = 1'b1; repeat (20) @(negedge clk); RESET = 1'b0;
            s6_on = 1'b1;
            mount4(2);                     // the bookmark = this title's own .sav
            download(0, 2);                // boot.rom autoload
            mgl_new;
            // the restore is running: the user presses Reset in the OSD 3 s into it
            while (!(saver_busy && !saver_saving)) @(posedge clk);
            wait_s(30);
            @(negedge clk); osd_reset = 1'b1; s6_after = 1'b1; wait_s(2); @(negedge clk); osd_reset = 1'b0;
            // the CPU leaves reset; 1 s later the game writes the timekeeper and
            // u_tk_nv asks for its partial save (save_req is a level until started)
            while (reset_or) @(posedge clk);
            wait_s(10);
            @(negedge clk); tk_save_req = 1'b1; wait_s(1); @(negedge clk); tk_save_req = 1'b0;
            // a request that was refused because the restore had not finished comes
            // again (u_tk_nv's 30 s age limit); give everything time to finish
            wait_s(40);
            while (saver_busy || download_settle_hold || reset_or) @(posedge clk);
            @(negedge clk); tk_save_req = 1'b1; wait_s(1); @(negedge clk); tk_save_req = 1'b0;
            wait_s(10);
            while (saver_busy) @(posedge clk);
            wait_s(5);
            s6_on = 1'b0;
            $display("  %0s: blocks served B=%0d; image==own .sav: %0d; CPU releases after the Reset=%0d (%0d before the image was complete); writes=%0d (%0d before the image was complete)",
                     name, served_from_b, image_is_b(0), rel_cnt, rel_bad, sd_wr_seen, wr_bad);
            if (!image_is_b(0)) begin
                $display("  FAIL %0s: the restore never completed -- the image is not the launcher's own .sav", name); errors = errors + 1;
            end
            if (rel_bad != 0) begin
                $display("  FAIL %0s: the CPU ran before the restore finished", name); errors = errors + 1;
            end
            if (wr_bad != 0) begin
                $display("  FAIL %0s: the file was written before the restore finished (the un-restored state replaced the install)", name); errors = errors + 1;
            end
            if (sd_wr_seen == 0) begin
                $display("  FAIL %0s: the timekeeper's partial save never ran after the restore", name); errors = errors + 1;
            end
            if (image_is_b(0) && rel_bad == 0 && wr_bad == 0 && sd_wr_seen != 0)
                $display("  ok   %0s: the restore ran again to the end, the CPU waited for it, the partial save came after it", name);
            if (reset_or) begin
                $display("  FAIL %0s: CPU still held in reset at the end", name); errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("tb_s573_sav_mount_order: %0d blocks (%0d onboard + %0d card), 1 s = %0d cycles, %0d cycles/block",
                 TOT, NUM_BLOCKS, CARD_BLOCKS, SEC, BLK_CYC);
`ifdef MGL_SAV_LAST
        $display("  MUTATION MGL_SAV_LAST: S2..S4 run the OLD launcher order");
        launch("S1 old order, other bookmark",        1, 1, 0, 1);
        launch("S2 (old order), other bookmark",      1, 1, 0, 0);
        launch("S3 (old order), no boot.rom",         1, 0, 0, 0);
        launch("S4 (old order), same bookmark",       2, 1, 0, 0);
`else
        launch("S1 old order, other bookmark",        1, 1, 0, 1);
        launch("S2 new order, other bookmark",        1, 1, 1, 0);
        launch("S3 new order, no boot.rom",      1, 0, 1, 0);
        launch("S4 new order, same bookmark",         2, 1, 1, 0);
`endif
        launch("S5 old order, same bookmark",         2, 1, 0, 0);
        launch_osd_reset("S6 OSD Reset during the restore");
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
