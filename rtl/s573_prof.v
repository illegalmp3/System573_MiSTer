// -----------------------------------------------------------------------------
// s573_prof.v - where the game's frame time goes (Tier-3 issues #1-#3)
//
// WHY. ddrextrm's gameplay loop halves while a background movie plays: the arrows
// scroll below 60 fps and the movie itself runs at about half speed, yet the audio
// stays in sync. The PSX core's Turbo setting (which removes the emulated RAM
// access waits) changed nothing on silicon (2026-09-17 A/B, three songs), so the
// lost time is NOT CPU memory-wait time. This module measures the remaining
// candidates that belong to US -- the 573 bus wait lines and the CD sector fetch --
// against a per-frame reference, so the next step is chosen from numbers instead
// of from a hypothesis.
//
// The per-frame reference is the WATCHDOG. The 573 bites unless the CPU strobes
// 0x1f5c0000 (MAME ksys573.cpp sys573_watchdog_w / watchdog.v), which every title
// does from its main loop, so kicks per second IS the loop rate. It is a relative
// meter: what matters is the same number in the menu (loop free) and in gameplay
// with a movie (loop halved), and how it moves when a candidate is fixed.
//
// All counters are FREE-RUNNING and CUMULATIVE; the HPS diffs consecutive polls.
// A 16-bit counter that can advance by at most ~33075 per second (a cycle counter
// at >>10, 33.8688 MHz) is unambiguous for any poll faster than 1.9 s -- the
// service polls every ~5 ms. Cheap by construction: a handful of counters and no
// bus of its own, so it can stay in the build instead of being a one-off probe.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_prof (
    input  wire        clk,
    input  wire        rst,

    // ---- levels: cycles counted while high ----
    input  wire        flash_wait,   // EXP1 stalled on the 573 flash / PCMCIA window
    input  wire        dio_wait,     // EXP1 stalled on the digital board (k573dio)
    input  wire        cd_busy,      // a CD sector fetch is outstanding (s573_cdimg)

    // ---- events ----
    input  wire        sec_done,     // 1-clk: a CD sector finished arriving
    input  wire        wdog_kick,    // 1-clk: the CPU strobed the watchdog (per frame)
    input  wire        ide_acc,      // LEVEL or pulse: CPU touching the ATAPI registers
    input  wire        exp1_acc,     // LEVEL or pulse: any EXP1 access

    // ---- STATUS words 17..23 (see s573_hps_ext.v) ----
    output wire [15:0] prof_flash_k, // flash_wait cycles >> 10
    output wire [15:0] prof_dio_k,   // dio_wait   cycles >> 10
    output wire [15:0] prof_cd_k,    // cd_busy    cycles >> 10
    output wire [15:0] prof_sectors, // sectors delivered
    output wire [15:0] prof_frames,  // watchdog kicks (= main-loop iterations)
    output wire [15:0] prof_ide,     // ATAPI register accesses >> 4
    output wire [15:0] prof_exp1     // EXP1 accesses >> 6
);
    // An access signal may be held for the whole (wait-stated) access, so count its
    // RISING EDGE: one count per transaction, not per stalled cycle.
    reg ide_q, exp1_q;
    wire ide_edge  = ide_acc  & ~ide_q;
    wire exp1_edge = exp1_acc & ~exp1_q;

    // {visible counter, fractional prescale} pairs. The prescale bits are the low
    // bits of the same counter, so nothing is lost between polls.
    reg [25:0] c_flash, c_dio, c_cd;      // 16 visible + 10 fraction
    reg [15:0] c_sect, c_frame;
    reg [19:0] c_ide;                     // 16 visible + 4 fraction
    reg [21:0] c_exp1;                    // 16 visible + 6 fraction

    always @(posedge clk) begin
        ide_q  <= ide_acc;
        exp1_q <= exp1_acc;
        if (rst) begin
            c_flash <= 0; c_dio <= 0; c_cd <= 0;
            c_sect  <= 0; c_frame <= 0; c_ide <= 0; c_exp1 <= 0;
            ide_q   <= 1'b0; exp1_q <= 1'b0;
        end else begin
            if (flash_wait) c_flash <= c_flash + 1'b1;
            if (dio_wait)   c_dio   <= c_dio   + 1'b1;
            if (cd_busy)    c_cd    <= c_cd    + 1'b1;
            if (sec_done)   c_sect  <= c_sect  + 1'b1;
            if (wdog_kick)  c_frame <= c_frame + 1'b1;
            if (ide_edge)   c_ide   <= c_ide   + 1'b1;
            if (exp1_edge)  c_exp1  <= c_exp1  + 1'b1;
        end
    end

    assign prof_flash_k = c_flash[25:10];
    assign prof_dio_k   = c_dio[25:10];
    assign prof_cd_k    = c_cd[25:10];
    assign prof_sectors = c_sect;
    assign prof_frames  = c_frame;
    assign prof_ide     = c_ide[19:4];
    assign prof_exp1    = c_exp1[21:6];
endmodule
