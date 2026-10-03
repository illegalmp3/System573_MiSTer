`timescale 1ns/1ps
// tb_s573_cdimg_ack.v - the sd_ack[1] contract of the CD sector reader.
//
// WHY (ddr3mj, 2026-10-02, s573mp3.log): mid-song the CD loader stopped for good.
// From the second after LBA 56839 the fabric reported cd_fetch=100% (s573_cdimg
// sec_busy stuck high) with sectors=0 and ide_acc=0, while Main -- alive, 26,000
// polls/s -- never saw another sd_rd[1] (read total frozen at 52438). Every
// heartbeat before it had fabric completions == Main reads. sec_busy high with
// no request visible to the host is S_STREAM entered WITHOUT a host transfer,
// and the only way into S_STREAM is cd_ack sampled high in S_REQ.
//
// sd_ack is a LEVEL: psx/sys/hps_io.sv raises it on the first word of Main's
// UIO_SECTOR_RD transaction and clears it only when io_enable drops (DisableIO,
// user_io.cpp), i.e. it is still high for a while AFTER the 1176th word -- the
// word on which the reader declares the sector ready. A sec_req that lands in
// that tail (or anywhere inside a transfer) saw the PREVIOUS transfer's ack as
// its own, dropped cd_req after one clock -- too short for Main's status poll
// to ever see -- and waited forever for 1176 words nobody would send.
//
// Upstream guards exactly this: psx/rtl/cd_top.vhd SFETCH_DELAY, "wait for HPS
// ack before new request" -- cd_hps_req is not raised until cd_hps_ack = '0'.
//
// The host BFM here follows Main, not the reader: it POLLS cd_req (a request it
// does not see at a poll does not exist for it), latches the LBA at that poll,
// then holds cd_ack from the transaction's first word until ACK_TAIL clocks
// after its last one.
//   [A] plain fetch
//   [B] next request inside the ack tail of the previous transfer  (the log)
//   [C] re-request in the middle of a transfer (new LBA)
// RED on the pre-fix reader ([B] and [C] wedge), GREEN with the ack-low guard.
module tb_s573_cdimg_ack;
    reg         clk = 0, rst = 1;
    reg         sec_req = 0;
    reg  [31:0] sec_lba = 0;
    reg  [10:0] sbuf_addr = 0;
    wire [15:0] sbuf_q;
    wire        sec_ready, sec_busy;
    wire        cd_req;
    wire [31:0] cd_lba;
    reg         cd_ack = 0, cd_wr = 0;
    reg  [15:0] cd_data = 0;
    integer     errors = 0;

    s573_cdimg dut (
        .clk(clk), .rst(rst), .ide_rst(1'b0),
        .sec_req(sec_req), .sec_lba(sec_lba),
        .sbuf_addr(sbuf_addr), .sbuf_q(sbuf_q),
        .sec_ready(sec_ready), .sec_busy(sec_busy),
        .cd_req(cd_req), .cd_lba(cd_lba),
        .cd_ack(cd_ack), .cd_wr(cd_wr), .cd_data(cd_data)
    );
    always #5 clk = ~clk;

    function [7:0] raw_byte(input [31:0] lba, input integer k);
        raw_byte = (k + 7*lba) & 8'hff;
    endfunction

    // ---- the host: Main's poll loop + hps_io's ack level ----
    localparam integer POLL_CLKS = 64;    // status poll period
    localparam integer ACK_TAIL  = 48;    // last word -> DisableIO
    integer host_xfers = 0;               // transfers the host started
    integer host_words = 0;               // words of the transfer in flight
    reg [31:0] host_lba;
    integer hw;
    initial begin : host
        forever begin
            repeat (POLL_CLKS) @(negedge clk);
            if (cd_req === 1'b1) begin
                host_lba = cd_lba;                 // latched by the status read
                repeat (6) @(negedge clk);         // status transaction ends
                cd_ack = 1'b1;                     // UIO_SECTOR_RD | ack
                host_xfers = host_xfers + 1;
                host_words = 0;
                for (hw = 0; hw < 1176; hw = hw + 1) begin
                    @(negedge clk);
                    cd_data = (host_lba < 32'd150) ? 16'h0000
                            : {raw_byte(host_lba - 32'd150, 2*hw+1), raw_byte(host_lba - 32'd150, 2*hw)};
                    cd_wr = 1'b1;
                    @(negedge clk);
                    cd_wr = 1'b0;
                    host_words = host_words + 1;
                    @(negedge clk);
                end
                repeat (ACK_TAIL) @(negedge clk);  // ... DisableIO
                cd_ack = 1'b0;
            end
        end
    end

    task request(input [31:0] lba);
        begin
            @(negedge clk); sec_lba = lba; sec_req = 1'b1;
            @(negedge clk); sec_req = 1'b0;
        end
    endtask

    // wait for sec_ready with a bound: a wedge is a FAIL, not a hang
    task expect_ready(input [255:0] what, output integer ok);
        integer t;
        begin
            ok = 0;
            for (t = 0; t < 20000 && !ok; t = t + 1) begin
                @(negedge clk);
                if (sec_ready === 1'b1 && sec_busy === 1'b0) ok = 1;
            end
            if (!ok) begin
                $display("FAIL: %0s: WEDGED -- sec_ready never came (sec_busy=%b cd_req=%b cd_ack=%b, host transfers=%0d)",
                         what, sec_busy, cd_req, cd_ack, host_xfers);
                errors = errors + 1;
            end
        end
    endtask

    reg [15:0] v;
    task check_buf(input [255:0] what, input [31:0] lba);
        integer i, bad;
        begin
            bad = 0;
            for (i = 0; i < 1024; i = i + 1) begin
                @(negedge clk); sbuf_addr = i[10:0]; @(posedge clk); #1 v = sbuf_q;
                if (v !== {raw_byte(lba, 16 + 2*i + 1), raw_byte(lba, 16 + 2*i)}) bad = bad + 1;
            end
            if (bad) begin
                $display("FAIL: %0s: %0d of 1024 user words are not LBA %0d's", what, bad, lba);
                errors = errors + 1;
            end
        end
    endtask

    integer ok, x0;
    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ---- [A] plain fetch ----
        request(32'd16);
        expect_ready("[A] plain fetch", ok);
        if (ok) check_buf("[A] plain fetch", 32'd16);
        if (host_xfers !== 1) begin $display("FAIL: [A] host transfers = %0d (expected 1)", host_xfers); errors = errors + 1; end

        // ---- [B] the next request lands in the ack tail of the previous transfer ----
        wait (cd_ack === 1'b0); repeat (8) @(negedge clk);
        request(32'd56839);
        expect_ready("[B] first of the pair", ok);
        // sec_ready rose on the 1176th word; the host has not dropped ack yet
        if (cd_ack !== 1'b1) begin $display("FAIL: [B] bench: ack already low at sec_ready"); errors = errors + 1; end
        repeat (10) @(negedge clk);
        x0 = host_xfers;
        request(32'd56840);                        // inside the tail
        expect_ready("[B] request inside the previous transfer's ack tail", ok);
        if (ok) check_buf("[B] request inside the ack tail", 32'd56840);
        if (host_xfers !== x0 + 1) begin
            $display("FAIL: [B] the host served %0d transfers for the second request (expected 1) -- it never saw cd_req",
                     host_xfers - x0);
            errors = errors + 1;
        end

        // ---- [C] a re-request for a different LBA in the middle of a transfer ----
        wait (cd_ack === 1'b0); repeat (8) @(negedge clk);
        request(32'd1000);
        wait (cd_ack === 1'b1 && host_words == 500);
        request(32'd2000);
        expect_ready("[C] re-request mid-transfer", ok);
        if (ok) check_buf("[C] re-request mid-transfer", 32'd2000);

        if (errors == 0) $display("RESULT: PASS (s573_cdimg ack contract: plain, ack-tail, mid-transfer)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin #400000000; $display("RESULT: FAIL (bench timeout)"); $finish; end
endmodule
