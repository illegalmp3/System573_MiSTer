`timescale 1ns/1ps
// tb_k573dio_cpld -- Digital I/O XC9536 CPLD FPGA-configuration port, through the
// real k573dio register bus (0x1f6400f0-0x1f6400ff).
//
// Replays, write for write, the two upload drivers we have source for:
//  * spicyjpeg/573in1 src/common/io.cpp loadDigitalIORawBitstream():
//      0xf4 = 0; 0xf6 = 0x8000, 0xc000, 0xf000; wait 5 ms;
//      require (0xf6 & 0x3000) == 0x1000; _writeBitstreamMSB/LSB to 0xf8 bit 15;
//      wait 50 ms; require (0xf6 & 0x3000) == 0x3000.
//  * Konami (psx-spx "0x1f6400f6"): the same three control writes, then the
//    41337-byte image "LSB first" -- each stored byte sent bit 0 first.
// and checks the board ID bits (0xf6 & 0xc000) == 0x8000 that 573in1
// isDigitalIOPresent() and ddrsbm test, plus the 0xf0-0xfe read mirror.
//
// Stream fixture: sim/fpgadata/fpga_573in1_raw.hex (gen_fpgadata.sh, from 573in1's
// data/fpga.bit). Without it the 573in1-file cases are skipped and the synthetic
// stream (same header: 0xff, preamble 0010, 24-bit length 330689) stands in.
//
// RED before rtl/k573dio_cpld.v: 0xf6 was MAME's constant 0xB000, so 573in1's
// pre-upload check (DONE must be 0) failed and it logged "bitstream upload failed".
module tb_k573dio_cpld;
    reg        clk = 0, rst = 1;
    reg        sel = 0, we = 0, re = 0;
    reg [7:0]  off = 0;
    reg [15:0] din = 0;
    wire [15:0] dout;
    integer errors = 0;

    k573dio #(.RAM_WORDS(4096), .DS_SERIAL(48'hABCD_EF12_3456), .DS_CLK_HZ(1_000_000)) dut (
        .clk(clk), .rst(rst), .sel(sel), .off(off), .we(we), .re(re),
        .din(din), .dout(dout), .lamp(),
        .dio_wait(), .dac_en(), .cfg_ddrsbm(1'b0),
        .mem_rd_req(), .mem_rd_addr(), .mem_rd_q(64'd0), .mem_rd_ack(1'b0),
        .mem_wr_req(), .mem_wr_addr(), .mem_wr_data(), .mem_wr_ack(1'b0),
        .dbg_wfifo_ovf(), .dbg_dio_hi_write(), .dbg_wfifo_state(), .dbg_ram_adr(),
        .crypto_key1(), .crypto_key2(), .crypto_key3(),
        .mp3_start(), .mp3_end(), .fpga_ctrl(), .network_id(),
        .cfg_epoch(), .mp3_cur_pos(),
        .gain_ll(), .gain_rr(), .gain_stb(),
        .mp3_out_ready(1'b0), .mp3_out_byte(), .mp3_out_valid(),
        .dec_frame_sync(1'b0), .dec_frame_idle(1'b0), .pcm_sample_tick(1'b0),
        .chart_ofs_ms(5'd0)
    );

    always #5 clk = ~clk;

    task wr(input [7:0] a, input [15:0] d);        // one-cycle bus write
        begin @(negedge clk); sel=1; we=1; off=a; din=d; @(negedge clk); sel=0; we=0; end
    endtask
    task rd(input [7:0] a, output [15:0] d);
        begin @(negedge clk); sel=1; re=1; off=a; #1 d=dout; @(negedge clk); sel=0; re=0; end
    endtask
    task chk(input [15:0] got, input [15:0] exp, input [8*48-1:0] what);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %04h (expected %04h)", what, got, exp);
                errors = errors + 1;
            end else $display("  ok  %0s = %04h", what, got);
        end
    endtask

    localparam integer NBYTES = 41337;
    localparam integer LENCNT = 330689;      // 573in1 fpga.bit length count
    reg [7:0] img [0:NBYTES-1];
    reg [7:0] syn [0:NBYTES-1];
    integer   have_file, fd, i, k, nb;
    reg [15:0] v;
    reg [7:0]  b;
    reg [23:0] len_f;

    // 573in1 reset sequence (loadDigitalIORawBitstream), status after its 5 ms wait
    task reset_seq_573in1; begin
        wr(8'hf4, 16'h0000);
        wr(8'hf6, 16'h8000); wr(8'hf6, 16'hc000); wr(8'hf6, 16'hf000);
        repeat (200) @(posedge clk);       // 5 ms in the real driver; >> INIT_CLKS
    end endtask

    // Stream a byte image; msb=1: _writeBitstreamMSB, msb=0: _writeBitstreamLSB.
    // src: 0 = file image, 1 = synthetic. Checks status at the length-count edge.
    task stream(input integer src, input integer msb, input [8*48-1:0] what);
        integer n, bit_i; reg [7:0] by; reg [15:0] s;
        begin
            n = 0;
            for (i = 0; i < NBYTES; i = i + 1) begin
                by = (src == 0) ? img[i] : syn[i];
                if (!msb) by = {by[0],by[1],by[2],by[3],by[4],by[5],by[6],by[7]};  // stored LSB-first
                for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin
                    if (msb) wr(8'hf8, {by[7 - bit_i], 15'd0});
                    else     wr(8'hf8, {by[bit_i],     15'd0});
                    n = n + 1;
                    if (n == LENCNT - 1) begin
                        rd(8'hf6, s);
                        if ((s & 16'h3000) !== 16'h1000) begin
                            $display("FAIL: %0s: DONE early at bit %0d (%04h)", what, n, s);
                            errors = errors + 1;
                        end
                    end
                    if (n == LENCNT) begin
                        rd(8'hf6, s);
                        if ((s & 16'h3000) !== 16'h3000) begin
                            $display("FAIL: %0s: no DONE at length count %0d (%04h)", what, n, s);
                            errors = errors + 1;
                        end else $display("  ok  %0s: DONE rises at bit %0d", what, n);
                    end
                end
            end
            repeat (50) @(posedge clk);    // 50 ms in the real driver
        end
    endtask

    initial begin
        // ---- fixtures ----
        fd = $fopen("fpgadata/fpga_573in1_raw.hex", "r");
        have_file = (fd != 0);
        if (have_file) begin $fclose(fd); $readmemh("fpgadata/fpga_573in1_raw.hex", img); end
        // synthetic: 0xff, then 0010 + 24-bit length (MSB first), then 1s
        len_f = LENCNT;
        syn[0] = 8'hff;
        syn[1] = {4'b0010, len_f[23:20]};
        syn[2] = len_f[19:12];
        syn[3] = len_f[11:4];
        syn[4] = {len_f[3:0], 4'hf};
        for (i = 5; i < NBYTES; i = i + 1) syn[i] = 8'hff;
        if (have_file) begin
            // the real file's header must parse to the length we assert against
            $display("  fixture: 573in1 fpga.bit raw, first bytes %02h %02h %02h %02h %02h",
                     img[0], img[1], img[2], img[3], img[4]);
            if ({img[1][3:0], img[2], img[3], img[4][7:4]} !== LENCNT[23:0] || img[1][7:4] !== 4'b0010) begin
                $display("FAIL: fixture header does not carry preamble 0010 + length %0d", LENCNT);
                errors = errors + 1;
            end
        end else $display("  NOTE: no fpgadata fixture -- 573in1-file cases skipped");

        repeat (4) @(posedge clk); @(negedge clk); rst = 0;
        repeat (100) @(posedge clk);

        // ---- power-on: unconfigured FPGA, board ID bits ----
        rd(8'hf6, v); chk(v, 16'h9000, "power-on status (ID, /INIT=1, DONE=0)");
        if ((v & 16'hc000) !== 16'h8000) begin $display("FAIL: isDigitalIOPresent"); errors = errors + 1; end
        for (k = 8'hf0; k <= 8'hfe; k = k + 2) begin
            rd(k[7:0], v);
            if (v !== 16'h9000) begin $display("FAIL: mirror %02h = %04h", k, v); errors = errors + 1; end
        end
        $display("  ok  0xf0-0xfe all mirror 0xf6");

        // ---- control steps (psx-spx: 0x8000, 0xc000, 0xf000) ----
        wr(8'hf6, 16'h8000); rd(8'hf6, v); chk(v, 16'h8000, "after 0x8000 (/PROGRAM low)");
        wr(8'hf6, 16'hc000); repeat (200) @(posedge clk);
        rd(8'hf6, v); chk(v, 16'h8000, "after 0xc000 (CPLD holds /INIT low)");
        wr(8'hf6, 16'hf000); rd(8'hf6, v);
        chk(v, 16'h9000, "after 0xf000 (clear already elapsed)");

        // ---- case 1: 573in1, real file, MSB-first ----
        if (have_file) begin
            reset_seq_573in1;
            rd(8'hf6, v); chk(v & 16'h3000, 16'h1000, "573in1 pre-upload (/INIT=1, DONE=0)");
            stream(0, 1, "573in1 fpga.bit MSB");
            rd(8'hf6, v); chk(v, 16'hB000, "573in1 post-upload");
        end

        // ---- case 2: Konami-style LSB-first image of the same stream ----
        reset_seq_573in1;
        rd(8'hf6, v); chk(v, 16'h9000, "re-program clears DONE");
        stream(have_file ? 0 : 1, 0, "LSB-first image");
        rd(8'hf6, v); chk(v, 16'hB000, "LSB-first post-upload (MAME's 0xB000)");

        // ---- case 3: synthetic header, MSB-first ----
        reset_seq_573in1;
        stream(1, 1, "synthetic MSB");
        rd(8'hf6, v); chk(v, 16'hB000, "synthetic post-upload");

        // ---- case 4: no preamble -> DONE at 330,696 bits (psx-spx length) ----
        reset_seq_573in1;
        for (nb = 1; nb <= 330696; nb = nb + 1) begin
            wr(8'hf8, 16'h8000);
            if (nb == 330695) begin rd(8'hf6, v); chk(v & 16'h3000, 16'h1000, "no-preamble: bit 330695"); end
        end
        rd(8'hf6, v); chk(v & 16'h3000, 16'h3000, "no-preamble: DONE at 330696");

        // ---- case 5: CPLD holding DONE low after configuration ----
        wr(8'hf6, 16'hd000); rd(8'hf6, v); chk(v, 16'h9000, "0xd000: DONE line held low");
        wr(8'hf6, 16'hf000); rd(8'hf6, v); chk(v, 16'hB000, "0xf000: DONE released");

        // ---- case 6: back-to-back control writes, poll /INIT (Konami timing unknown) ----
        wr(8'hf6, 16'h8000); wr(8'hf6, 16'hc000); wr(8'hf6, 16'hf000);
        k = 0; rd(8'hf6, v);
        while ((v & 16'h1000) == 0 && k < 1000) begin k = k + 1; rd(8'hf6, v); end
        $display("  info: /INIT high %0d status reads after 0xf000 (MAME: immediately)", k);
        if (k >= 1000) begin $display("FAIL: /INIT never rose"); errors = errors + 1; end

        // ---- 0xf4 DAC reset latch ----
        wr(8'hf4, 16'h0000); #1 if (dut.dac_en !== 1'b0) begin $display("FAIL: f4=0 dac_en"); errors = errors + 1; end
        wr(8'hf4, 16'h8000); #1 if (dut.dac_en !== 1'b1) begin $display("FAIL: f4=8000 dac_en"); errors = errors + 1; end
        $display("  ok  0xf4 bit 15 -> dac_en");

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
