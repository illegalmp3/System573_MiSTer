`timescale 1ns/1ps
// Testbench for the SECOND (install) cassette: s573_cass_pack.v (the index-5 .cas
// pack splitter, straight from emu.sv's wiring) feeding s573_seccart.v, loaded with
// the REAL cassette dumps of two two-cassette titles and driven through the D0-D7
// latch the way the BIOS / installer do (the same waveforms tb_s573_seccart.v uses).
//
//  Fixtures (sim/gen_secdata.sh, from dumps/mame573/<title>.zip via the SAME
//  tools -- tools/stage_zs01_u1.py, tools/make_cas_pack.py -- that stage the T7):
//    secdata/ddr4m_game_u1.hex   gca33aa.u1 padded to 4116 B (ZS01 game cassette)
//    secdata/ddr4m_cas.hex       {gca33aa.u6, gea33aa.u6, gea33aa.u1} = 564 B
//                                (X76F041 install cassette)            -- cassxzi
//    secdata/ddr3ma_game_u1.hex  gn887aa.u1, 132 B (X76F100 game cassette)
//    secdata/ddr3ma_cas.hex      {gn887aa.u6, ge887aa.u6, ge887aa.u1} = 148 B
//                                (X76F100 install cassette)            -- cassyyi
//
//  Part 0  a plain 8-byte .u6 through the pack splitter: all 8 bytes go to the game
//          serial, nothing to the install ports, inst_present stays 0 -- the
//          single-cassette titles are byte-for-byte unchanged.
//  Part A  ddr4m, launcher order (.u1 then .cas), then a ZS01 NVRAM "restore"
//          (load_eep_zs01_only) over the low addresses:
//          A1 inst_present=1 / inst_type=1 (X76F041) latched at download end;
//          A2 install in the slot: X76F041 RTR 19 55 AA 55; the REAL gea33aa config
//             password is accepted (wrong one NAKed); data[0..3] read back are the
//             REAL install-image bytes (so the restore did NOT overwrite them, and a
//             ZS01 image did not wrap over them); DS2401 ROM == gea33aa.u6;
//          A3 game in the slot: ZS01 RTR 5A 53 00 01; NO 1-Wire presence on I6 --
//             psx-spx "ZS01 cartridge variants": the game cassette's DS2401 hangs
//             off a ZS01 GPIO, not D4/I6 (read through ZS01 address 0xFD instead,
//             573in1 ZS01_ADDR_DS2401_ID; tb_zs01 covers that path). Was "ROM ==
//             gca33aa.u6", modelled on MAME k573cass.cpp, which exposes it on D4;
//             an X76-style RTR read does NOT return 19 55 AA 55 (the X76F041 really
//             is deselected).
//  Part B  ddr4m again, REVERSED file order (.cas first, then the 4116-B .u1 whose
//          low 10 address bits wrap over eeprom041): the install cassette must still
//          authenticate and read back its own bytes (the inst041_loaded guard).
//  Part C  ddr3ma (X76F100 + X76F100): install selected -> RTR 19 00 AA 55, the
//          install read password opens block 0 and the bytes are the install image's;
//          the game password is NAKed. Game selected -> the mirror image. DS2401 ROM
//          follows the selection. (The two read passwords are asserted to differ.)
//
// DS_CLK_HZ = 1_000_000 -> 1 clk == 1 us in the DS2401 time base.
module tb_s573_seccart_dual;
    reg clk = 0, rst = 1;
    always #500 clk = ~clk;
    integer errors = 0, i, k;

    // -------------------------------------------------------------------------
    // DUT A/B (ddr4m): cart_type 2 (ZS01 game). Two instances so Part B can load in
    // the reverse order from a clean chip.
    // -------------------------------------------------------------------------
    reg        latch_we_a = 0;  reg [7:0] dla = 8'b0000_0101;  reg io0_a = 0;
    reg        latch_we_b = 0;  reg [7:0] dlb = 8'b0000_0101;  reg io0_b = 0;
    reg        latch_we_c = 0;  reg [7:0] dlc = 8'b0000_0101;
    reg        sel_a = 0, sel_b = 0, sel_c = 0;
    // .u1 (game EEPROM) load ports
    reg        ea_we = 0; reg [12:0] ea_addr = 0; reg [7:0] ea_data = 0; reg ea_zs = 0;
    reg        eb_we = 0; reg [12:0] eb_addr = 0; reg [7:0] eb_data = 0;
    reg        ec_we = 0; reg [12:0] ec_addr = 0; reg [7:0] ec_data = 0;
    // pack splitters (one per DUT), fed like emu.sv feeds them from the loader
    reg        pa_dl = 0, pa_we = 0; reg [9:0] pa_addr = 0, pa_max = 0; reg [7:0] pa_data = 0;
    reg        pb_dl = 0, pb_we = 0; reg [9:0] pb_addr = 0, pb_max = 0; reg [7:0] pb_data = 0;
    reg        pc_dl = 0, pc_we = 0; reg [9:0] pc_addr = 0, pc_max = 0; reg [7:0] pc_data = 0;
    wire       a_ser_we, a_iser_we, a_ieep_we, a_present, a_type;
    wire [2:0] a_ser_addr, a_iser_addr; wire [7:0] a_ser_d, a_iser_d, a_ieep_d; wire [9:0] a_ieep_addr;
    wire       b_ser_we, b_iser_we, b_ieep_we, b_present, b_type;
    wire [2:0] b_ser_addr, b_iser_addr; wire [7:0] b_ser_d, b_iser_d, b_ieep_d; wire [9:0] b_ieep_addr;
    wire       c_ser_we, c_iser_we, c_ieep_we, c_present, c_type;
    wire [2:0] c_ser_addr, c_iser_addr; wire [7:0] c_ser_d, c_iser_d, c_ieep_d; wire [9:0] c_ieep_addr;

    s573_cass_pack pk_a (.clk(clk), .download(pa_dl), .byte_we(pa_we), .byte_addr(pa_addr), .byte_data(pa_data), .max_addr(pa_max),
        .ser_we(a_ser_we), .ser_addr(a_ser_addr), .ser_data(a_ser_d), .iser_we(a_iser_we), .iser_addr(a_iser_addr), .iser_data(a_iser_d),
        .ieep_we(a_ieep_we), .ieep_addr(a_ieep_addr), .ieep_data(a_ieep_d), .inst_present(a_present), .inst_type(a_type));
    s573_cass_pack pk_b (.clk(clk), .download(pb_dl), .byte_we(pb_we), .byte_addr(pb_addr), .byte_data(pb_data), .max_addr(pb_max),
        .ser_we(b_ser_we), .ser_addr(b_ser_addr), .ser_data(b_ser_d), .iser_we(b_iser_we), .iser_addr(b_iser_addr), .iser_data(b_iser_d),
        .ieep_we(b_ieep_we), .ieep_addr(b_ieep_addr), .ieep_data(b_ieep_d), .inst_present(b_present), .inst_type(b_type));
    s573_cass_pack pk_c (.clk(clk), .download(pc_dl), .byte_we(pc_we), .byte_addr(pc_addr), .byte_data(pc_data), .max_addr(pc_max),
        .ser_we(c_ser_we), .ser_addr(c_ser_addr), .ser_data(c_ser_d), .iser_we(c_iser_we), .iser_addr(c_iser_addr), .iser_data(c_iser_d),
        .ieep_we(c_ieep_we), .ieep_addr(c_ieep_addr), .ieep_data(c_ieep_d), .inst_present(c_present), .inst_type(c_type));

    wire io0_out_a, io0_out_b, io0_out_c; wire [7:0] in_a, in_b, in_c;
    wire [63:0] dbg_a, dbg_b, dbg_c;
    s573_seccart #(.DS_CLK_HZ(1_000_000)) dut_a (
        .clk(clk), .rst(rst), .cart_type(2'd2),
        .latch_we(latch_we_a), .d_latch(dla), .io0_dir(io0_a),
        .load_eep_we(ea_we), .load_eep_addr(ea_addr), .load_eep_data(ea_data),
        .load_ser_we(a_ser_we), .load_ser_addr(a_ser_addr), .load_ser_data(a_ser_d),
        .load_eep_zs01_only(ea_zs),
        .inst_sel(sel_a), .inst_type(a_type),
        .load_ieep_we(a_ieep_we), .load_ieep_addr(a_ieep_addr), .load_ieep_data(a_ieep_d),
        .load_iser_we(a_iser_we), .load_iser_addr(a_iser_addr), .load_iser_data(a_iser_d),
        .sec_dbg(dbg_a), .sec_cs_n(), .sec_rst_line(), .sec_scl_line(), .sec_sda_line(), .sec_ds_line(),
        .sec_zs01_state(), .sec_rtr_edges(), .sec_in_rtr(), .sec_rtr_emit(),
        .sec_io0(io0_out_a), .sec_in(in_a), .sec_drdy(), .sec_irdy(),
        .zs01_dump_addr(8'd0), .zs01_dump_data(), .zs01_nv_wr());
    s573_seccart #(.DS_CLK_HZ(1_000_000)) dut_b (
        .clk(clk), .rst(rst), .cart_type(2'd2),
        .latch_we(latch_we_b), .d_latch(dlb), .io0_dir(io0_b),
        .load_eep_we(eb_we), .load_eep_addr(eb_addr), .load_eep_data(eb_data),
        .load_ser_we(b_ser_we), .load_ser_addr(b_ser_addr), .load_ser_data(b_ser_d),
        .load_eep_zs01_only(1'b0),
        .inst_sel(sel_b), .inst_type(b_type),
        .load_ieep_we(b_ieep_we), .load_ieep_addr(b_ieep_addr), .load_ieep_data(b_ieep_d),
        .load_iser_we(b_iser_we), .load_iser_addr(b_iser_addr), .load_iser_data(b_iser_d),
        .sec_dbg(dbg_b), .sec_cs_n(), .sec_rst_line(), .sec_scl_line(), .sec_sda_line(), .sec_ds_line(),
        .sec_zs01_state(), .sec_rtr_edges(), .sec_in_rtr(), .sec_rtr_emit(),
        .sec_io0(io0_out_b), .sec_in(in_b), .sec_drdy(), .sec_irdy(),
        .zs01_dump_addr(8'd0), .zs01_dump_data(), .zs01_nv_wr());
    // DUT C (ddr3ma): cart_type 0 (X76F100 game)
    s573_seccart #(.DS_CLK_HZ(1_000_000)) dut_c (
        .clk(clk), .rst(rst), .cart_type(2'd0),
        .latch_we(latch_we_c), .d_latch(dlc), .io0_dir(1'b1),   // X76-only DUT: SDA output enabled (host_sda)
        .load_eep_we(ec_we), .load_eep_addr(ec_addr), .load_eep_data(ec_data),
        .load_ser_we(c_ser_we), .load_ser_addr(c_ser_addr), .load_ser_data(c_ser_d),
        .load_eep_zs01_only(1'b0),
        .inst_sel(sel_c), .inst_type(c_type),
        .load_ieep_we(c_ieep_we), .load_ieep_addr(c_ieep_addr), .load_ieep_data(c_ieep_d),
        .load_iser_we(c_iser_we), .load_iser_addr(c_iser_addr), .load_iser_data(c_iser_d),
        .sec_dbg(dbg_c), .sec_cs_n(), .sec_rst_line(), .sec_scl_line(), .sec_sda_line(), .sec_ds_line(),
        .sec_zs01_state(), .sec_rtr_edges(), .sec_in_rtr(), .sec_rtr_emit(),
        .sec_io0(io0_out_c), .sec_in(in_c), .sec_drdy(), .sec_irdy(),
        .zs01_dump_addr(8'd0), .zs01_dump_data(), .zs01_nv_wr());

    // Part 0: a lone splitter fed an 8-byte .u6, counting where the bytes went
    reg        p0_dl = 0, p0_we = 0; reg [9:0] p0_addr = 0, p0_max = 0; reg [7:0] p0_data = 0;
    wire       p0_ser_we, p0_iser_we, p0_ieep_we, p0_present, p0_type;
    s573_cass_pack pk_0 (.clk(clk), .download(p0_dl), .byte_we(p0_we), .byte_addr(p0_addr), .byte_data(p0_data), .max_addr(p0_max),
        .ser_we(p0_ser_we), .ser_addr(), .ser_data(), .iser_we(p0_iser_we), .iser_addr(), .iser_data(),
        .ieep_we(p0_ieep_we), .ieep_addr(), .ieep_data(), .inst_present(p0_present), .inst_type(p0_type));
    integer n_ser = 0, n_iser = 0, n_ieep = 0;
    always @(posedge clk) begin
        if (p0_ser_we)  n_ser  = n_ser  + 1;
        if (p0_iser_we) n_iser = n_iser + 1;
        if (p0_ieep_we) n_ieep = n_ieep + 1;
    end

    // -------------------------------------------------------------------------
    // fixtures
    // -------------------------------------------------------------------------
    reg [7:0] d4_u1  [0:4115];   // ddr4m game .u1 (padded ZS01)
    reg [7:0] d4_cas [0:563];    // ddr4m .cas
    reg [7:0] d3_u1  [0:131];    // ddr3ma game .u1 (X76F100)
    reg [7:0] d3_cas [0:147];    // ddr3ma .cas
    reg d4_present = 0, d3_present = 0;
    integer fh;

    // generic byte-stream "downloads" into a splitter: (dl, we, addr, data, max)
    task pack_byte_a(input [9:0] a, input [7:0] v); begin
        @(negedge clk); pa_addr=a; pa_data=v; pa_we=1; if (a > pa_max) pa_max=a;
        @(negedge clk); pa_we=0; end endtask
    task pack_byte_b(input [9:0] a, input [7:0] v); begin
        @(negedge clk); pb_addr=a; pb_data=v; pb_we=1; if (a > pb_max) pb_max=a;
        @(negedge clk); pb_we=0; end endtask
    task pack_byte_c(input [9:0] a, input [7:0] v); begin
        @(negedge clk); pc_addr=a; pc_data=v; pc_we=1; if (a > pc_max) pc_max=a;
        @(negedge clk); pc_we=0; end endtask
    task eep_a(input [12:0] a, input [7:0] v, input zs); begin
        @(negedge clk); ea_addr=a; ea_data=v; ea_we=1; ea_zs=zs;
        @(negedge clk); ea_we=0; ea_zs=0; end endtask
    task eep_b(input [12:0] a, input [7:0] v); begin
        @(negedge clk); eb_addr=a; eb_data=v; eb_we=1;
        @(negedge clk); eb_we=0; end endtask
    task eep_c(input [12:0] a, input [7:0] v); begin
        @(negedge clk); ec_addr=a; ec_data=v; ec_we=1;
        @(negedge clk); ec_we=0; end endtask

    // -------------------------------------------------------------------------
    // bus primitives -- the same waveforms as tb_s573_seccart.v, parameterized on
    // which DUT's latch they drive (1 = A, 2 = B, 3 = C)
    // -------------------------------------------------------------------------
    task tk; begin repeat (3) @(posedge clk); end endtask
    task wait_us(input integer n); begin repeat (n) @(posedge clk); end endtask
    reg [7:0] dl_cur;
    task put(input integer w, input integer b, input v); begin
        case (w) 1: dla[b]=v; 2: dlb[b]=v; default: dlc[b]=v; endcase
        tk;
    end endtask
    function io0(input integer w); io0 = (w==1) ? io0_out_a : (w==2) ? io0_out_b : io0_out_c; endfunction
    function ds_in(input integer w); ds_in = (w==1) ? in_a[0] : (w==2) ? in_b[0] : in_c[0]; endfunction
    // The seccart registers the latch only on latch_we; hold it high for the whole
    // bit-bang like the other cassette benches (Part 1/2/3 of tb_s573_seccart.v).
    task latch_on(input integer w); begin case (w) 1: latch_we_a=1; 2: latch_we_b=1; default: latch_we_c=1; endcase end endtask

    // ---- X76 (F041/F100) over D0..D3: SDA=D0, SCL=D1, CS=D2, RST=D3 ----
    task x_start(input integer w); begin put(w,1,0); put(w,0,1); put(w,1,1); put(w,0,0); put(w,1,0); end endtask
    task x_stop (input integer w); begin put(w,1,0); put(w,0,0); put(w,1,1); put(w,0,1); end endtask
    task x_send(input integer w, input [7:0] d, output ack);
        integer j; begin
            for (j=7;j>=0;j=j-1) begin put(w,1,0); put(w,0,d[j]); put(w,1,1); end
            put(w,1,0); put(w,0,1); put(w,1,1); ack=io0(w); put(w,1,0);
        end
    endtask
    task x_read(input integer w, input ack_bit, output [7:0] d);
        integer j; begin
            d=8'h00;
            for (j=7;j>=0;j=j-1) begin put(w,1,0); put(w,0,1); put(w,1,1); d[j]=io0(w); end
            put(w,1,0); put(w,0,ack_bit); put(w,1,1); put(w,1,0); put(w,0,1);
        end
    endtask
    task x_rtr(input integer w, output [7:0] d);    // X76 RTR: LSB-first on falling SCL
        integer j; begin
            d=8'h00;
            for (j=0;j<8;j=j+1) begin put(w,1,1); put(w,1,0); d[j]=io0(w); end
        end
    endtask
    // The Konami X76 driver drives SDA from latch D0 with the 0x1f500000 bit-6 output
    // enable SET (s573_seccart host_sda: pin 28 = bit6 ? D0 : released). Enable it for
    // the X76 transaction; the ZS01 tasks below set io0_a/io0_b per bit themselves.
    task x_select(input integer w);   begin
        case (w) 1: io0_a=1'b1; 2: io0_b=1'b1; default: ; endcase
        put(w,2,0); put(w,3,1); end endtask   // CS low, RST high -> RTR
    task x_deselect(input integer w); begin put(w,2,1); put(w,3,0); end endtask
    // X76F041 config-register read gated by the config password (image [20:27])
    task f041_cfg_auth(input integer w, input [63:0] pw, output ack);
        integer j; reg a; begin
            x_start(w);
            x_send(w, 8'h80, a);        // CONFIGURATION
            x_send(w, 8'h60, a);        // READ CONFIG REGISTERS (needs cpw)
            for (j=0;j<8;j=j+1) x_send(w, pw[8*(7-j) +: 8], a);
            x_send(w, 8'hc0, ack);      // verify
        end
    endtask
    // X76F100 installer framing (tb_x76f100_hypbbc2p.v, disassembled 0x8003854c):
    // START, cmd, 8 pw bytes, REPEATED START, 0x55 verify -> ack
    task f100_auth(input integer w, input [7:0] cmd, input [63:0] pw, output ack);
        integer j; reg a; begin
            x_start(w);
            x_send(w, cmd, a);
            for (j=0;j<8;j=j+1) x_send(w, pw[8*(7-j) +: 8], a);
            x_start(w);
            x_send(w, 8'h55, ack);
        end
    endtask

    // ---- DS2401 1-Wire master over D4, read I0 ----
    task ow_reset(input integer w); begin put(w,4,1); wait_us(500); put(w,4,0); wait_us(250); end endtask
    task ow_write_bit(input integer w, input b); integer low; begin
        low = b ? 6 : 50; put(w,4,1); wait_us(low); put(w,4,0); wait_us(75-low); end
    endtask
    task ow_read_bit(input integer w, output b); begin
        put(w,4,1); wait_us(4); put(w,4,0); wait_us(8); b=ds_in(w); wait_us(63); end
    endtask
    task ow_presence(input integer w, output p); begin    // reset pulse, sample at 70 us
        put(w,4,1); wait_us(500); put(w,4,0); wait_us(70); p = ~ds_in(w); wait_us(180); end
    endtask
    task ow_read_rom(input integer w, output [63:0] rom);
        integer j; reg bv; begin
            ow_reset(w);
            for (j=0;j<8;j=j+1) ow_write_bit(w, (8'h33 >> j) & 1'b1);
            rom = 64'd0;
            for (j=0;j<64;j=j+1) begin ow_read_bit(w, bv); rom[j]=bv; end
        end
    endtask
    // expected ROM for an 8-byte serial image s[0..7] (ds2401.v: file byte k -> rom[8*(7-k)+:8])
    function [63:0] exprom(input [63:0] s); exprom = s; endfunction

    // ---- ZS01 over CONTROL bit 6 (SDA, active-low) + D1 SCL; RTR MSB-first ----
    task z_rtr_a(output [7:0] d);
        integer j; begin
            d=8'h00; io0_a=1'b0;
            for (j=0;j<8;j=j+1) begin dla[1]=1;tk; dla[1]=0;tk; d={d[6:0],io0_out_a}; end
        end
    endtask

    reg ack; reg [7:0] b0,b1,b2,b3,d; reg [63:0] rom, want;
    reg [63:0] cpw_i, rpw_i, rpw_g;

    initial begin
        // fixtures: a missing one is a FAILURE (the lesson of tb_s573_seccart Part 3)
        fh = $fopen("secdata/ddr4m_cas.hex", "r");
        if (fh) begin $fclose(fh); d4_present = 1;
            $readmemh("secdata/ddr4m_game_u1.hex", d4_u1);
            $readmemh("secdata/ddr4m_cas.hex", d4_cas); end
        fh = $fopen("secdata/ddr3ma_cas.hex", "r");
        if (fh) begin $fclose(fh); d3_present = 1;
            $readmemh("secdata/ddr3ma_game_u1.hex", d3_u1);
            $readmemh("secdata/ddr3ma_cas.hex", d3_cas); end

        repeat (4) @(posedge clk); rst = 0; repeat (4) @(posedge clk);
        latch_on(1); latch_on(2); latch_on(3);

        // =====================================================================
        // Part 0: an 8-byte .u6 through the splitter (the single-cassette case)
        // =====================================================================
        @(negedge clk); p0_dl = 1;
        for (i=0;i<8;i=i+1) begin
            @(negedge clk); p0_addr=i[9:0]; p0_data=8'h11+i[7:0]; p0_we=1; if (i[9:0] > p0_max) p0_max=i[9:0];
            @(negedge clk); p0_we=0; end
        @(negedge clk); p0_dl = 0; repeat (3) @(posedge clk);
        if (n_ser !== 8 || n_iser !== 0 || n_ieep !== 0) begin
            $display("FAIL: .u6 split: ser=%0d iser=%0d ieep=%0d (want 8/0/0)", n_ser, n_iser, n_ieep); errors=errors+1; end
        if (p0_present !== 1'b0) begin $display("FAIL: .u6 marked an install cassette present"); errors=errors+1; end

        if (!d4_present) begin
            $display("FAIL: ddr4m fixtures absent (secdata/ddr4m_cas.hex) -- run sim/gen_secdata.sh with dumps/mame573/ddr4m.zip");
            errors = errors + 1;
        end else begin
            // =================================================================
            // Part A: ddr4m in LAUNCHER order -- .u1 (index 4) then .cas (index 5),
            // then the .sav restore of the ZS01 image (what s573_cass_nv does at LOAD)
            // =================================================================
            for (i=0;i<4116;i=i+1) eep_a(i[12:0], d4_u1[i], 1'b0);
            @(negedge clk); pa_dl = 1;
            for (i=0;i<564;i=i+1) pack_byte_a(i[9:0], d4_cas[i]);
            @(negedge clk); pa_dl = 0; repeat (3) @(posedge clk);
            // A1: the pack was recognised
            if (a_present !== 1'b1 || a_type !== 1'b1) begin
                $display("FAIL: ddr4m pack: inst_present=%b inst_type=%b (want 1/1 = X76F041)", a_present, a_type); errors=errors+1; end
            // the restore: 140 bytes of the ZS01 image over addresses 0..139, flagged
            for (i=0;i<140;i=i+1) eep_a(i[12:0], d4_u1[i], 1'b1);
            tk;

            // A2: INSTALL cassette in the slot
            sel_a = 1; tk;
            if (dbg_a[63:62] !== 2'd1) begin $display("FAIL: ddr4m slot type stamp %0d (want 1 = X76F041)", dbg_a[63:62]); errors=errors+1; end
            x_select(1);
            x_rtr(1,b0); x_rtr(1,b1); x_rtr(1,b2); x_rtr(1,b3);
            if ({b0,b1,b2,b3} !== 32'h19_55_AA_55) begin
                $display("FAIL: ddr4m install RTR %02h%02h%02h%02h (want 1955aa55 X76F041)", b0,b1,b2,b3); errors=errors+1; end
            x_stop(1);
            // the REAL config password: pack[16+20 .. 16+27]
            for (i=0;i<8;i=i+1) cpw_i[8*(7-i) +: 8] = d4_cas[16+20+i];
            f041_cfg_auth(1, cpw_i, ack);
            if (ack !== 1'b0) begin $display("FAIL: ddr4m install cassette rejected its REAL config password (ack=%b)", ack); errors=errors+1; end
            x_read(1, 1'b0, d);   // BCR1 = image[28]
            if (d !== d4_cas[16+28]) begin $display("FAIL: ddr4m install BCR1=%02h (want %02h from gea33aa.u1)", d, d4_cas[16+28]); errors=errors+1; end
            x_read(1, 1'b1, d);   // BCR2 = image[29]
            if (d !== d4_cas[16+29]) begin $display("FAIL: ddr4m install BCR2=%02h (want %02h)", d, d4_cas[16+29]); errors=errors+1; end
            x_stop(1);
            f041_cfg_auth(1, ~cpw_i, ack);   // negative control
            if (ack !== 1'b1) begin $display("FAIL: ddr4m install cassette accepted a WRONG config password"); errors=errors+1; end
            x_stop(1);
            // open the data array (BCR1/CR permissive, via the install load path --
            // the .u1 path is shut out of eeprom041 once the install image is in)
            @(negedge clk); pa_dl = 1;
            pack_byte_a(10'd16+10'd28, 8'h00);   // BCR1
            pack_byte_a(10'd16+10'd30, 8'h00);   // CR
            @(negedge clk); pa_dl = 0; tk;
            x_start(1); x_send(1, 8'h20, ack); x_send(1, 8'h00, ack);
            if (ack !== 1'b0) begin $display("FAIL: ddr4m install data read addr ack=%b", ack); errors=errors+1; end
            for (i=0;i<4;i=i+1) begin
                x_read(1, (i==3) ? 1'b1 : 1'b0, d);
                if (d !== d4_cas[16+36+i]) begin
                    $display("FAIL: ddr4m install data[%0d]=%02h (want %02h from gea33aa.u1 -- restore/.u1 wrapped over it?)", i, d, d4_cas[16+36+i]); errors=errors+1; end
            end
            x_stop(1);
            x_deselect(1);
            ow_read_rom(1, rom);
            want = {d4_cas[8],d4_cas[9],d4_cas[10],d4_cas[11],d4_cas[12],d4_cas[13],d4_cas[14],d4_cas[15]};
            if (rom !== want) begin $display("FAIL: ddr4m install DS2401 %016h (want gea33aa.u6 %016h)", rom, want); errors=errors+1; end

            // A3: GAME cassette in the slot
            sel_a = 0; tk;
            if (dbg_a[63:62] !== 2'd2) begin $display("FAIL: ddr4m slot type stamp %0d (want 2 = ZS01)", dbg_a[63:62]); errors=errors+1; end
            put(1,2,0); put(1,3,1);            // CS low, RST high -> RTR
            z_rtr_a(b0); z_rtr_a(b1); z_rtr_a(b2); z_rtr_a(b3);
            if ({b0,b1,b2,b3} !== 32'h5a53_0001) begin
                $display("FAIL: ddr4m game RTR %02h%02h%02h%02h (want 5a530001 ZS01)", b0,b1,b2,b3); errors=errors+1; end
            put(1,3,0); put(1,2,1);
            // the X76F041 must be deselected now: an X76-framed RTR is not 1955aa55
            x_select(1);
            x_rtr(1,b0); x_rtr(1,b1); x_rtr(1,b2); x_rtr(1,b3);
            if ({b0,b1,b2,b3} === 32'h19_55_AA_55) begin
                $display("FAIL: X76F041 still answers with the GAME cassette selected"); errors=errors+1; end
            x_deselect(1);
            ow_presence(1, ack);
            if (ack !== 1'b0) begin $display("FAIL: ddr4m ZS01 game cassette answers 1-Wire on I6 (psx-spx: not exposed)"); errors=errors+1; end
            // and the install cassette's DS2401 still answers once it is selected again
            sel_a = 1; tk;
            ow_presence(1, ack);
            if (ack !== 1'b1) begin $display("FAIL: ddr4m install DS2401 lost its presence pulse"); errors=errors+1; end
            sel_a = 0; tk;

            // =================================================================
            // Part B: REVERSED order -- .cas first, then the 4116-B .u1
            // =================================================================
            @(negedge clk); pb_dl = 1;
            for (i=0;i<564;i=i+1) pack_byte_b(i[9:0], d4_cas[i]);
            @(negedge clk); pb_dl = 0; repeat (3) @(posedge clk);
            for (i=0;i<4116;i=i+1) eep_b(i[12:0], d4_u1[i]);
            tk;
            sel_b = 1; tk;
            x_select(2);
            x_rtr(2,b0); x_rtr(2,b1); x_rtr(2,b2); x_rtr(2,b3);
            if ({b0,b1,b2,b3} !== 32'h19_55_AA_55) begin
                $display("FAIL: (reversed) install RTR %02h%02h%02h%02h", b0,b1,b2,b3); errors=errors+1; end
            x_stop(2);
            f041_cfg_auth(2, cpw_i, ack);
            if (ack !== 1'b0) begin $display("FAIL: (reversed order) the .u1 wrapped over the install cassette -- config password rejected"); errors=errors+1; end
            x_read(2, 1'b0, d);
            if (d !== d4_cas[16+28]) begin $display("FAIL: (reversed) BCR1=%02h (want %02h)", d, d4_cas[16+28]); errors=errors+1; end
            x_read(2, 1'b1, d);
            x_stop(2);
            x_deselect(2);
        end

        if (!d3_present) begin
            $display("FAIL: ddr3ma fixtures absent (secdata/ddr3ma_cas.hex) -- run sim/gen_secdata.sh with dumps/mame573/ddr3ma.zip");
            errors = errors + 1;
        end else begin
            // =================================================================
            // Part C: ddr3ma -- X76F100 game + X76F100 install (cassyyi)
            // =================================================================
            for (i=0;i<132;i=i+1) eep_c(i[12:0], d3_u1[i]);
            @(negedge clk); pc_dl = 1;
            for (i=0;i<148;i=i+1) pack_byte_c(i[9:0], d3_cas[i]);
            @(negedge clk); pc_dl = 0; repeat (3) @(posedge clk);
            if (c_present !== 1'b1 || c_type !== 1'b0) begin
                $display("FAIL: ddr3ma pack: inst_present=%b inst_type=%b (want 1/0 = X76F100)", c_present, c_type); errors=errors+1; end
            // read passwords: image [12:19]
            for (i=0;i<8;i=i+1) begin rpw_g[8*(7-i) +: 8] = d3_u1[12+i]; rpw_i[8*(7-i) +: 8] = d3_cas[16+12+i]; end
            if (rpw_g === rpw_i) begin $display("FAIL: ddr3ma game/install read passwords identical -- check proves nothing"); errors=errors+1; end

            // C1: INSTALL in the slot
            sel_c = 1; tk;
            if (dbg_c[63:62] !== 2'd0) begin $display("FAIL: ddr3ma slot type stamp %0d (want 0)", dbg_c[63:62]); errors=errors+1; end
            x_select(3);
            x_rtr(3,b0); x_rtr(3,b1); x_rtr(3,b2); x_rtr(3,b3);
            if ({b0,b1,b2,b3} !== 32'h19_00_AA_55) begin
                $display("FAIL: ddr3ma install RTR %02h%02h%02h%02h (want 1900aa55 X76F100)", b0,b1,b2,b3); errors=errors+1; end
            x_stop(3);
            f100_auth(3, 8'h81, rpw_i, ack);         // READ block 0, install password
            if (ack !== 1'b0) begin $display("FAIL: ddr3ma install cassette rejected its REAL read password"); errors=errors+1; end
            for (i=0;i<8;i=i+1) begin
                x_read(3, (i==7) ? 1'b1 : 1'b0, d);
                if (d !== d3_cas[16+20+i]) begin
                    $display("FAIL: ddr3ma install data[%0d]=%02h (want %02h from ge887aa.u1)", i, d, d3_cas[16+20+i]); errors=errors+1; end
            end
            x_stop(3);
            f100_auth(3, 8'h81, rpw_g, ack);         // the GAME password must be refused here
            if (ack !== 1'b1) begin $display("FAIL: ddr3ma install cassette accepted the GAME cassette's password"); errors=errors+1; end
            x_stop(3);
            x_deselect(3);
            ow_read_rom(3, rom);
            want = {d3_cas[8],d3_cas[9],d3_cas[10],d3_cas[11],d3_cas[12],d3_cas[13],d3_cas[14],d3_cas[15]};
            if (rom !== want) begin $display("FAIL: ddr3ma install DS2401 %016h (want ge887aa.u6 %016h)", rom, want); errors=errors+1; end

            // C2: GAME in the slot
            sel_c = 0; tk;
            x_select(3);
            x_rtr(3,b0); x_rtr(3,b1); x_rtr(3,b2); x_rtr(3,b3);
            if ({b0,b1,b2,b3} !== 32'h19_00_AA_55) begin
                $display("FAIL: ddr3ma game RTR %02h%02h%02h%02h", b0,b1,b2,b3); errors=errors+1; end
            x_stop(3);
            f100_auth(3, 8'h81, rpw_g, ack);
            if (ack !== 1'b0) begin $display("FAIL: ddr3ma game cassette rejected its REAL read password"); errors=errors+1; end
            for (i=0;i<8;i=i+1) begin
                x_read(3, (i==7) ? 1'b1 : 1'b0, d);
                if (d !== d3_u1[20+i]) begin
                    $display("FAIL: ddr3ma game data[%0d]=%02h (want %02h from gn887aa.u1)", i, d, d3_u1[20+i]); errors=errors+1; end
            end
            x_stop(3);
            f100_auth(3, 8'h81, rpw_i, ack);
            if (ack !== 1'b1) begin $display("FAIL: ddr3ma game cassette accepted the INSTALL cassette's password"); errors=errors+1; end
            x_stop(3);
            x_deselect(3);
            ow_read_rom(3, rom);
            want = {d3_cas[0],d3_cas[1],d3_cas[2],d3_cas[3],d3_cas[4],d3_cas[5],d3_cas[6],d3_cas[7]};
            if (rom !== want) begin $display("FAIL: ddr3ma game DS2401 %016h (want gn887aa.u6 %016h)", rom, want); errors=errors+1; end
        end

        if (errors == 0) $display("RESULT: PASS (s573_seccart_dual)");
        else             $display("RESULT: FAIL (s573_seccart_dual, %0d errors)", errors);
        $finish;
    end
endmodule
