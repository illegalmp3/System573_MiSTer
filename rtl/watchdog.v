// -----------------------------------------------------------------------------
// watchdog.v - Konami System 573 board watchdog
//
// The 573's watchdog lives in the Konami 058232 power-on-reset / coin-counter chip
// (psx-spx registers.md "0x1f5c0000"): any write to 0x1f5c0000 clears it; if it is
// not cleared for 350-400 ms it pulls the reset line low for about 50 ms; jumper
// S86 disables it. This models the counter: every `kick` pulse reloads it; at the
// timeout `reset_out` pulses for one clock (the ~50 ms hold is not modelled).
//
// In the build the bite is NOT wired to the core reset (rtl/emu.sv leaves
// wdog_reset open) -- the equivalent of a board with S86 fitted. Core-side stalls
// that a real board never has (flash/.sav traffic through the HPS, OSD pause)
// could otherwise trip it. docs/2026-11-02-source-review.md, "HLE inventory".
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module watchdog #(
    parameter integer TIMEOUT_CYCLES = 32'd11_854_080 // 350 ms at 33.8688 MHz
)(
    input  wire clk,
    input  wire rst,        // synchronous reset, active high
    input  wire kick,       // 1-cycle pulse: CPU wrote the watchdog clear window
    output reg  reset_out   // 1-cycle pulse when the watchdog bites
);
    // Width sized to hold TIMEOUT_CYCLES.
    localparam integer CW = 32;
    reg [CW-1:0] cnt;

    always @(posedge clk) begin
        if (rst) begin
            cnt       <= {CW{1'b0}};
            reset_out <= 1'b0;
        end else begin
            reset_out <= 1'b0;
            if (kick) begin
                cnt <= {CW{1'b0}};
            end else if (cnt >= (TIMEOUT_CYCLES - 1)) begin
                cnt       <= {CW{1'b0}};
                reset_out <= 1'b1;   // bite
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end
endmodule
