// tb_s573_wio.v -- the reader's fabric half (rtl/s573_wio.v) as the HPS and the
// 573 see it: CMD_573_WIO words on one side, the 573's JVS registers on the
// other, a PS1 card on the SNAC pins.
//   1. before ATTACH the JVS bits read the legacy constants (nibble C, no IRDY)
//   2. the 573 sends 01 71 the way DDR's driver does; the HPS sees req_seq step
//      and reads the request back with GETREQ
//   3. the HPS answers with PUTRESP; the 573 reads it word by word
//   4. SENSE drives 0x1f400006 bit 3
//   5. CARDREG + XFER exchange a byte with the card; NOP polls the result
//   6. a PUTRESP cut short commits nothing
// +red: osd_en = 0 (reader Off) -- everything above must fail.
`timescale 1ns/1ps
module tb_s573_wio;
    reg clk = 0, rst = 1, osd_en = 1;
    always #14.76 clk = ~clk;

    reg        mcu_rst_n = 0, jvs_wr = 0, jvs_clr = 0;
    reg [15:0] jvs_wdata = 0;
    wire [1:0] st, er;
    wire irdy, drdy, sense;
    wire [15:0] rdata;
    reg        stb = 0;
    reg  [9:0] idx = 0;
    reg [15:0] din = 0;
    wire [15:0] dout;
    wire [6:0] uo;
    reg        card_ack_n = 1, card_dat = 1;
    wire [6:0] ui = {1'b1, 1'b1, card_dat, card_ack_n, 1'b1, 1'b1, 1'b1};

    s573_wio dut (
        .clk(clk), .rst(rst), .osd_en(osd_en), .snac_en(1'b1),
        .mcu_rst_n(mcu_rst_n), .jvs_wr(jvs_wr), .jvs_wdata(jvs_wdata), .jvs_clr(jvs_clr),
        .jvs_status(st), .jvs_error(er), .jvs_irdy(irdy), .jvs_drdy(drdy),
        .jvs_sense(sense), .jvs_rdata(rdata),
        .stb(stb), .idx(idx), .din(din), .dout(dout),
        .user_out(uo), .user_in(ui));

    // ---- a card on SNAC port 1 (as tb_s573_wio_port) ----
    wire sel1_n = uo[1], cmd = uo[2], sclk = uo[5];
    reg  [7:0] out_byte = 8'ha5, in_byte = 0;
    integer    nb = 0;
    always @(negedge sclk) if (!sel1_n) card_dat <= out_byte[nb];
    always @(posedge sclk) if (!sel1_n) begin
        in_byte = {cmd, in_byte[7:1]};
        nb = nb + 1;
        if (nb == 8) begin
            nb = 0;
            fork begin #12000 card_ack_n = 0; #3000 card_ack_n = 1; end join_none
        end
    end

    integer fails = 0, checks = 0;
    task check(input cond, input [511:0] what);
        begin checks = checks + 1; if (!cond) begin fails = fails + 1; $display("FAIL %0s", what); end end
    endtask

    // ---- the HPS side: one SPI transaction = a list of words ----
    reg [15:0] tx [0:200];
    reg [15:0] rx [0:200];
    integer ntx, w;
    task spi;
        begin
            for (w = 0; w < ntx; w = w + 1) begin
                @(posedge clk) begin stb <= 1; idx <= w; din <= tx[w]; end
                #1 rx[w] = dout;            // the answer to this word, at its strobe
                @(posedge clk) stb <= 0;
                repeat (12) @(posedge clk);  // an SPI word is far slower than clk
            end
        end
    endtask
    task op(input [7:0] o, input [7:0] a);
        begin tx[0] = 16'h006f; tx[1] = {o, a}; ntx = 2; spi; end
    endtask

    // ---- the 573 side ----
    task wr573(input [15:0] v);
        begin @(posedge clk) begin jvs_wr <= 1; jvs_wdata <= v; end @(posedge clk) jvs_wr <= 0; repeat (4) @(posedge clk); end
    endtask
    task clr573;
        begin @(posedge clk) jvs_clr <= 1; @(posedge clk) jvs_clr <= 0; repeat (6) @(posedge clk); end
    endtask

    integer i;
    initial begin
        if ($test$plusargs("red")) osd_en = 0;
        repeat (5) @(posedge clk); rst <= 0;
        repeat (5) @(posedge clk); mcu_rst_n <= 1;
        repeat (5) @(posedge clk);

        // 1. not attached
        check({er, st} == 4'hc && irdy == 0 && sense == 1, "1: legacy constants before ATTACH");
        op(8'h01, 8'h01);
        check(rx[0][15] == 0, "1: status word: not attached yet");
        op(8'h00, 8'h00);
        check(rx[0][15] == 1 && rx[0][14] == 1, "1: status word: attached, reader on");

        // 2. 01 71: E0 01 02 71 74, written as 01E0 7102 0074
        wr573(16'h01e0); wr573(16'h7102); wr573(16'h0074);
        check(st == 2'd1, "2: MCU status 1 (request out)");
        op(8'h00, 8'h00);
        check(rx[0][13] == 1 && rx[0][7:0] == 8'd1, "2: HPS sees waiting, req_seq 1");
        tx[0] = 16'h006f; tx[1] = 16'h0600; for (i = 2; i < 7; i = i + 1) tx[i] = 0; ntx = 7; spi;
        check(rx[2] == 16'd5 && rx[3] == 16'd1, "2: GETREQ: 5 bytes, seq 1");
        check(rx[4] == 16'h01e0 && rx[5] == 16'h7102 && rx[6] == 16'h0074, "2: GETREQ: the bytes");

        // 6. a short PUTRESP: nothing
        tx[0] = 16'h006f; tx[1] = 16'h0700; tx[2] = 16'd8; tx[3] = 16'd1; tx[4] = 16'h00e0; ntx = 5; spi;
        check(irdy == 0 && st == 2'd1, "6: cut-short PUTRESP commits nothing");

        // 3. E0 00 05 01 01 00 00 07
        tx[0] = 16'h006f; tx[1] = 16'h0700; tx[2] = 16'd8; tx[3] = 16'd1;
        tx[4] = 16'h00e0; tx[5] = 16'h0105; tx[6] = 16'h0001; tx[7] = 16'h0700; ntx = 8; spi;
        check(irdy == 1 && st == 2'd0 && rdata == 16'h00e0, "3: response: first word 00E0, IRDY");
        clr573; check(rdata == 16'h0105 && st == 2'd2, "3: word 1");
        clr573; check(rdata == 16'h0001, "3: word 2");
        clr573; check(rdata == 16'h0700, "3: word 3");
        clr573; check(irdy == 0 && st == 2'd0, "3: done");

        // 4. sense
        op(8'h02, 8'h00); repeat (2) @(posedge clk);
        check(sense == 0, "4: SENSE 0 -> bit 3 low");

        // 5. a card byte: select port 0, exchange 01 -> card answers A5
        op(8'h03, 8'hfb);
        op(8'h04, 8'h00);
        tx[0] = 16'h006f; tx[1] = 16'h0501; tx[2] = 16'd40; ntx = 3; spi;
        for (i = 0; i < 200 && !rx[0][11]; i = i + 1) begin op(8'h00, 8'h00); #2000; end
        check(rx[0][11] == 1 && rx[0][10:9] == 2'd0, "5: XFER done, result 0");
        check(rx[1][7:0] == 8'ha5 && rx[1][15:12] == 4'd1, "5: the card's byte, xfer_cnt 1");
        check(in_byte == 8'h01, "5: the card got the command byte");

        if (fails) $display("RESULT: FAIL (s573_wio, %0d of %0d checks)", fails, checks);
        else       $display("RESULT: PASS (s573_wio, %0d checks)", checks);
        $finish;
    end
endmodule
