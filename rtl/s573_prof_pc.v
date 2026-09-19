// -----------------------------------------------------------------------------
// s573_prof_pc.v - PC-sampling profiler for the R3000 (Tier-3 #1-#3)
//
// WHY. Run C (2026-09-17) established that ddrextrm renders exactly 60 frames a
// second while the MDEC is idle and exactly 30 while a background video decodes,
// with every occupancy counter (MDEC 24.6%, GPU 10%, DMA-paused 3.5%, CPU memory-
// stall 13.6%) far from saturation. An occupancy level cannot tell a spin-wait from
// work, so those numbers could not say WHERE the CPU's 33 ms go: in libpress's
// DecDCTvlc, in a DrawSync/VSync spin, or in the game's own logic
// (docs/2026-09-18-ddrextrm-video-path-from-sources.md). A PC profile can.
//
// WHAT. Every 2^SAMPLE_LOG2 clk1x cycles the fetch PC (psx_patches 0031,
// psx_top dbg573_pc) is sampled and one of 512 16-bit bins is incremented:
//   RAM, first 1 MB        bin = phys[19:11]   (2 KB bins -- the game executable
//                           loads at 0x80010000 and is 0xde800 long, so it occupies
//                           bins 0x020..0x1dc; the kernel is bins 0x000..0x01f.
//                           2 KB, not 4: ddrextrm's libpress puts the blocking
//                           DecDCTin/outSync spin loops at 0x800733xx..0x800737xx
//                           and DecDCTvlc from 0x80073804 -- the 2 KB boundary
//                           at 0x80073800 is what separates "waiting on the MDEC"
//                           from "decoding the bitstream on the CPU")
//   RAM, 1 MB .. 8 MB      cnt_ram_hi          (overlays, if any)
//   BIOS ROM               cnt_bios
//   anything else          cnt_other           (scratchpad, EXP1/2, garbage)
// and cnt_samples counts every sample. All counters are free-running CUMULATIVE
// 16-bit values, same contract as s573_prof.v / s573_prof_gpu.v: the HPS diffs
// consecutive dumps mod 2^16. At the default period (1024 clk = 33,075 samples/s)
// no counter can move by 65,536 within a one-second dump interval, so the diffs
// are unambiguous without any clearing -- which is what keeps the bin store a
// single M10K (512 x 16 = 8 Kbit) with no sweep logic. Bins are NOT reset on rst
// (the RAM has no reset; the first diff after a reset is discarded by the HPS).
//
// The bin store is one 512x16 RAM: port A does the sampler's read-modify-write
// (three cycles out of every 2^SAMPLE_LOG2), port B is the HPS read port with the
// s573_hps_ext trace convention -- rd_data is valid the cycle after rd_addr.
//
// Sampling the fetch PC while the CPU is stalled on memory or paused for DMA
// still attributes that time to the instruction at the head of the pipeline,
// which is the point: this is a WALL-CLOCK profile, not an instruction count.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_prof_pc #(
    parameter SAMPLE_LOG2 = 10          // sample every 2^SAMPLE_LOG2 clk cycles
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] pc,              // psx dbg573_pc (fetch PC), clk1x domain
    // ---- HPS read port (s573_hps_ext CMD_573_PCPROF) ----
    input  wire [8:0]  rd_addr,
    output reg  [15:0] rd_data,         // bin[rd_addr], valid the cycle after rd_addr
    output reg  [15:0] cnt_samples,     // samples taken (cumulative)
    output reg  [15:0] cnt_ram_hi,      // samples with the PC in RAM above 1 MB
    output reg  [15:0] cnt_bios,        // samples with the PC in the BIOS ROM
    output reg  [15:0] cnt_other        // samples anywhere else
);
    // ---- sample cadence ----
    reg [SAMPLE_LOG2-1:0] tick;
    wire sample = (tick == {SAMPLE_LOG2{1'b0}});

    // ---- classify the sampled PC ----
    // KUSEG (000), KSEG0 (100) and KSEG1 (101) all map the same physical space;
    // the 573 has 4 MB of RAM but the mirror decode covers 8 MB, so use that.
    wire        seg_ok  = (pc[31:29] == 3'b000) || (pc[31:29] == 3'b100) || (pc[31:29] == 3'b101);
    wire [28:0] phys    = pc[28:0];
    wire        in_ram  = seg_ok && (phys[28:23] == 6'd0);          // < 0x800000
    wire        in_lo   = in_ram && (phys[22:20] == 3'd0);          // < 0x100000
    wire        in_bios = seg_ok && (phys[28:19] == 10'h3F8);        // 0x1FC00000..0x1FC7FFFF

    // ---- bin store: 512 x 16, port A = sampler RMW, port B = HPS read ----
    reg [15:0] hist [0:511];
    // Zero at power-up. Quartus honours this for an inferred RAM (it becomes the
    // M10K's initial contents) and simulation needs it, or every bin is X until
    // its first write and the HPS's first diffs are garbage.
    integer init_i;
    initial for (init_i = 0; init_i < 512; init_i = init_i + 1) hist[init_i] = 16'd0;
    reg [8:0]  a_addr;
    reg [15:0] a_q;
    reg        a_we;
    reg [15:0] a_din;
    reg [1:0]  st;                      // 0 idle, 1 read issued, 2 write

    // Written in the Quartus true-dual-port template form (port A read-during-
    // write returns NEW data) so it infers one M10K rather than 8,192 flops --
    // this design lives at 98.7% LAB occupancy. The sampler never uses a_q from
    // the cycle it writes, so the read-during-write mode is immaterial to it.
    always @(posedge clk) begin
        // port A: the sampler's read-modify-write
        if (a_we) begin
            hist[a_addr] <= a_din;
            a_q          <= a_din;
        end else begin
            a_q          <= hist[a_addr];
        end
        // port B: the HPS read port
        rd_data <= hist[rd_addr];
    end

    always @(posedge clk) begin
        if (rst) begin
            tick        <= {SAMPLE_LOG2{1'b0}};
            st          <= 2'd0;
            a_we        <= 1'b0;
            a_addr      <= 9'd0;
            a_din       <= 16'd0;
            cnt_samples <= 16'd0;
            cnt_ram_hi  <= 16'd0;
            cnt_bios    <= 16'd0;
            cnt_other   <= 16'd0;
        end else begin
            tick <= tick + 1'b1;
            a_we <= 1'b0;
            case (st)
                2'd0: if (sample) begin
                    cnt_samples <= cnt_samples + 1'b1;
                    if (in_lo) begin
                        a_addr <= phys[19:11];      // read issued this cycle (a_q next)
                        st     <= 2'd1;
                    end else if (in_ram) begin
                        cnt_ram_hi <= cnt_ram_hi + 1'b1;
                    end else if (in_bios) begin
                        cnt_bios <= cnt_bios + 1'b1;
                    end else begin
                        cnt_other <= cnt_other + 1'b1;
                    end
                end
                2'd1: st <= 2'd2;                   // a_q now holds hist[a_addr]
                2'd2: begin
                    a_din <= a_q + 1'b1;
                    a_we  <= 1'b1;
                    st    <= 2'd0;
                end
                default: st <= 2'd0;
            endcase
        end
    end
endmodule
