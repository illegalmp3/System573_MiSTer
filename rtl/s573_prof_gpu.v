// -----------------------------------------------------------------------------
// s573_prof_gpu.v - the PSX half of the frame-time profile (Tier-3 #1-#3)
//
// WHY. The 573-side counters (s573_prof.v) came back nearly empty on silicon
// (2026-09-17, run B): with ddrextrm in gameplay the flash wait, the digital-board
// wait and the CD fetch are all ~0% of the second, so the frame time the game is
// losing is not being lost in our glue. The watchdog turned out to be a fixed 30 Hz
// task in this title -- 30 kicks/s in the attract screens the player sees running
// at full speed as well as in the slow gameplay -- so it is not a frame meter
// either, and the run produced no frame rate at all.
//
// This is the frame meter. The taps come from psx_top (psx_patches 0029):
//   flip    GP1(05) "start of display area" write = the game's buffer flip, one
//           per RENDERED frame. This is the number the player is describing.
//   vblank  the GPU's own VBLANK interrupt, ~60/s: the reference the flip rate is
//           read against, and a check that the video timing itself is sane.
//   paused  cpuPaused: the CPU is stopped because a DMA owns the bus.
//   stall   stallNext: the CPU is stalled on a memory request.
//   gpubusy / mdecbusy: the drawing engine and the MDEC video decoder are working.
// Between them: whether the game renders 60 or 30 frames a second, and which engine
// is holding the second when it renders 30.
//
// Same contract as s573_prof.v: free-running cumulative 16-bit counters, cycle
// counters scaled >>10, the HPS diffs consecutive polls.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_prof_gpu (
    input  wire        clk,
    input  wire        rst,
    input  wire        flip,       // 1-clk: GP1(05) write (buffer flip)
    input  wire        vblank,     // 1-clk: GPU VBLANK irq
    input  wire        cpupaused,  // level: CPU stopped for DMA
    input  wire        cpustall,   // level: CPU stalled on memory
    input  wire        gpubusy,    // level: drawing engine busy
    input  wire        mdecbusy,   // level: MDEC busy
    input  wire        mdecmb,     // TOGGLE: flips once per decoded macroblock (clk2x source)
    output wire [15:0] prof_flips,
    output wire [15:0] prof_vblanks,
    output wire [15:0] prof_paused_k,
    output wire [15:0] prof_stall_k,
    output wire [15:0] prof_gpu_k,
    output wire [15:0] prof_mdec_k,
    output wire [15:0] prof_mdec_mb   // macroblocks decoded (a RATE, not an occupancy)
);
    // The taps are levels on psx_top's clk1x, which is this clock. flip and vblank
    // are single-cycle strobes there, but count only their RISING edge so a tap
    // that ever becomes a level cannot silently inflate a frame rate.
    reg flip_q, vb_q, mb_q;
    wire flip_edge = flip   & ~flip_q;
    wire vb_edge   = vblank & ~vb_q;
    // mdecmb is a toggle from the MDEC's clk2x domain: count EVERY level change. A
    // 1-clk2x pulse sampled here on clk1x was caught only ~half the time (09-27 log).
    wire mb_edge   = mdecmb ^ mb_q;

    reg [15:0] c_flip, c_vb, c_mb;
    reg [25:0] c_paused, c_stall, c_gpu, c_mdec;   // 16 visible + 10 fraction

    always @(posedge clk) begin
        flip_q <= flip;
        vb_q   <= vblank;
        mb_q   <= mdecmb;
        if (rst) begin
            c_flip <= 0; c_vb <= 0; c_mb <= 0;
            c_paused <= 0; c_stall <= 0; c_gpu <= 0; c_mdec <= 0;
            flip_q <= 1'b0; vb_q <= 1'b0; mb_q <= 1'b0;
        end else begin
            if (flip_edge)  c_flip   <= c_flip   + 1'b1;
            if (vb_edge)    c_vb     <= c_vb     + 1'b1;
            if (mb_edge)    c_mb     <= c_mb     + 1'b1;
            if (cpupaused)  c_paused <= c_paused + 1'b1;
            if (cpustall)   c_stall  <= c_stall  + 1'b1;
            if (gpubusy)    c_gpu    <= c_gpu    + 1'b1;
            if (mdecbusy)   c_mdec   <= c_mdec   + 1'b1;
        end
    end

    assign prof_flips    = c_flip;
    assign prof_vblanks  = c_vb;
    assign prof_paused_k = c_paused[25:10];
    assign prof_stall_k  = c_stall[25:10];
    assign prof_gpu_k    = c_gpu[25:10];
    assign prof_mdec_k   = c_mdec[25:10];
    assign prof_mdec_mb  = c_mb;
endmodule
