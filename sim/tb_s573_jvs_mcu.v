// tb_s573_jvs_mcu.v -- the 573's JVS MCU (rtl/s573_jvs_mcu.v) against psx-spx.
//
//  1. the BIOS self-test sequence psx-spx lists for the 700B01 shell, i.e. the
//     {error,status} nibbles MAME stores in h8b01.bin: 0C after reset, 0E after
//     a valid header word, 0A after an invalid one, 0D for each of 16 valid dummy
//     packets, 05 for each of 16 with a bad checksum; plus JVSIRDY/JVSDRDY = 0 and
//     data 0 after reset;
//  2. a transaction exactly as DDR's JVS driver does it (game 0x800c17a4 send,
//     0x800c18ec receive): the HPS sees the request, answers it, and the 573 reads
//     the response word by word with the status codes psx-spx gives;
//  3. a response tagged with an old req_seq is dropped;
//  4. EN=0 (reader Off) reads exactly the legacy constants.
// Run with -DEXPECT_RED and EN tied 0 for parts 1-3 to see them fail (RED).
`timescale 1ns/1ps
module tb_s573_jvs_mcu;
    reg clk = 0, rst = 1, en = 1;
    always #15 clk = ~clk;

    reg        mcu_rst_n = 0, wr_data = 0, clr_irdy = 0;
    reg [15:0] wdata = 0;
    wire [1:0] status, error;
    wire irdy, drdy, sense, waiting;
    wire [15:0] rdata;
    wire [7:0] req_seq;
    wire [8:0] req_len;
    reg  [7:0] req_raddr = 0;
    wire [15:0] req_rword;
    reg        resp_we = 0, resp_commit = 0;
    reg  [7:0] resp_waddr = 0;
    reg  [8:0] resp_len = 0;
    reg  [15:0] resp_wword = 0;
    reg  [7:0] resp_seq = 0;
    reg        sense_in = 1;

    s573_jvs_mcu dut (
        .clk(clk), .rst(rst), .en(en),
        .mcu_rst_n(mcu_rst_n), .wr_data(wr_data), .wdata(wdata), .clr_irdy(clr_irdy),
        .status(status), .error(error), .irdy(irdy), .drdy(drdy), .sense(sense), .rdata(rdata),
        .req_seq(req_seq), .req_len(req_len), .req_raddr(req_raddr), .req_rword(req_rword),
        .resp_we(resp_we), .resp_waddr(resp_waddr), .resp_wword(resp_wword),
        .resp_commit(resp_commit), .resp_len(resp_len), .resp_seq(resp_seq),
        .sense_in(sense_in), .waiting(waiting));

    integer fails = 0, checks = 0;
    wire [3:0] nib = {error, status};
    task expect_nib(input [3:0] want, input [255:0] what);
        begin
            checks = checks + 1;
            if (nib !== want) begin
                fails = fails + 1;
                $display("FAIL %0s: nibble %h, want %h", what, nib, want);
            end
        end
    endtask

    task mcu_reset;     // game 0x800c147c: bit 8 low, wait, high
        begin
            @(posedge clk) mcu_rst_n <= 0;
            repeat (20) @(posedge clk);
            mcu_rst_n <= 1;
            repeat (4) @(posedge clk);
            clr_irdy <= 1; @(posedge clk) clr_irdy <= 0;
            repeat (4) @(posedge clk);
        end
    endtask

    task wr(input [15:0] w);
        begin
            @(posedge clk) begin wr_data <= 1; wdata <= w; end
            @(posedge clk) wr_data <= 0;
            repeat (3) @(posedge clk);
            checks = checks + 1;
            if (drdy !== 1'b0) begin fails = fails + 1; $display("FAIL JVSDRDY still set after a write"); end
        end
    endtask

    // send a packet the way game 0x800c17a4 builds and writes it
    reg [7:0] pkt [0:299];
    integer n, i, words;
    task send(input [7:0] addr, input integer len, input integer bad);
        reg [7:0] s;
        begin
            pkt[0] = 8'he0; pkt[1] = addr; pkt[2] = len + 1;
            s = addr + len + 1;
            for (i = 0; i < len; i = i + 1) s = s + pkt[3 + i];
            pkt[3 + len] = bad ? s + 8'd1 : s;
            n = len + 4;
            words = (len + 5) / 2;
            for (i = 0; i < words; i = i + 1)
                wr({(2*i+1 < n) ? pkt[2*i+1] : 8'h00, pkt[2*i]});
        end
    endtask

    reg [7:0] rsp [0:63];
    integer rn, k;
    task hps_answer(input [7:0] seq);
        begin
            for (k = 0; k < rn; k = k + 2) begin
                @(posedge clk) begin resp_we <= 1; resp_waddr <= k / 2; resp_wword <= {(k + 1 < rn) ? rsp[k+1] : 8'hee, rsp[k]}; end
            end
            @(posedge clk) begin resp_we <= 0; resp_commit <= 1; resp_len <= rn; resp_seq <= seq; end
            @(posedge clk) resp_commit <= 0;
            repeat (8) @(posedge clk);
        end
    endtask

    reg [15:0] got;
    initial begin
        if ($test$plusargs("red")) en = 0;
        repeat (4) @(posedge clk); rst <= 0;
        repeat (4) @(posedge clk);

        // ---- 1. BIOS self-test (psx-spx 700B01 list / h8b01.bin) ----
        mcu_reset;
        expect_nib(4'hc, "after reset");
        checks = checks + 3;
        if (irdy !== 0 || drdy !== 0 || rdata !== 16'h0000) begin fails = fails + 1; $display("FAIL reset: irdy %b drdy %b data %h", irdy, drdy, rdata); end
        mcu_reset; wr(16'h00e0); expect_nib(4'he, "valid header");
        mcu_reset; wr(16'h001f); expect_nib(4'ha, "invalid header");
        for (k = 0; k < 16; k = k + 1) begin
            mcu_reset;
            pkt[3] = 8'h00; pkt[4] = (16'h1 << k) & 8'hff; pkt[5] = ((16'h1 << k) >> 8) & 8'hff;
            send(8'h1f, 3, 0);
            expect_nib(4'hd, "dummy packet");
        end
        for (k = 0; k < 16; k = k + 1) begin
            mcu_reset;
            pkt[3] = 8'h00; pkt[4] = (16'h1 << k) & 8'hff; pkt[5] = ((16'h1 << k) >> 8) & 8'hff;
            send(8'h1f, 3, 1);
            expect_nib(4'h5, "dummy packet, bad checksum");
        end

        // ---- 2. a DDR transaction: 01 71 (status) answered with 01 01 00 00 ----
        mcu_reset;
        pkt[3] = 8'h71;
        send(8'h01, 1, 0);
        expect_nib(4'hd, "request out");
        checks = checks + 2;
        if (req_len !== 9'd5) begin fails = fails + 1; $display("FAIL req_len %0d", req_len); end
        req_raddr <= 1; @(posedge clk); @(posedge clk);
        if (req_rword !== 16'h7102) begin fails = fails + 1; $display("FAIL req word 1 = %h (want 7102)", req_rword); end
        // E0 00 05 01 01 00 00 07  (status 01, report 01, data 0000)
        rsp[0]=8'he0; rsp[1]=8'h00; rsp[2]=8'h05; rsp[3]=8'h01; rsp[4]=8'h01; rsp[5]=8'h00; rsp[6]=8'h00; rsp[7]=8'h07;
        rn = 8;
        hps_answer(req_seq);
        expect_nib(4'hc, "response ready: status 0");
        checks = checks + 1;
        if (irdy !== 1 || rdata !== 16'h00e0) begin fails = fails + 1; $display("FAIL first word %h irdy %b (game wants 00E0)", rdata, irdy); end
        for (k = 1; k < 4; k = k + 1) begin
            clr_irdy <= 1; @(posedge clk) clr_irdy <= 0;
            repeat (8) @(posedge clk);
            checks = checks + 2;
            if (irdy !== 1 || rdata !== {rsp[2*k+1], rsp[2*k]}) begin fails = fails + 1; $display("FAIL word %0d = %h irdy %b", k, rdata, irdy); end
            if (status !== 2'd2) begin fails = fails + 1; $display("FAIL status %0d while reading (want 2)", status); end
        end
        clr_irdy <= 1; @(posedge clk) clr_irdy <= 0;
        repeat (8) @(posedge clk);
        expect_nib(4'hc, "all read: status 0");
        checks = checks + 1;
        if (irdy !== 0) begin fails = fails + 1; $display("FAIL irdy after the last word"); end

        // ---- 3. a stale response (old seq) is dropped ----
        mcu_reset;
        pkt[3] = 8'h71;
        send(8'h01, 1, 0);
        hps_answer(req_seq - 8'd1);
        expect_nib(4'hd, "stale response ignored");
        checks = checks + 1;
        if (irdy !== 0) begin fails = fails + 1; $display("FAIL stale response delivered"); end

        // ---- 4. sense passes the board's level ----
        sense_in = 0; #1;
        checks = checks + 1;
        if (sense !== 1'b0) begin fails = fails + 1; $display("FAIL sense"); end

        // ---- 5. reader Off: the legacy constants ----
        en = 0; #1;
        checks = checks + 1;
        if (nib !== 4'hc || irdy !== 0 || drdy !== 0 || sense !== 1 || rdata !== 0) begin
            fails = fails + 1; $display("FAIL en=0 legacy constants");
        end

        if (fails) $display("RESULT: FAIL (s573_jvs_mcu, %0d of %0d checks)", fails, checks);
        else       $display("RESULT: PASS (s573_jvs_mcu, %0d checks)", checks);
        $finish;
    end
endmodule
