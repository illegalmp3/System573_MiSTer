// -----------------------------------------------------------------------------
// s573_sectrace -- cassette stimulus recorder (ddrusa ERROR 121 (3))
//
// Five bitstreams have now been spent trying to see what PSX.EXE's ZS01 detector
// actually does on the board, and every one of them was wasted by the CAPTURE
// GATE, not by the hypothesis:
//
//   1. gated on CS          -- the game holds CS asserted and polls the same misc
//                              word for coins forever, so idle reads overwrote it.
//   2. gated on in_rtr      -- the RTR-loops fix landed in the SAME bitstream and
//                              made in_rtr never fall, so again idle reads won.
//   3. fill-once ring       -- filled with 128 boot-time DS2401 1-Wire latch writes
//                              (all scl=0, zero misc reads) long before the probe,
//                              and it clobbered the frozen capture on the way past.
//
// The lesson is that the gate has to be derived from something ONLY the cassette
// protocol does, and it has to be provable before a bitstream is spent. Hence:
//
//   * this is a MODULE, not inline logic, so sim/tb_sectrace_arm.v can drive it
//     with the measured boot traffic followed by the real detector probe and
//     assert that the window opens on the probe;
//   * the primary trigger is the RST RISING EDGE WITH THE CASSETTE SELECTED, and
//     it RE-ARMS: it is the edge that starts the response-to-reset, so the window
//     begins exactly where PSX.EXE's detector begins. The board says this edge
//     happens exactly ONCE in a whole run (zs01.v's dbg_rtr = rtr_probes = 1), so
//     re-arming cannot be flooded the way gating on CS or in_rtr was.
//   * the fallback trigger, used only if RST never rises, is an SCL EDGE WITH THE
//     CASSETTE SELECTED. The 128 captured boot entries prove that discriminates:
//     scl was 0 on every one of them and never moved, because the board DS2401
//     hangs off latch D4 and needs no clock. CS on its own is useless here -- it
//     was already asserted through all of that traffic.
//
// Once armed the ring records every cassette latch write and every read of the
// misc word, in order, and FREEZES when full. Those 256 entries span the whole
// 33-edge response-to-reset plus the CPU reads interleaved with it, so the value
// the game assembled can be reconstructed exactly from the trace rather than
// guessed at from a register whose window length I had to assume in advance.
//
//   entry = { evt, rst, cs_n, scl, sda, ds, io0_dir, io0, cpu_bit, state[2:0], dt[3:0] }
//   (256 entries; trace_count bit 9 = the window opened, bits 8:0 = entries).
//   256 and not 128 because the probe alone is ~106 events: 32 iterations of
//   {read, SCL high write, SCL low write} plus the RST/CS/SCL preamble. A 128-deep
//   ring would have truncated the tail of the very thing it was built to record.
//           evt: 0 = cassette latch write, 1 = CPU read of 0x1f400006
//           dt counts 32-clk ticks since the previous event, saturating at 15
//           (~0.94 us per tick at 33.8688 MHz, so 15 means "more than ~14 us").
//
// cap_bits/cap_cnt are the cheap cross-check kept in the original 4023f19 format:
// cpu_bit shifted in on the first 32 misc reads after the latest arm, then frozen,
// with cap_cnt counting every read in the window so a 33-read probe is visible as
// a count, not as a silently shifted-out capture.
// -----------------------------------------------------------------------------
module s573_sectrace (
    input  wire        clk,
    input  wire        rst,

    // live cassette fabric state
    input  wire        cs_n,        // latch D2 (active low chip select)
    input  wire        rst_line,    // latch D3
    input  wire        scl,         // latch D1
    input  wire        sda,         // latch D0
    input  wire        ds,          // latch D4 (board DS2401 drive) -- marks 1-Wire traffic
    input  wire        io0_dir,     // 0x1f500000 bit 6 (active low host drive)
    input  wire        io0,         // what the cassette mux presents to s573_io
    input  wire        cpu_bit,     // bit 2 of the misc word s573_io hands the CPU
    input  wire [2:0]  zs01_state,  // ZS01 framing state

    // the two stimulus events worth recording
    input  wire        latch_wr,    // 1-cycle: CPU wrote the 0x1f6a0000 latch
    input  wire        misc_rd,     // 1-cycle: CPU read 0x1f400006

    // read-out
    input  wire [7:0]  trace_addr,
    output reg  [15:0] trace_data,
    output wire [15:0] trace_count, // {armed, entries[8:0]} -- see below
    output wire [31:0] cap_bits,
    output wire [7:0]  cap_cnt
);
    reg [15:0] ring [0:255];
    reg [8:0]  wptr      = 9'd0;    // 0..256; bit 8 set == full (256 recorded)
    wire       full      = wptr[8];
    reg        armed     = 1'b0;
    reg        scl_q     = 1'b0;
    reg        rst_q     = 1'b0;
    reg [3:0]  dt        = 4'd0;
    reg [4:0]  tick      = 5'd0;
    reg [31:0] capr      = 32'd0;
    reg [7:0]  capc      = 8'd0;
    reg        cap_live  = 1'b0;

    // RST 0->1 while selected == the start of a response-to-reset. Re-arming on it
    // means a spurious early arm is thrown away when the real probe arrives.
    wire sel_rst  = ~cs_n & rst_line;
    wire rst_rise = sel_rst & ~rst_q;
    // ONLY the cassette protocol clocks SCL. The board DS2401 is on latch D4 and
    // the boot traffic that swallowed the previous ring never touched D1.
    wire scl_edge = (scl != scl_q);
    wire arm_now  = rst_rise | (~armed & ~cs_n & scl_edge);
    wire logging  = (armed | arm_now) & ~full;
    wire evt      = latch_wr | misc_rd;
    // An event landing on the very clock the window (re)opens belongs at index 0 of
    // the NEW window, not appended to the discarded one. Same for the assembly.
    wire [8:0]  widx = arm_now ? 9'd0  : wptr;
    wire [31:0] cacc = arm_now ? 32'd0 : capr;
    wire [7:0]  ccnt = arm_now ? 8'd0  : capc;
    wire        clive = arm_now ? 1'b1 : cap_live;

    // EXACTLY 16 bits: 9 single-bit lines + 3 state + 4 dt. The first version of
    // this concatenation had only EIGHT single bits, so it was 15 bits wide, got
    // zero-extended, and every field in the HPS log was shifted by one -- which is
    // why the last hardware trace printed 128 latch writes when it had in fact
    // recorded 124 CPU reads. Count the fields if you touch this line.
    wire [15:0] entry = { misc_rd, rst_line, cs_n, scl, sda, ds,
                          io0_dir, io0, cpu_bit, zs01_state, dt };

    always @(posedge clk) begin
        scl_q <= scl;
        rst_q <= sel_rst;
        if (rst) begin
            wptr <= 9'd0; armed <= 1'b0;
            dt <= 4'd0; tick <= 5'd0;
            capr <= 32'd0; capc <= 8'd0; cap_live <= 1'b0;
        end else begin
            // (re)open the window: throw away anything recorded before this edge
            if (arm_now) begin
                armed    <= 1'b1;
                wptr     <= 9'd0;
                capr     <= 32'd0;
                capc     <= 8'd0;
                cap_live <= 1'b1;
                dt       <= 4'd0;
                tick     <= 5'd0;
            end

            // coarse inter-event delta
            if (tick == 5'd31) begin
                tick <= 5'd0;
                if (dt != 4'd15) dt <= dt + 4'd1;
            end else
                tick <= tick + 5'd1;

            if (logging & evt) begin
                ring[widx[7:0]] <= entry;
                dt   <= 4'd0;
                tick <= 5'd0;
                wptr <= widx + 9'd1;
            end

            // frozen first-32-reads assembly, same window
            if ((armed | arm_now) & misc_rd) begin
                if (clive) begin
                    capr <= {cacc[30:0], cpu_bit};
                    if (ccnt == 8'd31) cap_live <= 1'b0;
                end
                if (~&ccnt) capc <= ccnt + 8'd1;
            end
        end
    end

    // bit 9 says the window ever opened; bits 8:0 are the entries recorded (0..256).
    // The armed bit matters on its own: if it is 0, SCL never moved with the
    // cassette selected -- the game never clocked the chip at all.
    assign trace_count = {6'd0, armed, wptr};
    assign cap_bits    = capr;
    assign cap_cnt     = capc;

    always @(posedge clk) trace_data <= ring[trace_addr];
endmodule
