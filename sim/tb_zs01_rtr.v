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
        .sec_dbg(sec_dbg), .sec_cs_n(sec_cs_n), .sec_rtr_edges(sec_rtr_edges),
        .sec_in_rtr(sec_in_rtr), .sec_rtr_emit(sec_rtr_emit),
        .sec_io0(sec_io0), .sec_in(sec_in), .sec_drdy(sec_drdy), .sec_irdy(sec_irdy)
    );

    // write the latch and let the chip's registered scl edge-detect settle
    task wr(input [7:0] v); begin
        @(negedge clk); latch = v; latch_we = 1;
        @(negedge clk); latch_we = 0;
        repeat (20) @(negedge clk);   // >> the CPU's own inter-write delay
    end endtask

    reg [7:0] u1 [0:4115];
    reg [7:0] u6 [0:7];
    reg [31:0] id; integer i; reg present; integer fh;
    reg b;

    // bit positions
    localparam D0=0, D1=1, D2=2, D3=3;
    reg [7:0] L;

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
            $display("tb_zs01_rtr: no ddrusa fixture -- SKIPPED"); $display("RESULT: PASS"); $finish;
        end

        // load the image
        repeat (4) @(negedge clk); rst = 1;
        for (i=0;i<140;i=i+1) begin @(negedge clk); L_we=1; L_addr=i[12:0]; L_data=u1[i]; end
        @(negedge clk); L_we=0;
        for (i=0;i<8;i=i+1) begin @(negedge clk); Ls_we=1; Ls_addr=i[2:0]; Ls_data=u6[i]; end
        @(negedge clk); Ls_we=0;
        repeat (4) @(negedge clk); rst = 0; repeat (4) @(negedge clk);

        // ---- detector preamble (0x803250fc..0x80325194) ----
        // idle high, then: SCL low; CS low(select); RST low; delay; RST high(->RTR);
        // delay; SCL high; delay; SCL low(1st falling -> chip drives bit0); delay.
        L = 8'b0000_1111;              wr(L);            // start released
        L[D1]=0;                       wr(L);            // SCL low
        L[D2]=0;                       wr(L);            // CS low = selected
        L[D3]=0;                       wr(L);            // RST low
        L[D3]=1;                       wr(L);            // RST high -> RESPONSE TO RESET
        L[D1]=1;                       wr(L);            // SCL high (rising)
        L[D1]=0;                       wr(L);            // SCL low  (falling #1 -> bit0)

        // ---- 32 samples, MSB-first (0x8032519c inner x 4 bytes) ----
        id = 32'd0;
        for (i=0;i<32;i=i+1) begin
            b  = sec_io0;                                 // SAMPLE bit2 while SCL low
            id = {id[30:0], b};
            L[D1]=1;                    wr(L);            // SCL high (rising)
            L[D1]=0;                    wr(L);            // SCL low  (falling -> next bit)
        end

        $display("tb_zs01_rtr: assembled 0x%08x  (want 0x5a530001; hw saw 0xb4a60002)", id);
        $display("tb_zs01_rtr: chip serviced %0d RTR falling edges, drove 0x%08x",
                 sec_rtr_edges, sec_rtr_emit);
        if (id === 32'h5a53_0001) $display("RESULT: PASS");
        else                      $display("RESULT: FAIL");
        $finish;
    end
endmodule
