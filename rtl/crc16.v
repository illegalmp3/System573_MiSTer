// -----------------------------------------------------------------------------
// crc16.v - CRC-16/CCITT engine (polynomial 0x1021), MSB-first, no reflection
//
// The System 573 ZS01 (NS2K001) security cartridge attaches a 16-bit CRC to
// every 12-byte command/response packet: the CRC is computed over the first ten
// bytes (poly 0x1021) and stored big-endian in the last two.
//
// NOT USED by the build: zs01.v computes its packet CRC itself (psx-spx
// security-cartridges.md "ZS01 protocol": init 0xffff, MSB first, result
// inverted). This engine is kept with its bench; nothing instantiates it, so
// Quartus drops it. (An earlier note here said the CRC also appears on the ATAPI
// and Digital I/O paths; no source says so.)
//
// Parameterized by polynomial and initial value so the same module covers both
// the common CRC-CCITT variants (XMODEM: init 0x0000; CCITT-FALSE: init 0xFFFF)
// and the ZS01 packet CRC's polynomial and seed (psx-spx gives both).
// Bytes are fed in MSB-first; assert `load` to (re)seed, then pulse `stb` once
// per byte. `crc` holds the running remainder.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module crc16 #(
    parameter [15:0] POLY = 16'h1021,
    parameter [15:0] INIT = 16'hFFFF
)(
    input  wire        clk,
    input  wire        load,       // synchronous reseed to INIT
    input  wire        stb,        // process one byte on `data`
    input  wire [7:0]  data,
    output reg  [15:0] crc
);
    // One byte of CRC-16 update: xor the byte into the high half, then run
    // eight shifts, xoring the polynomial whenever the top bit falls out.
    function [15:0] crc_byte(input [15:0] c, input [7:0] d);
        integer i;
        reg [15:0] x;
        begin
            x = c ^ {d, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                x = x[15] ? ((x << 1) ^ POLY) : (x << 1);
            crc_byte = x;
        end
    endfunction

    always @(posedge clk) begin
        if (load)
            crc <= INIT;
        else if (stb)
            crc <= crc_byte(crc, data);
    end
endmodule
