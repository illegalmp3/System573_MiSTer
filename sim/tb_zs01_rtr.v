`timescale 1ns/1ps
// tb_zs01_rtr.v -- replay PSX.EXE's ZS01 type-detection probe against the REAL
// s573_seccart read-back path, and check the 32-bit id the game would assemble.
//
// This is NOT another cipher/round-trip bench. It reproduces, latch-write for
// latch-write, the boot-time detector at PSX.EXE 0x803250b8 (decoded in
// docs/2026-09-14): assert CS, pulse RST high, one SCL cycle, then 32 iterations
// of {sample 0x1f400006 bit2 while SCL low; raise SCL; shift; lower SCL}. It reads
// sec_io0 exactly where the game reads bit 2, through the real cart_type=2 mux, so
// a read-back-path error is visible here -- which neither existing ZS01 bench can
// see (they clock the RTR the way the RTL emits it).
//
// The game assembles MSB-first and compares to 0x5a530001. On hardware it got a
// 1-bit-shifted value (0xb4a60002) and rejected the cassette (ERROR 121 (3)).
// GREEN here == the read-back path delivers the id the way the game clocks it.
module tb_zs01_rtr;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    // latch bits (0x1f6a0000): [0]=SDA(D0) [1]=SCL(D1) [2]=CS(D2, active-low) [3]=RST(D3)
    reg  [7:0] latch = 8'b0000_1111;   // idle: RST/CS/SCL/SDA all released-ish
    reg        latch_we = 0;
    reg        io0_dir = 0;            // control bit6 (ZS01 SDA host drive); 0 = released

    wire [7:0] sec_in;
    wire       sec_io0, sec_drdy, sec_irdy;
    wire [63:0] sec_dbg; wire sec_cs_n; wire [7:0] sec_rtr_edges;
    wire sec_in_rtr; wire [31:0] sec_rtr_emit;

    reg        L_we=0; reg [12:0] L_addr=0; reg [7:0] L_data=0;
    reg        Ls_we=0; reg [2:0] Ls_addr=0; reg [7:0] Ls_data=0;

    s573_seccart #(.CART_TYPE(2)) dut (
        .clk(clk), .rst(rst),
        .cart_type(2'd2),
        .latch_we(latch_we), .d_latch(latch),
        .io0_dir(io0_dir),
        .load_eep_we(L_we), .load_eep_addr(L_addr), .load_eep_data(L_data),
        .load_ser_we(Ls_we), .load_ser_addr(Ls_addr), .load_ser_data(Ls_data),
        // second (install) cassette + restore flag: not used by this bench
        .load_eep_zs01_only(1'b0), .inst_sel(1'b0), .inst_type(1'b0), .load_ieep_we(1'b0), .load_ieep_addr(10'd0), .load_ieep_data(8'd0), .load_iser_we(1'b0), .load_iser_addr(3'd0), .load_iser_data(8'd0),
        .sec_dbg(sec_dbg), .sec_cs_n(sec_cs_n), .sec_rst_line(), .sec_scl_line(), .sec_sda_line(), .sec_zs01_state(), .sec_rtr_edges(sec_rtr_edges),
        .sec_in_rtr(sec_in_rtr), .sec_rtr_emit(sec_rtr_emit),
        .sec_io0(sec_io0), .sec_in(sec_in), .sec_drdy(sec_drdy), .sec_irdy(sec_irdy)
    );

    // write the latch and let the chip's registered scl edge-detect settle
    task wr(input [7:0] v); begin
        @(negedge clk); latch = v; latch_we = 1;
        @(negedge clk); latch_we = 0;
        repeat (20) @(negedge clk);   // >> the CPU's own inter-write delay
    end endtask

    // latch bit positions (0x1f6a0000): declared BEFORE the tasks that use them
    localparam D0=0, D1=1, D2=2, D3=3;

    task probe(input d0, output [31:0] idout);
        integer k; reg bb; reg [7:0] LL;
        begin
            // return the chip to idle. NOTE: as of the 2026-09-14 wiring fix, latch
            // D0 is NOT connected to the ZS01 (SDA is control bit 6 alone), so this
            // D0 wiggle no longer reaches the chip -- it is harmless, and the RST
            // rising edge below forces ST_RTR regardless. Kept as bus stimulus.
            // (was: STOP = SDA rising while SCL high)
            LL = 8'b0000_1111; LL[D0]=0; LL[D1]=1; LL[D2]=0; wr(LL);
            LL[D0]=1;                                        wr(LL);  // STOP
            LL[D1]=0;                                        wr(LL);
            // ---- detector preamble (PSX.EXE 0x803250fc..0x80325194) ----
            LL[D0]=d0;           wr(LL);   // whatever the board left on D0
            LL[D1]=0;            wr(LL);   // SCL low
            LL[D2]=0;            wr(LL);   // CS low = selected
            LL[D3]=0;            wr(LL);   // RST low
            LL[D3]=1;            wr(LL);   // RST high -> response to reset
            LL[D1]=1;            wr(LL);   // SCL high
            LL[D1]=0;            wr(LL);   // SCL low -> chip drives bit 0
            idout = 32'd0;
            for (k=0;k<32;k=k+1) begin
                bb    = sec_io0;                  // sample bit2 while SCL low
                idout = {idout[30:0], bb};
                LL[D1]=1;        wr(LL);          // SCL high
                LL[D1]=0;        wr(LL);          // SCL low -> next bit
            end
        end
    endtask

    integer cfg;
    reg cfg_io0, cfg_d0;
    reg [7:0] u1 [0:4115];
    reg [7:0] u6 [0:7];
    reg [31:0] id; integer i; reg present; integer fh;
    reg b; integer errors;


    initial begin
        errors = 0;
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
            $display("tb_zs01_rtr: no ddrusa fixture -- SKIPPED"); $display("RESULT: PASS"); $finish;
        end

        // load the image
        repeat (4) @(negedge clk); rst = 1;
        for (i=0;i<140;i=i+1) begin @(negedge clk); L_we=1; L_addr=i[12:0]; L_data=u1[i]; end
        @(negedge clk); L_we=0;
        for (i=0;i<8;i=i+1) begin @(negedge clk); Ls_we=1; Ls_addr=i[2:0]; Ls_data=u6[i]; end
        @(negedge clk); Ls_we=0;
        repeat (4) @(negedge clk); rst = 0; repeat (4) @(negedge clk);

        // ---- sweep the two host-side drive signals the board may leave in any
        // ---- state: io0_dir (control bit 6) and D0. Neither should affect what the
        // ---- DEVICE drives during the response-to-reset, so all four must read back
        // ---- the id. Since the 2026-09-14 fix D0 is not wired to the ZS01 at all, so
        // ---- the D0 half of the sweep is now trivially independent by construction.
        for (cfg = 0; cfg < 4; cfg = cfg + 1) begin
            cfg_io0 = (cfg / 2) % 2;
            cfg_d0  = cfg % 2;
            io0_dir = cfg_io0;
            probe(cfg_d0, id);
            $display("tb_zs01_rtr: io0_dir=%0d D0=%0d -> assembled 0x%08x  edges=%0d  drove 0x%08x%s",
                     cfg_io0, cfg_d0, id, sec_rtr_edges, sec_rtr_emit,
                     (id === 32'h5a53_0001) ? "  ok" : "   <== FAILS");
            if (id !== 32'h5a53_0001) errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d of 4 combinations fail)", errors);
        $finish;
    end
endmodule
