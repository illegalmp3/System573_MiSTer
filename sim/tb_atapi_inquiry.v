`timescale 1ns/1ps
// tb_atapi_inquiry.v -- the CR-589's INQUIRY, byte for byte, at three allocation
// lengths.
//
// dsfdr's install boot died with ERROR 184 / CD-ROM DRIVE ERROR, and the cause was
// decoded out of the game's own PSX.EXE rather than guessed at:
//
//   0x8031fad0  builds a 12-byte CDB, opcode 0x12, and stores 96 (0x60) in CDB[4]
//               AND as the expected transfer count, then issues the packet. A
//               negative return here is what the caller turns into 184.
//   0x8031483c  calls it, and `bgez v0` -> 0x8031484c `jal <show_error>` with
//               a0 = 184. So 184 fires BEFORE any byte of the response is examined:
//               it is a short transfer, not a content mismatch.
//   0x80314918  only then compares INQUIRY bytes 32..35 against a table of accepted
//               drive firmware revisions at 0x80340be4 -- exactly three entries,
//               "GS0N", "kona", "GSCA" -- which are the revisions it will UPGRADE
//               FROM; anything else makes it skip the drive-firmware flash. The
//               drive reports "gscb" (the post-update revision, see rtl/atapi.v)
//               precisely so the installer finds nothing to upgrade.
//
// atapi.v served a hardcoded 36 bytes and reported revision "1.0b", so it failed
// the first check and would have failed the second. Both are MAME's CR-589
// behaviour, and MAME is the reference these games actually run against:
// src/devices/bus/ata/cr589.cpp overrides the base t10mmc INQUIRY *specifically* to
// drop its `if (m_transfer_length > 36) m_transfer_length = 36;` clamp, and its
// nvram_default writes "MATSHITACD-ROM CR-589   GS0N" as bytes 8..35 (stock);
// we report the flashed identity "MATSHITACD-ROM CR-589   gscb".
//
// This bench pins all of it: the honoured allocation length at 96 (dsfdr), at 36
// (the BIOS POST path, so the three playable titles cannot regress) and at 0
// (which SPC defines as 256), the 28-byte identity, and that bytes past the 36-byte
// page read as zero the way the CR-589's memset leaves them.
module tb_atapi_inquiry;
    reg clk = 0, rst = 1;
    reg [23:0] exp1_addr = 0;
    reg [1:0]  exp1_reqsize = 2'b01;   // lh pass-through (these checks read full halfwords)
    reg [15:0] exp1_wdata = 0;
    reg        exp1_we = 0, exp1_re = 0;
    wire [15:0] exp1_rdata;

    reg [3:0]  dip_sw = 4'h7;          // SW4=0 -> Flash boot (as emu.sv)
    wire [1:0] coin_counter;
    wire audio_amp_en, audio_mute, spu_dac_en, wdog_reset, cdrom_irq;
    wire [31:0] lamp_out;
    integer errors = 0;

    system573_top #(.CLK_FREQ_HZ(1_000_000), .WDOG_TIMEOUT(100000)) dut (
        .clk(clk), .rst(rst), .card_en(1'b0), .card_slot1(1'b0),
        // the card reader Off (s573_wio): JVS bits read their legacy constants
        .wio_osd_en(1'b0), .wio_snac_en(1'b0), .wio_stb(1'b0), .wio_idx(10'd0), .wio_din(16'd0),
        .wio_dout(), .wio_user_out(), .wio_user_in(7'h7f),
        .exp1_addr(exp1_addr), .exp1_reqsize(exp1_reqsize), .exp1_wdata(exp1_wdata),
        .exp1_we(exp1_we), .exp1_re(exp1_re), .exp1_rdata(exp1_rdata),
        .dip_sw(dip_sw), .stage_mux_en(1'b0), .stage_trace_addr(7'd0), .stage_trace_data(), .stage_trace_count(), .p1_ctrl(8'h00), .p2_ctrl(8'h00),
        .coin_sw(2'b00), .service_btn(1'b0), .test_btn(1'b0),
        .pcmcia_present(2'b00),
        .cd_present(1'b1),
        .cd_image(1'b0), .cd_hps_req(), .cd_hps_lba(),
        .cd_hps_ack(1'b0), .cd_hps_write(1'b0), .cd_hps_data(16'h0000),
        .cd_ti_write(1'b0), .cd_ti_addr(9'd0), .cd_ti_data(32'd0),
        .cd_img_mounted(1'b0), .cd_img_size(64'd0),
        .atapi_dma_req(), .atapi_dma_rd(1'b0), .atapi_dma_dout(),
        .adc_ch0(8'h00), .adc_ch1(8'h00), .adc_ch2(8'h00), .adc_ch3(8'h00),
        .coin_counter(coin_counter), .audio_amp_en(audio_amp_en),
        .audio_mute(audio_mute), .spu_dac_en(spu_dac_en), .wdog_reset(wdog_reset),
        .cdrom_irq(cdrom_irq), .lamp_out(lamp_out),
        .dio_mp3_ready(1'b0),   // no MP3 streaming in this drive-check test
        .dio_dec_frame_sync(1'b0), .dio_dec_frame_idle(1'b0), .dio_pcm_sample_tick(1'b0),
        .flash_wait(), .flash_mem_req(), .flash_mem_addr(),
        .flash_mem_q(128'd0), .flash_mem_ready(1'b0),
        // DIO_SIM_BACKING defaults to 1: inline DIO RAM; dio_wait stays 0,
        // the DDR3 channels are unused.
        .dio_wait(), .dio_mem_rd_req(), .dio_mem_rd_addr(),
        .dio_mem_rd_q(64'd0), .dio_mem_rd_ack(1'b0),
        .dio_mem_wr_req(), .dio_mem_wr_addr(), .dio_mem_wr_data(),
        .dio_mem_wr_ack(1'b0), .dio_dbg_ovf(), .cfg_ddrsbm(1'b0), .chart_ofs_ms(5'd0),
        .nvram_we(1'b0), .nvram_addr(13'd0), .nvram_din(8'd0),
        .sec_cart_type(2'd0),
        .sec_eep_we(1'b0), .sec_eep_addr(10'd0), .sec_eep_din(8'd0),
        .sec_ser_we(1'b0), .sec_ser_addr(3'd0), .sec_ser_din(8'd0),
        // second (install) cassette + restore flag: not used by this bench
        .sec_eep_zs01_only(1'b0), .sec_inst_sel(1'b0), .sec_inst_type(1'b0), .sec_ieep_we(1'b0), .sec_ieep_addr(10'd0), .sec_ieep_din(8'd0), .sec_iser_we(1'b0), .sec_iser_addr(3'd0), .sec_iser_din(8'd0)
    );

    always #5 clk = ~clk;

    task exp1_write(input [23:0] a, input [15:0] d);
        begin
            @(negedge clk); exp1_addr = a; exp1_wdata = d; exp1_we = 1; exp1_re = 0;
            @(posedge clk);
            @(negedge clk); exp1_we = 0;
        end
    endtask
    task exp1_read(input [23:0] a, output [15:0] d);
        begin
            @(negedge clk); exp1_addr = a; exp1_reqsize = 2'b01; exp1_re = 0; exp1_we = 0;
            @(posedge clk);
            @(negedge clk); exp1_re = 1;
            @(posedge clk);
            @(negedge clk); exp1_re = 0;
            repeat (2) @(posedge clk);
            #1; d = exp1_rdata;
        end
    endtask
    task chk(input [15:0] got, input [15:0] exp, input [255:0] what);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %04h (expected %04h)", what, got, exp);
                errors = errors + 1;
            end else
                $display("  ok: %0s = %04h", what, got);
        end
    endtask

    // issue a PACKET (0xA0) command + 12-byte CDB (only CDB[0]=opcode matters to atapi.v)
    task packet_send(input [7:0] op);
        integer w; begin
            exp1_write(24'h48000e, 16'h00A0);          // PACKET command
            exp1_write(24'h480000, {8'h00, op});       // CDB word0 (opcode in low byte)
            for (w = 0; w < 5; w = w + 1) exp1_write(24'h480000, 16'h0000);
        end
    endtask

    // bounded BSY-clear poll, like the BIOS's 0xf690-loop status wait (trace pc
    // 0x803cb304): commands with a response-build window (READ TOC's metadata
    // lookup) legally show BSY for a few cycles before raising DRQ.
    task wait_not_busy(input [255:0] what);
        integer p; reg [15:0] s; begin
            s = 16'h0080;
            // budget covers the IDENTIFY fix's IDENT_SETTLE (2048 clk1x) BSY hold as well
            // as READ TOC's short metadata-lookup window (each exp1_read is several clk).
            for (p = 0; p < 4096 && (s & 16'h0080) !== 16'h0000; p = p + 1)
                exp1_read(24'h48000e, s);
            if ((s & 16'h0080) !== 16'h0000) begin
                $display("FAIL: BSY stuck (%0s)", what);
                errors = errors + 1;
            end
        end
    endtask

    // PACKET + 12-byte CDB with an allocation length in CDB[4].
    // CDB bytes go out two per word, little end first: word2 = {pkt[5], pkt[4]}.
    task packet_inquiry(input [7:0] alloc);
        integer w; begin
            exp1_write(24'h48000e, 16'h00A0);              // PACKET
            exp1_write(24'h480000, 16'h0012);              // pkt[1:0] = 00 12
            exp1_write(24'h480000, 16'h0000);              // pkt[3:2]
            exp1_write(24'h480000, {8'h00, alloc});        // pkt[5:4] -> pkt[4] = alloc
            for (w = 0; w < 3; w = w + 1) exp1_write(24'h480000, 16'h0000);
        end
    endtask

    reg [15:0] v;
    reg [7:0]  dbuf [0:255];
    integer i, want;
    reg [8:0] got_bc;
    reg       pad_bad;

    // read `n` bytes of the data phase into dbuf
    task drain(input integer n);
        integer k; reg [15:0] w; begin
            for (k = 0; k < n; k = k + 2) begin
                exp1_read(24'h480000, w);
                dbuf[k]   = w[7:0];
                dbuf[k+1] = w[15:8];
            end
        end
    endtask

    task expect_string(input integer at, input [255:0] str, input integer len,
                       input [255:0] what);
        integer k; reg [7:0] c; reg bad; begin
            bad = 0;
            for (k = 0; k < len; k = k + 1) begin
                c = str[8*(len-1-k) +: 8];
                if (dbuf[at+k] !== c) bad = 1;
            end
            if (bad) begin
                $write("FAIL: %0s at byte %0d = \"", what, at);
                for (k = 0; k < len; k = k + 1) $write("%c", dbuf[at+k]);
                $display("\"");
                errors = errors + 1;
            end else
                $display("  ok: %0s matches at byte %0d", what, at);
        end
    endtask

    task inquiry(input integer alloc, input integer expect_len, input [255:0] what);
        integer k; begin
            packet_inquiry(alloc[7:0]);
            wait_not_busy(what);
            // IDE reg N is at exp1 byte offset 2N (system573_top: atapi_addr = exp1_addr[3:1]),
            // as the 0x48000e status/command reads above already rely on. Byte count is
            // regs 4/5 -> offsets 0x08/0x0a. (Was 0x04/0x06 = IREASON / reg 3, which read a
            // constant 0x102 = 258 regardless of allocation.)
            exp1_read(24'h480008, v); got_bc[7:0] = v[7:0];   // reg 4: byte count low
            exp1_read(24'h48000a, v); got_bc[8]   = v[0];     // reg 5: byte count high, bit 0
            if (got_bc !== expect_len[8:0]) begin
                $display("FAIL: %0s: byte count = %0d, expected %0d", what, got_bc, expect_len);
                errors = errors + 1;
            end else
                $display("  ok: %0s: drive reports %0d bytes", what, got_bc);
            drain(expect_len);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);
        exp1_write(24'h560000, 16'h0000); repeat (4) @(posedge clk);
        exp1_write(24'h560000, 16'h0001); repeat (4) @(posedge clk);

        // ---- dsfdr's request: 96 bytes ----
        $display("tb_atapi_inquiry: INQUIRY alloc=96 (dsfdr PSX.EXE 0x8031fad0)");
        inquiry(96, 96, "alloc=96");
        expect_string(8,  "MATSHITA",         8,  "vendor id");
        expect_string(16, "CD-ROM CR-589   ", 16, "product id");
        expect_string(32, "gscb",             4,  "firmware revision");
        // the 24-byte concatenation the game memcmps at PSX.EXE 0x803148dc
        expect_string(8,  "MATSHITACD-ROM CR-589   ", 24, "vendor+product as the game compares it");
        pad_bad = 0;
        for (i = 36; i < 96; i = i + 1)
            if (dbuf[i] !== 8'h00 && !pad_bad) begin
                $display("FAIL: byte %0d = %02h, expected 00 past the 36-byte page", i, dbuf[i]);
                errors = errors + 1;
                pad_bad = 1;
            end
        if (!pad_bad) $display("  ok: bytes 36..95 are zero");

        // ---- the BIOS POST's request: 36 bytes. THE regression guard. ----
        $display("tb_atapi_inquiry: INQUIRY alloc=36 (BIOS POST -- must not change)");
        inquiry(36, 36, "alloc=36");
        expect_string(8, "MATSHITACD-ROM CR-589   ", 24, "identity at alloc=36");

        // ---- SPC: an allocation length of 0 means 256 ----
        $display("tb_atapi_inquiry: INQUIRY alloc=0 (SPC: means 256)");
        inquiry(0, 256, "alloc=0 -> 256");
        expect_string(32, "gscb", 4, "revision at alloc=256");

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d checks)", errors);
        $finish;
    end
endmodule
