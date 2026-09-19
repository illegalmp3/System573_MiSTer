`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_s573_prof_pc.v - the PC-sampling profiler counts what it says it counts
//
// The profile this module produces is what the ddrextrm 30-fps investigation now
// turns on, so every claim in its header is exercised:
//   1. exactly one sample per 2^SAMPLE_LOG2 cycles (cnt_samples), no more, no less
//      -- including the very first one after reset;
//   2. a PC in the first MB of RAM lands in bin phys[19:11] -- KUSEG, KSEG0 and
//      KSEG1 spellings all in the SAME bin, 2 KB boundaries exact;
//   3. RAM above 1 MB, the BIOS and anything else go to their own counters and
//      NEVER touch a bin;
//   4. bins are cumulative and wrap mod 2^16 (the HPS diffs them);
//   5. the HPS read port returns bin[rd_addr] the cycle after rd_addr, and reading
//      does not disturb counting;
//   6. rst clears the class counters and the sampler but not the bins (diffed).
// The DUT is built with SAMPLE_LOG2=4 (period 16) so the bench runs in seconds;
// a second instance at the default 10 checks the production cadence once.
//
// Phase note: a sample fires on every posedge where the 4-bit tick is 0. run()
// changes pc on a negedge and then waits n*16 cycles, so whatever the phase, the
// window holds exactly n sample edges. Between tests the pc is PARKED on bin 0x040,
// which is never asserted, so the HPS reads (which take cycles) cannot leak samples
// into a bin under test. Bin numbers below are phys >> 11.
// -----------------------------------------------------------------------------
module tb_s573_prof_pc;
    reg clk = 0, rst = 1;
    reg [31:0] pc = 32'h80010000;       // the reset-release sample lands in bin 0x020
    reg [8:0]  rd_addr = 0;
    wire [15:0] rd_data, c_samples, c_ram_hi, c_bios, c_other;
    integer errors = 0;

    always #5 clk = ~clk;

    s573_prof_pc #(.SAMPLE_LOG2(4)) dut (
        .clk(clk), .rst(rst), .pc(pc),
        .rd_addr(rd_addr), .rd_data(rd_data),
        .cnt_samples(c_samples), .cnt_ram_hi(c_ram_hi), .cnt_bios(c_bios), .cnt_other(c_other)
    );

    // production-cadence instance: same stimulus, only cnt_samples is checked
    wire [15:0] p_rd, p_samples, p_hi, p_bios, p_other;
    s573_prof_pc dut10 (
        .clk(clk), .rst(rst), .pc(pc),
        .rd_addr(9'd0), .rd_data(p_rd),
        .cnt_samples(p_samples), .cnt_ram_hi(p_hi), .cnt_bios(p_bios), .cnt_other(p_other)
    );

    localparam [31:0] PARK = 32'h80020000;   // bin 0x040: never asserted

    task chk(input [511:0] name, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) begin
                $display("FAIL: %0s = %0d (0x%0h), expected %0d (0x%0h)", name, got, got, want, want);
                errors = errors + 1;
            end
        end
    endtask

    // hold `addr` on the pc input for exactly n sample periods (n*16 cycles)
    task run(input [31:0] addr, input integer n);
        begin
            pc = addr;
            repeat (n * 16) @(negedge clk);
        end
    endtask

    // read one bin through the HPS port. The RMW of the last sample lands 3
    // cycles after it; wait that out so the value is settled.
    task read_bin(input [8:0] a, output [15:0] v);
        begin
            repeat (4) @(negedge clk);
            rd_addr = a;
            @(negedge clk);      // rd_data <= bins[rd_addr] at the posedge in between
            v = rd_data;
        end
    endtask

    reg [15:0] v, v2;
    integer k;
    initial begin
        repeat (3) @(negedge clk);
        rst = 0;                 // the posedge after this samples pc=0x80010000 (bin 0x020)
        @(negedge clk);

        // ---- 1/2: 100 samples at DecDCTvlc's entry -> bin 0x0e7 (0x80073800..0x80073fff)
        run(32'h80073804, 100);
        // ---- 2: the same 2 KB spelled KUSEG and KSEG1 -> the same bin
        run(32'h00073800, 10);
        run(32'ha0073ffc, 10);
        // ---- 2b: neighbouring bins are independent; the 2 KB boundary exact --
        // 0x800736a4 (DecDCToutSync's spin) must NOT share a bin with DecDCTvlc
        run(32'h80074000, 7);          // first word of bin 0x0e8
        run(32'h800737fc, 5);          // last word of bin 0x0e6
        run(32'h800736a4, 3);          // DecDCToutSync spin -> bin 0x0e6 too
        // ---- 3: classes that must not touch the bins
        run(32'h80100000, 11);         // RAM, 1 MB exactly -> ram_hi
        run(32'h803ffffc, 4);          // RAM, top of 4 MB -> ram_hi
        run(32'hbfc00000, 9);          // BIOS, KSEG1
        run(32'h9fc7fffc, 3);          // BIOS, KSEG0, last word of the 512 KB
        run(32'h1f800000, 6);          // scratchpad (KUSEG) -> other
        run(32'h1f000000, 2);          // EXP1 -> other
        run(32'hc0000000, 1);          // KSEG2 -> other
        run(32'h80800000, 5);          // RAM mirror decode ends at 8 MB -> other
        // checked at the negedge that ends the last run: no further sample yet
        chk("ram_hi", c_ram_hi, 15);
        chk("bios", c_bios, 12);
        chk("other", c_other, 14);
        chk("cnt_samples = 1 (reset release) + every run", c_samples, 1 + 135 + 41);

        pc = PARK;
        read_bin(9'h0e7, v); chk("bin 0x0e7: 100 KSEG0 + 10 KUSEG + 10 KSEG1 samples", v, 120);
        read_bin(9'h0e8, v); chk("bin 0x0e8", v, 7);
        read_bin(9'h0e6, v); chk("bin 0x0e6: 5 at its last word + 3 in the outSync spin", v, 8);
        read_bin(9'h020, v); chk("bin 0x020: the one sample at reset release", v, 1);
        read_bin(9'h000, v); chk("bin 0x000 untouched by the other classes", v, 0);
        read_bin(9'h1ff, v); chk("bin 0x1ff untouched by the other classes", v, 0);
        read_bin(9'h100, v); chk("bin 0x100 untouched by the other classes", v, 0);
        read_bin(9'h0ff, v); chk("bin 0x0ff untouched by the other classes", v, 0);

        // ---- 5: the read port does not disturb counting (sweep it while sampling):
        // 48 cycles = exactly 3 sample edges whatever the phase
        pc = 32'h80050000;
        for (k = 0; k < 48; k = k + 1) begin
            rd_addr = k[8:0];
            @(negedge clk);
        end
        pc = PARK;
        read_bin(9'h0a0, v); chk("bin 0x0a0 while the HPS port was busy", v, 3);

        // ---- 4: wrap mod 2^16 -- 65,540 samples into one bin reads 4
        run(32'h800e0000, 65540);
        pc = PARK;
        read_bin(9'h1c0, v); chk("bin 0x1c0 wraps mod 65536", v, 4);

        // ---- 6: rst clears the class counters and the sampler, keeps the bins
        @(negedge clk); rst = 1; repeat (2) @(negedge clk);
        chk("cnt_samples cleared by rst", c_samples, 0);
        chk("ram_hi cleared by rst", c_ram_hi, 0);
        chk("bios cleared by rst", c_bios, 0);
        chk("other cleared by rst", c_other, 0);
        rst = 0;
        read_bin(9'h0e7, v); chk("bin 0x0e7 survives rst (cumulative, the HPS diffs it)", v, 120);

        // ---- 1 at the production cadence: 4096 cycles -> exactly 4 samples
        v2 = p_samples;
        pc = PARK;
        repeat (4096) @(negedge clk);
        chk("SAMPLE_LOG2=10: 4096 cycles = 4 samples", (p_samples - v2) & 16'hffff, 4);

        if (errors == 0) $display("RESULT: PASS (s573_prof_pc)");
        else             $display("RESULT: FAIL (s573_prof_pc, %0d errors)", errors);
        $finish;
    end
endmodule
