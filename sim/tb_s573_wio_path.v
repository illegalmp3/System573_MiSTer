`timescale 1ns/1ps
// tb_s573_wio_path -- the White I/O path end to end in the fabric: the 573 writes
// a JVS packet into s573_jvs_mcu exactly as ddr4m's send routine does, the HPS
// (this bench, speaking the EXT_BUS word protocol of tb_s573_hps_ext) reads it
// through CMD_573_WIO, answers, and the 573 reads the answer back; then one card
// byte goes out through CMD_573_WIO op 3 and s573_wio_snac to a card on the pins.
module tb_s573_wio_path;
    reg clk = 0, rst = 1;
    always #14.76 clk = ~clk;

    // ---- EXT_BUS (HPS side driven here) ----
    reg [15:0] tb_din = 0; reg tb_strobe = 0, tb_enable = 0;
    wire [35:0] EXT_BUS;
    assign EXT_BUS[31:16] = tb_din;
    assign EXT_BUS[33] = tb_strobe;
    assign EXT_BUS[34] = tb_enable;
    assign EXT_BUS[35] = 1'b0;
    wire [15:0] dut_dout = EXT_BUS[15:0];

    // ---- wiring as emu.sv does it ----
    wire w_req_ready; wire [8:0] w_req_len; wire [7:0] w_req_seq, w_req_raddr; wire [15:0] w_req_rdata;
    wire w_resp_we, w_resp_commit; wire [7:0] w_resp_waddr, w_resp_seq; wire [15:0] w_resp_wdata; wire [8:0] w_resp_len;
    wire s_start, s_port; wire [1:0] s_op, s_mode; wire [7:0] s_tx, s_rx; wire s_busy, s_ack, s_err; wire [1:0] w_flags;
    wire hb, ds, di, eo; wire [15:0] cf, pw, cb; wire [8:0] pa; wire [7:0] sta; wire [6:0] sga;

    s573_hps_ext ext (.clk_sys(clk), .rst(rst), .EXT_BUS(EXT_BUS), .heartbeat(hb),
        .fab_pcm_rd(16'd0), .hps_pcm_wr(pw), .fab_pos_lo(16'd0), .cfg_epoch(16'd0), .hps_cons_bytes(cb),
        .mp3_start(25'd0), .mp3_end(25'd0), .mp3_key1(16'd0), .mp3_key2(16'd0), .mp3_key3(16'd0),
        .cfg_ddrsbm(1'b0), .fpga_ctrl_en(3'd0), .gain_ll(20'd0), .gain_rr(20'd0), .gain_stb(1'b0),
        .status_flags(16'd0), .underrun_cnt(16'd0), .buf_level(16'd0), .stage_dbg(48'd0), .sec_dbg(64'd0),
        .sec_size_dbg(16'd0), .sec_rd_dbg(48'd0), .sec_emit_dbg(32'd0), .sec_cnt_dbg(16'd0),
        .pcprof_addr(pa), .pcprof_data(16'd0), .pcprof_samples(16'd0), .pcprof_ram_hi(16'd0),
        .pcprof_bios(16'd0), .pcprof_other(16'd0), .prof_dbg(112'd0), .profg_dbg(112'd0),
        .dio_dbg(48'd0), .fliphist_dbg(48'd0), .sec_trace_addr(sta), .sec_trace_data(16'd0),
        .sec_trace_count(16'd0), .stage_trace_addr(sga), .stage_trace_data(16'd0), .stage_trace_count(8'd0),
        .wio_req_ready(w_req_ready), .wio_req_len(w_req_len), .wio_req_seq(w_req_seq),
        .wio_req_raddr(w_req_raddr), .wio_req_rdata(w_req_rdata),
        .wio_resp_we(w_resp_we), .wio_resp_waddr(w_resp_waddr), .wio_resp_wdata(w_resp_wdata),
        .wio_resp_commit(w_resp_commit), .wio_resp_len(w_resp_len), .wio_resp_seq(w_resp_seq),
        .wio_snac_start(s_start), .wio_snac_op(s_op), .wio_snac_port(s_port), .wio_snac_mode(s_mode),
        .wio_snac_tx(s_tx), .wio_snac_busy(s_busy), .wio_snac_rx(s_rx), .wio_snac_ack(s_ack),
        .wio_snac_err(s_err), .wio_flags(w_flags),
        .ctrl_flags(cf), .dec_frame_sync(ds), .dec_frame_idle(di), .evt_ovf(eo));

    reg wr = 0, clr = 0; reg [15:0] wd = 0;
    wire [15:0] rd; wire irdy, drdy; wire [1:0] status, err;
    s573_jvs_mcu mcu (.clk(clk), .rst(rst), .mcu_rst_n(1'b1), .wr_data(wr), .wdata(wd), .clr_irdy(clr),
        .rdata(rd), .irdy(irdy), .drdy(drdy), .status(status), .err(err),
        .req_ready(w_req_ready), .req_len(w_req_len), .req_seq(w_req_seq), .req_raddr(w_req_raddr),
        .req_rdata(w_req_rdata), .resp_we(w_resp_we), .resp_waddr(w_resp_waddr), .resp_wdata(w_resp_wdata),
        .resp_commit(w_resp_commit), .resp_len(w_resp_len), .resp_seq(w_resp_seq));

    wire [1:0] sel_n; wire sclk, cmd; reg dat = 1, ack_n = 1;
    s573_wio_snac snac (.clk(clk), .rst(rst), .en(1'b1), .start(s_start), .op(s_op), .port(s_port),
        .ack_mode(s_mode), .tx(s_tx), .busy(s_busy), .rx(s_rx), .ack_seen(s_ack), .line_err(s_err),
        .sel_n(sel_n), .clk_o(sclk), .cmd_o(cmd), .dat_i(dat), .ack_n_i(ack_n));

    integer errors = 0;
    task chk(input c, input [8*80-1:0] what); begin
        if (!c) begin $display("FAIL: %0s", what); errors = errors + 1; end else $display("  ok  %0s", what);
    end endtask

    // ---- SPI word primitives (tb_s573_hps_ext timing) ----
    task spi_begin; begin @(negedge clk); tb_enable = 1; @(negedge clk); end endtask
    task spi_end;   begin @(negedge clk); tb_enable = 0; repeat (2) @(negedge clk); end endtask
    task spi_word(input [15:0] din, output [15:0] dout); begin
        @(negedge clk); tb_din = din; tb_strobe = 1; @(negedge clk); tb_strobe = 0;
        repeat (6) @(negedge clk); dout = dut_dout;
    end endtask

    // ---- the 573 sends E0 01 03 71 ... (status request), as 0x800ac924 ----
    reg [15:0] r0, r1, r2;
    reg [7:0] q [0:15];
    integer k, n;
    initial begin
        repeat (4) @(posedge clk); rst = 0; repeat (4) @(posedge clk);

        spi_begin; spi_word(16'h006f, r0); spi_word(16'h4003, r1); spi_end;   // op 4 FLAGS = 3
        chk(w_flags == 2'b11, "op 4 sets the flags");
        chk(r0[15] == 1'b0, "no request pending");

        // E0 01 02 71 74 -> words 01e0 7102 0074
        @(negedge clk); wr = 1; wd = 16'h01e0; @(negedge clk); wr = 0; while (drdy) @(negedge clk);
        @(negedge clk); wr = 1; wd = 16'h7102; @(negedge clk); wr = 0; while (drdy) @(negedge clk);
        @(negedge clk); wr = 1; wd = 16'h0074; @(negedge clk); wr = 0; while (drdy) @(negedge clk);
        repeat (4) @(negedge clk);
        chk(status == 2'd1, "MCU busy: request out");

        spi_begin; spi_word(16'h006f, r0); chk(r0[15] && r0[8:0] == 9'd5, "word0: request ready, 5 bytes");
        spi_word(16'h1000, r1); chk(r1[7:0] == w_req_seq, "word1: seq");
        spi_word(16'h0000, r1); spi_word(16'h0000, r2);
        chk(r1 == 16'h01e0 && r2 == 16'h7102, "request words 0/1");
        spi_word(16'h0000, r1); chk(r1[7:0] == 8'h74, "request word 2 (checksum)");
        spi_end;

        // answer E0 00 05 01 01 00 01 08 (status 0x0001): bytes e0 00 05 01 01 00 01 08
        spi_begin; spi_word(16'h006f, r0); spi_word(16'h2008, r1); spi_word({8'd0, w_req_seq}, r1);
        spi_word(16'h00e0, r1); spi_word(16'h0105, r1); spi_word(16'h0001, r1); spi_word(16'h0801, r1);
        spi_end;
        repeat (8) @(negedge clk);
        chk(irdy && rd == 16'h00e0, "573 sees JVSIRDY, first word 00e0");
        for (k = 0; k < 4; k = k + 1) begin
            q[2*k] = rd[7:0]; q[2*k+1] = rd[15:8];
            @(negedge clk); clr = 1; @(negedge clk); clr = 0;
            n = 0; while (!irdy && n < 400) begin @(negedge clk); n = n + 1; end
        end
        chk(q[2] == 8'h05 && q[3] == 8'h01 && q[4] == 8'h01 && q[5] == 8'h00 && q[6] == 8'h01 && q[7] == 8'h08,
            "573 reads 05 01 01 00 01 08");
        repeat (100) @(negedge clk);
        chk(status == 2'd0 && !irdy, "MCU idle again");

        // ---- one card byte through op 3: SELECT port 0, XFER 0x81 (card ACKs) ----
        spi_begin; spi_word(16'h006f, r0); spi_word(16'h3000, r1); spi_word(16'h0000, r1); spi_end;
        n = 0; r0 = 16'h4000; while (r0[14] && n < 100) begin
            #(5000); spi_begin; spi_word(16'h006f, r0); spi_end; n = n + 1; end
        chk(sel_n == 2'b10, "SELECT port 0");
        fork
            begin : card                      // ACK 12 us after the 8th rising edge
                repeat (8) @(posedge sclk);
                #(12000); ack_n = 0; #(3000); ack_n = 1;
            end
            begin
                spi_begin; spi_word(16'h006f, r0); spi_word(16'h3000, r1);
                spi_word({1'b0, 2'd2, 2'd1, 3'd0, 8'h81}, r1); spi_end;
            end
        join
        n = 0; r0 = 16'h4000; while (r0[14] && n < 100) begin
            #(5000); spi_begin; spi_word(16'h006f, r0); spi_end; n = n + 1; end
        chk(r0[13] && !r0[12], "XFER done: ACK seen, no line error");
        spi_begin; spi_word(16'h006f, r0); spi_word(16'h0000, r1); spi_end;
        chk(r1[15:8] == 8'hff, "rx = FFh (DAT idle high: the reply to 81h is Hi-Z)");

        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
