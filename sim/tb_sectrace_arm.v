`timescale 1ns/1ps
// tb_sectrace_arm.v -- prove the cassette recorder's ARM GATE before a bitstream
// is spent on it.
//
// Three bitstreams in a row produced an unusable capture, and every time the fault
// was the gate, not the hypothesis: CS (asserted the whole time, so idle polling
// overwrote it), then in_rtr (never falls, same result), then a fill-once ring
// (full of boot-time DS2401 latch writes before the probe ever ran). Each was
// "obviously right" when written and each cost a 25-minute build plus a hardware
// session. So the gate gets a bench of its own now.
//
// The bench replays the three phases the board actually presents, in order:
//
//   A  boot: 300 cassette latch writes and 300 misc reads with CS asserted, RST
//      already high and SCL DEAD -- the measured shape of the traffic that
//      swallowed the 128-entry ring (the board DS2401 lives on latch D4 and needs
//      no clock). The window must stay SHUT.
//   A' one spurious SCL edge and 100 more events. This DOES arm (that is the
//      fallback trigger doing its job), and phase B must then throw it away.
//   B  the detector probe from PSX.EXE 0x803250b8: CS, RST pulse, one throwaway SCL
//      cycle, then 32 x {read bit 2 with SCL low, SCL high, SCL low}, with cpu_bit
//      carrying 0x5a530001 MSB-first. The RST rising edge must RE-ARM -- discarding
//      phase A' entirely -- and the whole probe must fit, tail included.
//   C  the error screen: 400 more misc reads with SCL dead. The frozen 32-read
//      assembly must NOT move -- this is the exact failure mode of attempts 1 and 2.
//
// PASS means: shut through A, armed in A', re-armed clean in B with the id both
// reconstructible from the ring and held in cap_bits, and unmoved through C.
module tb_sectrace_arm;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg  cs_n = 1'b0;        // selected, exactly as the board leaves it
    reg  rst_line = 1'b1;
    reg  scl = 1'b0;
    reg  sda = 1'b0;
    reg  io0_dir = 1'b0;
    reg  io0 = 1'b0;
    reg  cpu_bit = 1'b0;
    reg  [2:0] zs01_state = 3'd0;
    reg  latch_wr = 1'b0, misc_rd = 1'b0;

    reg  [7:0]  taddr = 8'd0;
    wire [15:0] tdata;
    wire [15:0] tcount;
    wire [31:0] cap_bits;
    wire [7:0]  cap_cnt;

    s573_sectrace dut (
        .clk(clk), .rst(rst),
        .cs_n(cs_n), .rst_line(rst_line), .scl(scl), .sda(sda),
        .io0_dir(io0_dir), .io0(io0), .cpu_bit(cpu_bit), .zs01_state(zs01_state),
        .latch_wr(latch_wr), .misc_rd(misc_rd),
        .trace_addr(taddr), .trace_data(tdata), .trace_count(tcount),
        .cap_bits(cap_bits), .cap_cnt(cap_cnt)
    );

    wire       armed   = tcount[9];
    wire [8:0] entries = tcount[8:0];

    localparam [31:0] ZS01_ID = 32'h5a53_0001;

    // one cassette latch write, then the CPU's own inter-write delay
    task wr; begin
        @(negedge clk); latch_wr = 1'b1;
        @(negedge clk); latch_wr = 1'b0;
        repeat (20) @(negedge clk);
    end endtask

    // one CPU read of 0x1f400006
    task rd; begin
        @(negedge clk); misc_rd = 1'b1;
        @(negedge clk); misc_rd = 1'b0;
        repeat (20) @(negedge clk);
    end endtask

    integer k, errors;
    reg [31:0] from_ring;
    integer reads_seen;
    reg [31:0] cap_after_probe;
    reg [8:0]  entries_after_probe;

    initial begin
        errors = 0;
        repeat (4) @(negedge clk); rst = 1'b0; repeat (4) @(negedge clk);

        // ---------------- phase A: boot / DS2401 on D4, SCL dead ----------------
        for (k = 0; k < 300; k = k + 1) begin
            sda = k[0];          // D0 moves, D1 never does
            wr;
            rd;
        end
        if (armed !== 1'b0) begin
            $display("tb_sectrace_arm: FAIL: armed during the boot traffic (entries=%0d)", entries);
            errors = errors + 1;
        end
        if (entries !== 9'd0) begin
            $display("tb_sectrace_arm: FAIL: recorded %0d boot entries; the window must stay shut", entries);
            errors = errors + 1;
        end

        // ------------- phase A': a spurious SCL edge arms the fallback -------------
        scl = 1'b1;  wr;
        scl = 1'b0;  wr;
        cpu_bit = 1'b1;
        for (k = 0; k < 100; k = k + 1) begin wr; rd; end
        if (armed !== 1'b1) begin
            $display("tb_sectrace_arm: FAIL: an SCL edge with CS asserted did not arm the fallback");
            errors = errors + 1;
        end
        if (entries === 9'd0) begin
            $display("tb_sectrace_arm: FAIL: armed but recorded nothing in phase A'");
            errors = errors + 1;
        end
        $display("tb_sectrace_arm: phase A' armed the fallback and recorded %0d entries (to be discarded)",
                 entries);

        // ---------------- phase B: the detector probe ----------------
        sda = 1'b0;                      wr;
        scl = 1'b0;                      wr;   // SCL low  (still no edge: already 0)
        cs_n = 1'b0;                     wr;   // CS low = selected
        rst_line = 1'b0;                 wr;   // RST low
        rst_line = 1'b1; zs01_state = 3'd1; wr; // RST high -> response to reset
        scl = 1'b1;                      wr;   // SCL high  <== the arm edge
        scl = 1'b0;                      wr;   // SCL low -> chip drives bit 0
        for (k = 0; k < 32; k = k + 1) begin
            cpu_bit = ZS01_ID[31 - k];   // what s573_io hands the CPU this clock
            io0     = ZS01_ID[31 - k];
            rd;                          // sample bit 2 while SCL low
            scl = 1'b1;              wr;
            scl = 1'b0;              wr;
        end
        if (armed !== 1'b1) begin
            $display("tb_sectrace_arm: FAIL: the probe did not arm the window");
            errors = errors + 1;
        end
        // The RST rise must have DISCARDED phase A': ~99 probe entries, not ~300.
        if (entries > 9'd150) begin
            $display("tb_sectrace_arm: FAIL: %0d entries -- the RST edge did not discard phase A'",
                     entries);
            errors = errors + 1;
        end
        cap_after_probe    = cap_bits;
        entries_after_probe = entries;
        if (cap_cnt !== 8'd32) begin
            $display("tb_sectrace_arm: FAIL: cap_cnt=%0d, expected 32 reads in the probe window", cap_cnt);
            errors = errors + 1;
        end
        if (cap_bits !== ZS01_ID) begin
            $display("tb_sectrace_arm: FAIL: cap_bits=0x%08x, expected 0x%08x", cap_bits, ZS01_ID);
            errors = errors + 1;
        end
        if (entries >= 9'd256) begin
            $display("tb_sectrace_arm: FAIL: the ring filled during the probe (%0d) -- the tail is lost",
                     entries);
            errors = errors + 1;
        end

        // reconstruct the id from the ring the way the HPS service does
        from_ring = 32'd0; reads_seen = 0;
        for (k = 0; k < entries_after_probe; k = k + 1) begin
            @(negedge clk); taddr = k[7:0];
            @(negedge clk);
            if (tdata[15]) begin                       // an R entry
                if (reads_seen < 32) from_ring = {from_ring[30:0], tdata[8]};
                reads_seen = reads_seen + 1;
            end
        end
        $display("tb_sectrace_arm: probe recorded %0d entries, %0d CPU reads -> ring assembles 0x%08x",
                 entries_after_probe, reads_seen, from_ring);
        if (from_ring !== ZS01_ID) begin
            $display("tb_sectrace_arm: FAIL: the ring assembles 0x%08x, expected 0x%08x",
                     from_ring, ZS01_ID);
            errors = errors + 1;
        end

        // ---------------- phase C: the error screen polls forever ----------------
        cpu_bit = 1'b1; io0 = 1'b1;
        for (k = 0; k < 400; k = k + 1) rd;
        if (cap_bits !== cap_after_probe) begin
            $display("tb_sectrace_arm: FAIL: idle polling moved cap_bits 0x%08x -> 0x%08x",
                     cap_after_probe, cap_bits);
            errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d checks)", errors);
        $finish;
    end
endmodule
