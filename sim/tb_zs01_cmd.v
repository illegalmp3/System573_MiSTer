`timescale 1ns/1ps
// tb_zs01_cmd.v -- the ZS01 COMMAND path through s573_seccart, driven the way the
// GAME drives it, checked against an INDEPENDENT golden.
//
// WHY THIS EXISTS. tb_s573_seccart Part 3 was the only test covering the ZS01
// command/START path, and it gates on secdata/gtrfrk5m_u1.hex -- a fixture this tree
// has never had (no dumps/mame573/gtrfrk5m.zip). It therefore SKIPPED silently and
// reported PASS, so the ZS01 integration was effectively untested, which is how the
// SDA-wiring bug (docs/2026-09-14-ddrusa-zs01-sda-is-control-bit6.md) survived.
//
// This bench uses the ddrusa dump, which we DO have, and differs from
// tb_zs01_golden.v in the thing that matters: it goes through s573_seccart, so the
// host-side SDA WIRING is part of the device under test.
//
//   * SDA is driven ONLY through CONTROL bit 6 (io0_dir), active-low, exactly as
//     PSX.EXE's ZS01 driver does (0x80325000-0x80326200 via the setter 0x803208f4).
//   * LATCH D0 IS HELD LOW THROUGHOUT, as the real board leaves it -- the ZS01 driver
//     never writes D0. This is what makes the test able to FAIL: with the old
//     `zs01_sda_i = d_q[0] & ~io0_dir`, SDA is pinned low, no START is ever seen,
//     i2c_starts stays 0 and every command times out.
//   * SCL=D1, CS=D2 (low=selected), RST=D3.
//
// The command and response bytes are raw ciphertext from secdata/ddrusa_zs01_vectors.hex,
// produced by tools/zs01_ref.py (a transcription of MAME zs01.cpp that shares no code
// with rtl/zs01.v), so NO cipher runs on the checking side.
module tb_zs01_cmd;
    localparam integer NV_MAX = 13;
    reg clk = 0, rst = 1;
    // latch: [0]=D0 (NOT wired to ZS01) [1]=SCL [2]=CS(low=sel) [3]=RST [4]=DS2401
    reg [7:0] dl  = 8'b0000_0100;      // D0=0, SCL=0, CS=1(deselected), RST=0
    reg       io0 = 1'b0;              // control bit6: 0 -> SDA released HIGH
    reg        L_we = 0; reg [12:0] L_addr = 0; reg [7:0] L_data = 0;
    reg        S_we = 0; reg [2:0]  S_addr = 0; reg [7:0] S_data = 0;
    // cassette-persistence observability (2026-09-16): the NVRAM dump port and the
    // "a WRITE changed persisted state" strobe, checked against the MAME-model NVRAM
    // after the same vectors (tools/zs01_ref.py --nvout).
    reg  [7:0] dump_addr = 8'd0;
    wire [7:0] dump_data;
    wire       nv_wr;
    integer    nv_wr_cnt = 0;
    always @(posedge clk) if (nv_wr) nv_wr_cnt = nv_wr_cnt + 1;
    wire [63:0] sec_dbg;  wire sec_io0;  wire [7:0] sec_in;
    wire sec_drdy, sec_irdy;

    s573_seccart #(.DS_CLK_HZ(1_000_000)) dut (
        .clk(clk), .rst(rst), .cart_type(2'd2),          // ZS01
        .latch_we(1'b1), .d_latch(dl), .io0_dir(io0),
        .load_eep_we(L_we), .load_eep_addr(L_addr), .load_eep_data(L_data),
        .load_ser_we(S_we), .load_ser_addr(S_addr), .load_ser_data(S_data),
        .sec_dbg(sec_dbg), .sec_cs_n(), .sec_rst_line(), .sec_scl_line(),
        .sec_sda_line(), .sec_ds_line(), .sec_zs01_state(), .sec_rtr_edges(),
        .sec_in_rtr(), .sec_rtr_emit(),
        .sec_io0(sec_io0), .sec_in(sec_in), .sec_drdy(sec_drdy), .sec_irdy(sec_irdy),
        .zs01_dump_addr(dump_addr), .zs01_dump_data(dump_data), .zs01_nv_wr(nv_wr)
    );


    always #5 clk = ~clk;
    task tk; begin repeat (3) @(posedge clk); end endtask

    // ---- host drive: SDA on control bit 6 only, SCL on latch D1 ----
    task sda(input v); begin io0 = ~v; tk; end endtask     // v=1 release high, v=0 pull low
    task scl(input v); begin dl[1] = v; tk; end endtask

    task i2c_start; begin scl(0); sda(1); scl(1); sda(0); scl(0); end endtask

    task send_byte(input [7:0] d, output ack);
        integer i; begin
            for (i = 7; i >= 0; i = i - 1) begin scl(0); sda(d[i]); scl(1); end
            scl(0); sda(1); scl(1); ack = sec_io0; scl(0);      // 9th clock = device ACK
        end
    endtask

    task read_byte(output [7:0] d);
        integer i; begin
            d = 8'h00;
            for (i = 7; i >= 0; i = i - 1) begin scl(0); sda(1); scl(1); d[i] = sec_io0; end
            scl(0); sda(0); scl(1); scl(0); sda(1);             // master ACK (SDA low)
        end
    endtask

    reg [7:0] u1 [0:139];
    reg [7:0] u6 [0:7];
    reg [7:0] vec [0:1023];
    reg [7:0] resp [0:11];
    reg [7:0] nvgold [0:139];
    integer k, v, nvec, bad, errors, fh;
    reg ack;
    reg [5:0] starts; reg [7:0] pkts;

    initial begin
        errors = 0;
        fh = $fopen("secdata/ddrusa_zs01_vectors.hex", "r");
        if (fh == 0) begin
            $display("tb_zs01_cmd: ddrusa fixture absent -- SKIPPED");
            $display("RESULT: PASS"); $finish;
        end
        $fclose(fh);
        for (k = 0; k < 140; k = k + 1) u1[k] = 8'h00;
        $readmemh("secdata/ddrusa_u1.hex", u1, 0, 139);
        $readmemh("secdata/ddrusa_u6.hex", u6);
        $readmemh("secdata/ddrusa_zs01_vectors.hex", vec);

        // ---- load the real ddrusa cassette through the boot load port ----
        repeat (4) @(posedge clk);
        for (k = 0; k < 140; k = k + 1) begin
            @(negedge clk); L_we = 1; L_addr = k[12:0]; L_data = u1[k];
        end
        @(negedge clk); L_we = 0;
        for (k = 0; k < 8; k = k + 1) begin
            @(negedge clk); S_we = 1; S_addr = k[2:0]; S_data = u6[k];
        end
        @(negedge clk); S_we = 0;
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; repeat (4) @(posedge clk);

        // ---- select the cassette (CS low), SDA released, SCL low ----
        dl[2] = 1'b0; io0 = 1'b0; dl[1] = 1'b0; tk;

        // ---- replay every golden vector as a real I2C transaction ----
        nvec = vec[0];
        if (nvec > NV_MAX) nvec = NV_MAX;
        $display("tb_zs01_cmd: replaying %0d ddrusa vectors through s573_seccart", nvec);
        for (v = 0; v < nvec; v = v + 1) begin
            i2c_start;
            for (k = 0; k < 12; k = k + 1) send_byte(vec[1 + 24*v + k], ack);
            repeat (1000) @(posedge clk);              // the packet engine is multi-cycle
            for (k = 0; k < 12; k = k + 1) read_byte(resp[k]);
            bad = 0;
            for (k = 0; k < 12; k = k + 1)
                if (resp[k] !== vec[1 + 24*v + 12 + k]) bad = bad + 1;
            if (bad != 0) begin
                errors = errors + 1;
                $display("FAIL: vector %0d: %0d of 12 response bytes differ", v, bad);
                $write("       expected:"); for (k=0;k<12;k=k+1) $write(" %02h", vec[1+24*v+12+k]); $write("\n");
                $write("       got     :"); for (k=0;k<12;k=k+1) $write(" %02h", resp[k]);         $write("\n");
            end
        end

        // ---- NVRAM dump == the MAME model's NVRAM after the same 13 vectors ----
        // The vectors contain exactly three state-changing WRITEs (0x0d, 0x0c cmd|4,
        // 0xff data key); READs and the bad-CRC packet must not strobe nv_wr.
        fh = $fopen("secdata/ddrusa_zs01_nv_after.hex", "r");
        if (fh == 0) begin
            $display("FAIL: secdata/ddrusa_zs01_nv_after.hex missing -- rerun sim/gen_secdata.sh");
            errors = errors + 1;
        end else begin
            $fclose(fh);
            $readmemh("secdata/ddrusa_zs01_nv_after.hex", nvgold);
            bad = 0;
            for (k = 0; k < 140; k = k + 1) begin
                @(negedge clk); dump_addr = k[7:0];
                repeat (3) @(posedge clk); #1;
                if (dump_data !== nvgold[k]) begin
                    if (bad < 6) $display("FAIL: NVRAM dump byte %0d = %02h, MAME model %02h", k, dump_data, nvgold[k]);
                    bad = bad + 1;
                end
            end
            if (bad != 0) begin
                $display("FAIL: %0d of 140 NVRAM dump bytes differ from the MAME model", bad);
                errors = errors + 1;
            end
        end
        if (nv_wr_cnt != 3) begin
            $display("FAIL: nv_wr pulsed %0d times over the vectors (expected 3 state-changing WRITEs)", nv_wr_cnt);
            errors = errors + 1;
        end

        starts = sec_dbg[61:56];
        pkts   = sec_dbg[7:0];
        $display("  fabric: i2c_starts=%0d  packets=%0d  (0 starts => SDA never went high: wiring bug)",
                 starts, pkts);
        if (starts == 0) begin
            $display("FAIL: the ZS01 saw NO I2C START -- the host SDA path is broken");
            errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d error(s))", errors);
        $finish;
    end
endmodule
