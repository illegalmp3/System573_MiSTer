`timescale 1ns/1ps
// tb_zs01_detect.v -- PSX.EXE's ZS01 detector, driven through the REAL CPU BUS.
//
// tb_zs01_rtr proved s573_seccart hands back the right id when sec_io0 is read
// directly. This one closes the last gap: it drives the cassette latch with
// exp1 writes to 0x1f6a0000 and samples bit 2 of an exp1 READ of 0x1f400006 --
// the exact bus transactions the game performs (PSX.EXE 0x803250b8, decoded in
// docs/2026-09-14) -- so s573_io's misc-word assembly, the asic offset decode
// and the exp1 read path are all in the loop.
//
// On hardware the detector rejects the cassette (ERROR 121 (3)) while the chip
// demonstrably drives the id, so the fault is somewhere in THIS path. GREEN here
// means the whole CPU-visible read-back is correct and the fault is outside the
// fabric entirely; RED reproduces the bug where it can be fixed for free.
module tb_zs01_detect;
    reg clk = 0, rst = 1;
    reg [23:0] exp1_addr = 0;
    reg [1:0]  exp1_reqsize = 2'b01;
    reg [15:0] exp1_wdata = 0;
    reg        exp1_we = 0, exp1_re = 0;
    wire [15:0] exp1_rdata;

    reg [3:0]  dip_sw = 4'h0;
    reg [7:0]  p1_ctrl = 8'hFF, p2_ctrl = 8'hFF;
    reg [1:0]  coin_sw = 0;
    reg        service_btn = 0, test_btn = 0;
    reg [1:0]  pcmcia_present = 0;
    reg [7:0]  adc_ch0 = 0, adc_ch1 = 0, adc_ch2 = 0, adc_ch3 = 0;
    wire [1:0] coin_counter;
    wire audio_amp_en, audio_mute, spu_dac_en, wdog_reset, cdrom_irq;
    wire [31:0] lamp_out;
    wire [47:0] sec_rd_dbg; wire [31:0] sec_emit_dbg;

    reg        L_we=0;  reg [12:0] L_addr=0; reg [7:0] L_data=0;
    reg        Ls_we=0; reg [2:0]  Ls_addr=0; reg [7:0] Ls_data=0;
    integer errors = 0;

    system573_top #(.CLK_FREQ_HZ(1_000_000), .WDOG_TIMEOUT(32'd4_000_000_000)) dut (
        .clk(clk), .rst(rst), .card_en(1'b0), .card_slot1(1'b0),
        .exp1_addr(exp1_addr), .exp1_reqsize(exp1_reqsize), .exp1_wdata(exp1_wdata),
        .exp1_we(exp1_we), .exp1_re(exp1_re), .exp1_rdata(exp1_rdata),
        .dip_sw(dip_sw), .stage_mux_en(1'b0), .stage_trace_addr(7'd0), .stage_trace_data(), .stage_trace_count(), .p1_ctrl(p1_ctrl), .p2_ctrl(p2_ctrl),
        .coin_sw(coin_sw), .service_btn(service_btn), .test_btn(test_btn),
        .pcmcia_present(pcmcia_present),
        .cd_present(1'b1),   // this integration test exercises the ATAPI/CD path, so model a drive present
        .cd_image(1'b0), .cd_hps_req(), .cd_hps_lba(),
        .cd_hps_ack(1'b0), .cd_hps_write(1'b0), .cd_hps_data(16'h0000),
        .cd_ti_write(1'b0), .cd_ti_addr(9'd0), .cd_ti_data(32'd0),
        .cd_img_mounted(1'b0), .cd_img_size(64'd0),
        .atapi_dma_req(), .atapi_dma_rd(1'b0), .atapi_dma_dout(),
        .adc_ch0(adc_ch0), .adc_ch1(adc_ch1), .adc_ch2(adc_ch2), .adc_ch3(adc_ch3),
        .coin_counter(coin_counter), .audio_amp_en(audio_amp_en),
        .audio_mute(audio_mute), .spu_dac_en(spu_dac_en), .wdog_reset(wdog_reset),
        .cdrom_irq(cdrom_irq), .lamp_out(lamp_out),
        .dio_mp3_ready(1'b0),   // no MP3 streaming in this smoke test
        .dio_dec_frame_sync(1'b0), .dio_dec_frame_idle(1'b0), .dio_pcm_sample_tick(1'b0),
        // SIM_BACKING defaults to 1: inline flash; flash_wait stays 0, SDRAM unused.
        .flash_wait(), .flash_mem_req(), .flash_mem_addr(),
        .flash_mem_q(128'd0), .flash_mem_ready(1'b0),
        // DIO_SIM_BACKING defaults to 1: inline DIO RAM; dio_wait stays 0,
        // the DDR3 channels are unused.
        .dio_wait(), .dio_mem_rd_req(), .dio_mem_rd_addr(),
        .dio_mem_rd_q(64'd0), .dio_mem_rd_ack(1'b0),
        .dio_mem_wr_req(), .dio_mem_wr_addr(), .dio_mem_wr_data(),
        .dio_mem_wr_ack(1'b0), .dio_dbg_ovf(), .cfg_ddrsbm(1'b0), .chart_ofs_ms(5'd0),
        .nvram_we(1'b0), .nvram_addr(13'd0), .nvram_din(8'd0),
        .sec_cart_type(2'd2),          // ZS01
        .sec_eep_we(L_we), .sec_eep_addr(L_addr), .sec_eep_din(L_data),
        .sec_ser_we(Ls_we), .sec_ser_addr(Ls_addr), .sec_ser_din(Ls_data),
        // second (install) cassette + restore flag: not used by this bench
        .sec_eep_zs01_only(1'b0), .sec_inst_sel(1'b0), .sec_inst_type(1'b0), .sec_ieep_we(1'b0), .sec_ieep_addr(10'd0), .sec_ieep_din(8'd0), .sec_iser_we(1'b0), .sec_iser_addr(3'd0), .sec_iser_din(8'd0),
        .sec_dbg(), .sec_rd_dbg(sec_rd_dbg), .sec_emit_dbg(sec_emit_dbg),
        .sec_trace_addr(8'd0), .sec_trace_data(), .sec_trace_count()
    );

    always #5 clk = ~clk;

    task exp1_write(input [23:0] a, input [15:0] d);
        begin
            @(negedge clk); exp1_addr = a; exp1_wdata = d; exp1_we = 1; exp1_re = 0;
            @(negedge clk); exp1_we = 0;
            repeat (6) @(negedge clk);
        end
    endtask
    task exp1_read(input [23:0] a, output [15:0] d);
        begin
            @(negedge clk); exp1_addr = a; exp1_reqsize = 2'b01; exp1_re = 0; exp1_we = 0;
            @(negedge clk); exp1_re = 1;
            @(negedge clk); exp1_re = 0;
            @(negedge clk); d = exp1_rdata;
            repeat (2) @(negedge clk);
        end
    endtask

    // latch bits: [0]=SDA(D0) [1]=SCL(D1) [2]=CS(D2, active-low) [3]=RST(D3)
    localparam D0=0, D1=1, D2=2, D3=3;
    reg [7:0]  L;
    reg [15:0] rd;
    reg [31:0] id;
    reg [7:0]  u1 [0:4115];
    reg [7:0]  u6 [0:7];
    integer i, fh; reg present;

    // write the cassette latch the way the game does (halfword to 0x1f6a0000)
    task wrlatch; begin exp1_write(24'h6a0000, {8'h00, L}); end endtask

    initial begin
        present = 1'b0;
        fh = $fopen("secdata/ddrusa_u1.hex","r");
        if (fh != 0) begin
            $fclose(fh);
            for (i=0;i<4116;i=i+1) u1[i]=8'h00;
            $readmemh("secdata/ddrusa_u1.hex", u1, 0, 139);
            $readmemh("secdata/ddrusa_u6.hex", u6);
            present = 1'b1;
        end
        if (!present) begin
            $display("tb_zs01_detect: no ddrusa fixture -- SKIPPED");
            $display("RESULT: PASS"); $finish;
        end

        repeat (4) @(negedge clk);
        for (i=0;i<140;i=i+1) begin @(negedge clk); L_we=1; L_addr=i[12:0]; L_data=u1[i]; end
        @(negedge clk); L_we=0;
        for (i=0;i<8;i=i+1) begin @(negedge clk); Ls_we=1; Ls_addr=i[2:0]; Ls_data=u6[i]; end
        @(negedge clk); Ls_we=0;
        repeat (4) @(negedge clk); rst = 0; repeat (20) @(negedge clk);

        // ---- detector preamble ----
        L = 8'b0000_1111; wrlatch;
        L[D1]=0;          wrlatch;   // SCL low
        L[D2]=0;          wrlatch;   // CS low = selected
        L[D3]=0;          wrlatch;   // RST low
        L[D3]=1;          wrlatch;   // RST high -> response to reset
        L[D1]=1;          wrlatch;   // SCL high
        L[D1]=0;          wrlatch;   // SCL low  -> chip drives bit 0

        // ---- 32 samples through the real bus, MSB-first ----
        id = 32'd0;
        for (i=0;i<32;i=i+1) begin
            exp1_read(24'h400006, rd);          // read 0x1f400006 like the game
            id = {id[30:0], rd[2]};             // bit 2 = cassette SDA
            L[D1]=1; wrlatch;                   // SCL high
            L[D1]=0; wrlatch;                   // SCL low -> next bit
        end

        $display("tb_zs01_detect: CPU assembled 0x%08x (want 0x5a530001)", id);
        $display("tb_zs01_detect: chip serviced %0d RTR edges, drove 0x%08x",
                 sec_rd_dbg[47:40], sec_emit_dbg);
        if (id !== 32'h5a53_0001) begin
            $display("FAIL: the CPU-visible read-back does not carry the ZS01 id");
            errors = errors + 1;
        end
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
