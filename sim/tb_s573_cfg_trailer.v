// tb_s573_cfg_trailer.v - the index-5 path end to end: s573_seccart_loader ->
// s573_cfg_trailer -> s573_cass_pack, driven like emu.sv drives it (WIDE ioctl words).
//
// For each file shape the cassette side must see EXACTLY what it saw before the
// trailer existed -- same serial bytes, same install EEPROM bytes, same
// install-present / chip-type verdict -- and the trailer must be reported (or not):
//   1. plain 8-byte .u6                       -> unchanged, no trailer
//   2. .u6 + trailer                          -> as 1, trailer valid
//   3. X76F100 pack (148 B) / + trailer       -> X76F100 install, trailer
//   4. X76F041 pack (564 B) / + trailer       -> X76F041 install, trailer
//   5. .u6 + 8 bytes with a BAD checksum      -> all 16 bytes passed on, no trailer
//   6. a 6-byte file                          -> flushed, no trailer
//   7. back-to-back loads: a trailer does not survive into a load without one
`timescale 1ns/1ps
module tb_s573_cfg_trailer;
    reg clk = 0; always #5 clk = ~clk;
    reg download = 0, ioctl_wr = 0;
    reg [9:0] ioctl_addr = 0;
    reg [15:0] ioctl_dout = 0;

    wire lb_we; wire [9:0] lb_addr; wire [7:0] lb_data; wire lb_nvhi; wire [9:0] lb_max;
    s573_seccart_loader #(.AW(10)) ld (.clk(clk), .load_en(download), .ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .byte_we(lb_we), .byte_addr(lb_addr),
        .byte_data(lb_data), .nv_hi(lb_nvhi), .max_addr(lb_max));
    wire t_we; wire [9:0] t_addr; wire [7:0] t_data; wire [9:0] t_max; wire t_busy, t_valid;
    wire [7:0] t_prof, t_card;
    s573_cfg_trailer tr (.clk(clk), .download(download), .in_we(lb_we), .in_addr(lb_addr),
        .in_data(lb_data), .out_we(t_we), .out_addr(t_addr), .out_data(t_data), .max_addr(t_max),
        .busy(t_busy), .valid(t_valid), .profile(t_prof), .card(t_card));
    wire ser_we, iser_we, ieep_we; wire [2:0] ser_a, iser_a; wire [7:0] ser_d, iser_d, ieep_d;
    wire [9:0] ieep_a; wire inst_present, inst_type;
    s573_cass_pack pk (.clk(clk), .download(t_busy), .byte_we(t_we), .byte_addr(t_addr),
        .byte_data(t_data), .max_addr(t_max), .ser_we(ser_we), .ser_addr(ser_a), .ser_data(ser_d),
        .iser_we(iser_we), .iser_addr(iser_a), .iser_data(iser_d), .ieep_we(ieep_we),
        .ieep_addr(ieep_a), .ieep_data(ieep_d), .inst_present(inst_present), .inst_type(inst_type));

    reg [7:0] ser [0:7]; reg [7:0] iser [0:7]; reg [7:0] ieep [0:1023];
    integer nser, niser, nieep;
    always @(posedge clk) begin
        if (ser_we)  begin ser[ser_a]   <= ser_d;  nser  = nser + 1;  end
        if (iser_we) begin iser[iser_a] <= iser_d; niser = niser + 1; end
        if (ieep_we) begin ieep[ieep_a] <= ieep_d; nieep = nieep + 1; end
    end

    reg [7:0] file [0:1023];
    integer errs = 0, k;

    task load(input integer len);
        integer w;
        begin
            nser = 0; niser = 0; nieep = 0;
            for (k = 0; k < 1024; k = k + 1) ieep[k] = 8'hxx;
            @(negedge clk); download = 1;
            repeat (3) @(negedge clk);
            for (w = 0; w < len; w = w + 2) begin
                ioctl_addr = w; ioctl_dout = {file[w+1], file[w]}; ioctl_wr = 1;
                @(negedge clk); ioctl_wr = 0;
                repeat ((w % 6) + 1) @(negedge clk);   // irregular gaps, incl. back-to-back
            end
            download = 0;
            repeat (40) @(negedge clk);
        end
    endtask

    task fill(input integer len, input integer seed);
        begin for (k = 0; k < len; k = k + 1) file[k] = (k * 37 + seed) & 8'hff; end
    endtask
    task add_trailer(input integer at, input [7:0] prof, input [7:0] crd, input bad);
        begin
            file[at] = "S"; file[at+1] = "5"; file[at+2] = "7"; file[at+3] = "3"; file[at+4] = "C";
            file[at+5] = prof; file[at+6] = crd;
            file[at+7] = file[at] ^ file[at+1] ^ file[at+2] ^ file[at+3] ^ file[at+4] ^ prof ^ crd ^ (bad ? 8'h01 : 8'h00);
        end
    endtask
    task check_case(input [255:0] name, input integer datalen, input exp_valid, input [7:0] exp_prof,
                input exp_inst, input exp_type);
        integer bad;
        begin
            bad = 0;
            for (k = 0; k < 8 && k < datalen; k = k + 1) if (ser[k] !== file[k]) bad = 1;
            if (datalen > 8)  for (k = 8; k < 16 && k < datalen; k = k + 1) if (iser[k-8] !== file[k]) bad = 1;
            if (datalen > 16) for (k = 16; k < datalen; k = k + 1) if (ieep[k-16] !== file[k]) bad = 1;
            if (nser + niser + nieep != datalen) bad = 1;
            if (t_valid !== exp_valid || (exp_valid && t_prof !== exp_prof)) bad = 1;
            if (inst_present !== exp_inst || (exp_inst && inst_type !== exp_type)) bad = 1;
            if (bad) begin
                errs = errs + 1;
                $display("FAIL %0s: writes %0d (want %0d) valid=%b prof=%0d inst=%b type=%b",
                         name, nser + niser + nieep, datalen, t_valid, t_prof, inst_present, inst_type);
            end else
                $display("  ok %0s", name);
        end
    endtask

    initial begin
        repeat (5) @(negedge clk);
        fill(8, 1);                       load(8);   check_case("u6",               8,   0, 0, 0, 0);
        fill(8, 2); add_trailer(8, 2, 0, 0); load(16); check_case("u6+trailer",     8,   1, 2, 0, 0);
        fill(148, 3);                     load(148); check_case("x76f100 pack",     148, 0, 0, 1, 0);
        fill(148, 4); add_trailer(148, 0, 1, 0); load(156); check_case("x76f100 pack+trailer", 148, 1, 0, 1, 0);
        fill(564, 5);                     load(564); check_case("x76f041 pack",     564, 0, 0, 1, 1);
        fill(564, 6); add_trailer(564, 3, 2, 0); load(572); check_case("x76f041 pack+trailer", 564, 1, 3, 1, 1);
        if (t_card !== 8'd2) begin errs = errs + 1; $display("FAIL card byte %0d", t_card); end
        fill(8, 7); add_trailer(8, 2, 0, 1); load(16); check_case("bad checksum",   16,  0, 0, 0, 0);
        fill(6, 8);                       load(6);   check_case("6-byte file",      6,   0, 0, 0, 0);
        fill(8, 9); add_trailer(8, 1, 0, 0); load(16); check_case("trailer again",  8,   1, 1, 0, 0);
        fill(8, 10);                      load(8);   check_case("then none",        8,   0, 0, 0, 0);
        $display("RESULT: %s (s573_cfg_trailer: %0d failures)", errs ? "FAIL" : "PASS", errs);
        $finish;
    end
endmodule
