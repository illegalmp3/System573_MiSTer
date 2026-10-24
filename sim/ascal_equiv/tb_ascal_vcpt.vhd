-- tb_ascal_vcpt.vhd -- psx_patches/0033 equivalence check.
-- Two ascal scalers driven by the same input video, output timing, avalon model and
-- parameter changes: u_ref = the pinned upstream ascal.vhd (entity renamed ascal_ref),
-- u_dut = psx/sys/ascal.vhd with 0033 applied. Every o_clk cycle, every output
-- (o_r/g/b, o_hs/vs/de/vbl/brd, o_lltune) and both avalon request buses must be
-- equal, and the internal line counter o_vcpt_pre3 must match.
-- Phases: o_ce every clock / every 2nd / pseudo-random; vtotal + vsync position
-- changed at several line positions; VRR on with the input frame both faster
-- and slower than the output frame (o_vrr_sync2 must fire for the jump path).
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY tb_ascal_vcpt IS
END ENTITY;

ARCHITECTURE sim OF tb_ascal_vcpt IS
  SUBTYPE uint12 IS natural RANGE 0 TO 4095;
  SIGNAL i_clk, o_clk, a_clk : std_logic := '0';
  SIGNAL done : boolean := false;
  SIGNAL rst_n : std_logic := '0';

  -- input video
  SIGNAL ihtot : natural := 36;
  SIGNAL ivtot : natural := 30;
  SIGNAL ihc, ivc : natural := 0;
  SIGNAL i_r, i_g, i_b : unsigned(7 DOWNTO 0) := x"00";
  SIGNAL i_hs, i_vs, i_de, i_ce : std_logic := '0';

  -- output timing
  SIGNAL o_ce : std_logic := '1';
  SIGNAL htotal  : uint12 := 50;
  SIGNAL hsstart : uint12 := 42;
  SIGNAL hsend   : uint12 := 45;
  SIGNAL hdisp   : uint12 := 40;
  SIGNAL hmax    : uint12 := 39;
  SIGNAL vtotal  : uint12 := 30;
  SIGNAL vsstart : uint12 := 26;
  SIGNAL vsend   : uint12 := 28;
  SIGNAL vdisp   : uint12 := 24;
  SIGNAL vmax    : uint12 := 23;
  SIGNAL vrr     : std_logic := '0';
  SIGNAL vrrmax  : uint12 := 40;

  TYPE outs_t IS RECORD
    r, g, b : unsigned(7 DOWNTO 0);
    hs, vs, de, vbl, brd : std_logic;
    lltune : unsigned(15 DOWNTO 0);
    rd, wr : std_logic;
    adr : std_logic_vector(27 DOWNTO 0);
    bc  : std_logic_vector(7 DOWNTO 0);
    wd  : std_logic_vector(127 DOWNTO 0);
    be  : std_logic_vector(15 DOWNTO 0);
  END RECORD;
  SIGNAL ref, dut : outs_t;
  SIGNAL ref_rdv, dut_rdv : std_logic := '0';
  SIGNAL ref_rdd, dut_rdd : std_logic_vector(127 DOWNTO 0) := (OTHERS => '0');

  SIGNAL ncyc, nmis, nvs, nlines_seen, nvrr : natural := 0;
  SIGNAL phase : natural := 0;
BEGIN
  i_clk <= NOT i_clk AFTER 5 ns WHEN NOT done;
  o_clk <= NOT o_clk AFTER 3.5 ns WHEN NOT done;
  a_clk <= NOT a_clk AFTER 4.5 ns WHEN NOT done;

  -- input video: 32x24 active in ihtot x ivtot, one pixel per clock
  PROCESS (i_clk)
  BEGIN
    IF rising_edge(i_clk) THEN
      i_ce <= '1';
      IF ihc + 1 >= ihtot THEN
        ihc <= 0;
        IF ivc + 1 >= ivtot THEN ivc <= 0; ELSE ivc <= ivc + 1; END IF;
      ELSE
        ihc <= ihc + 1;
      END IF;
      i_de <= '0';
      IF ihc < 32 AND ivc < 24 THEN i_de <= '1'; END IF;
      i_hs <= '0';
      IF ihc >= 33 AND ihc < 35 THEN i_hs <= '1'; END IF;
      i_vs <= '0';
      IF ivc >= 26 AND ivc < 28 THEN i_vs <= '1'; END IF;
      i_r <= to_unsigned((ihc * 7 + ivc) MOD 256, 8);
      i_g <= to_unsigned((ivc * 11) MOD 256, 8);
      i_b <= to_unsigned((ihc + ivc * 3) MOD 256, 8);
    END IF;
  END PROCESS;

  -- avalon slave model, one per scaler (identical behaviour)
  avl_ref : PROCESS (a_clk)
    VARIABLE left : natural := 0;
    VARIABLE dly  : natural := 0;
    VARIABLE adr  : unsigned(27 DOWNTO 0);
  BEGIN
    IF rising_edge(a_clk) THEN
      ref_rdv <= '0';
      IF left > 0 THEN
        IF dly > 0 THEN dly := dly - 1;
        ELSE
          ref_rdv <= '1';
          ref_rdd <= std_logic_vector(adr) & std_logic_vector(adr + 1) & std_logic_vector(NOT adr) & x"5a5a5a5a" & x"a5a";
          adr := adr + 1;
          left := left - 1;
        END IF;
      ELSIF ref.rd = '1' THEN
        left := to_integer(unsigned(ref.bc));
        adr := unsigned(ref.adr);
        dly := 3;
      END IF;
    END IF;
  END PROCESS;
  avl_dut : PROCESS (a_clk)
    VARIABLE left : natural := 0;
    VARIABLE dly  : natural := 0;
    VARIABLE adr  : unsigned(27 DOWNTO 0);
  BEGIN
    IF rising_edge(a_clk) THEN
      dut_rdv <= '0';
      IF left > 0 THEN
        IF dly > 0 THEN dly := dly - 1;
        ELSE
          dut_rdv <= '1';
          dut_rdd <= std_logic_vector(adr) & std_logic_vector(adr + 1) & std_logic_vector(NOT adr) & x"5a5a5a5a" & x"a5a";
          adr := adr + 1;
          left := left - 1;
        END IF;
      ELSIF dut.rd = '1' THEN
        left := to_integer(unsigned(dut.bc));
        adr := unsigned(dut.adr);
        dly := 3;
      END IF;
    END IF;
  END PROCESS;

  u_ref : ENTITY work.ascal_ref
    GENERIC MAP (MASK => x"F7", RAMBASE => x"20000000", RAMSIZE => x"00800000",
                 PALETTE => false, PALETTE2 => false, DOWNSCALE_NN => true,
                 FRAC => 8, N_DW => 128, N_AW => 28)
    PORT MAP (
      i_r => i_r, i_g => i_g, i_b => i_b, i_hs => i_hs, i_vs => i_vs, i_fl => '0',
      i_de => i_de, i_ce => i_ce, i_clk => i_clk,
      o_r => ref.r, o_g => ref.g, o_b => ref.b, o_hs => ref.hs, o_vs => ref.vs,
      o_de => ref.de, o_vbl => ref.vbl, o_brd => ref.brd, o_ce => o_ce, o_clk => o_clk,
      o_lltune => ref.lltune, iauto => '1',
      mode => "00000", htotal => htotal, hsstart => hsstart, hsend => hsend,
      hdisp => hdisp, hmin => 0, hmax => hmax, vtotal => vtotal, vsstart => vsstart,
      vsend => vsend, vdisp => vdisp, vmin => 0, vmax => vmax, vrr => vrr, vrrmax => vrrmax,
      poly_clk => a_clk, poly_dw => (OTHERS => '0'), poly_a => (OTHERS => '0'), poly_wr => '0',
      avl_clk => a_clk, avl_waitrequest => '0', avl_readdata => ref_rdd,
      avl_readdatavalid => ref_rdv, avl_burstcount => ref.bc, avl_writedata => ref.wd,
      avl_address => ref.adr, avl_write => ref.wr, avl_read => ref.rd,
      avl_byteenable => ref.be, reset_na => rst_n);

  u_dut : ENTITY work.ascal
    GENERIC MAP (MASK => x"F7", RAMBASE => x"20000000", RAMSIZE => x"00800000",
                 PALETTE => false, PALETTE2 => false, DOWNSCALE_NN => true,
                 FRAC => 8, N_DW => 128, N_AW => 28)
    PORT MAP (
      i_r => i_r, i_g => i_g, i_b => i_b, i_hs => i_hs, i_vs => i_vs, i_fl => '0',
      i_de => i_de, i_ce => i_ce, i_clk => i_clk,
      o_r => dut.r, o_g => dut.g, o_b => dut.b, o_hs => dut.hs, o_vs => dut.vs,
      o_de => dut.de, o_vbl => dut.vbl, o_brd => dut.brd, o_ce => o_ce, o_clk => o_clk,
      o_lltune => dut.lltune, iauto => '1',
      mode => "00000", htotal => htotal, hsstart => hsstart, hsend => hsend,
      hdisp => hdisp, hmin => 0, hmax => hmax, vtotal => vtotal, vsstart => vsstart,
      vsend => vsend, vdisp => vdisp, vmin => 0, vmax => vmax, vrr => vrr, vrrmax => vrrmax,
      poly_clk => a_clk, poly_dw => (OTHERS => '0'), poly_a => (OTHERS => '0'), poly_wr => '0',
      avl_clk => a_clk, avl_waitrequest => '0', avl_readdata => dut_rdd,
      avl_readdatavalid => dut_rdv, avl_burstcount => dut.bc, avl_writedata => dut.wd,
      avl_address => dut.adr, avl_write => dut.wr, avl_read => dut.rd,
      avl_byteenable => dut.be, reset_na => rst_n);

  -- compare every output clock
  cmp : PROCESS (o_clk)
    ALIAS ref_v IS << SIGNAL .tb_ascal_vcpt.u_ref.o_vcpt_pre3 : uint12 >>;
    ALIAS dut_v IS << SIGNAL .tb_ascal_vcpt.u_dut.o_vcpt_pre3 : uint12 >>;
    ALIAS dut_vrr IS << SIGNAL .tb_ascal_vcpt.u_dut.o_vrr_sync2 : boolean >>;
    VARIABLE vs_d : std_logic := '0';
    VARIABLE v_d : uint12 := 0;
  BEGIN
    IF falling_edge(o_clk) AND rst_n = '1' THEN
      ncyc <= ncyc + 1;
      IF ref /= dut OR ref_v /= dut_v THEN
        IF nmis < 20 THEN
          REPORT "MISMATCH phase " & integer'image(phase) & " cycle " & integer'image(ncyc) &
                 " vcpt ref " & integer'image(ref_v) & " dut " & integer'image(dut_v) &
                 " hs " & std_logic'image(ref.hs) & std_logic'image(dut.hs) &
                 " vs " & std_logic'image(ref.vs) & std_logic'image(dut.vs) &
                 " de " & std_logic'image(ref.de) & std_logic'image(dut.de) SEVERITY warning;
        END IF;
        nmis <= nmis + 1;
      END IF;
      IF ref.vs = '1' AND vs_d = '0' THEN nvs <= nvs + 1; END IF;
      IF ref_v /= v_d THEN nlines_seen <= nlines_seen + 1; END IF;
      IF dut_vrr AND o_ce = '1' THEN nvrr <= nvrr + 1; END IF;
      vs_d := ref.vs;
      v_d := ref_v;
    END IF;
  END PROCESS;

  -- o_ce pattern per phase
  ce : PROCESS (o_clk)
    VARIABLE lfsr : unsigned(15 DOWNTO 0) := x"ACE1";
    VARIABLE t : std_logic := '0';
  BEGIN
    IF rising_edge(o_clk) THEN
      lfsr := lfsr(14 DOWNTO 0) & (lfsr(15) XOR lfsr(13) XOR lfsr(12) XOR lfsr(10));
      t := NOT t;
      CASE phase IS
        WHEN 2 => o_ce <= t;
        WHEN 3 | 6 => o_ce <= lfsr(0) OR lfsr(3);
        WHEN OTHERS => o_ce <= '1';
      END CASE;
    END IF;
  END PROCESS;

  stim : PROCESS
    ALIAS ref_h IS << SIGNAL .tb_ascal_vcpt.u_ref.o_hcpt : uint12 >>;
    -- change timing at output line position `pos` (o_hcpt of the reference)
    PROCEDURE at_hpos(pos : natural) IS
    BEGIN
      LOOP
        WAIT UNTIL rising_edge(o_clk);
        EXIT WHEN ref_h = pos;
      END LOOP;
    END PROCEDURE;
    PROCEDURE frames(n : natural) IS
      VARIABLE s : natural;
    BEGIN
      s := nvs;
      WAIT UNTIL nvs >= s + n;
    END PROCEDURE;
  BEGIN
    WAIT FOR 100 ns;
    rst_n <= '1';
    phase <= 1; frames(6);                                   -- o_ce every clock
    phase <= 2; frames(6);                                   -- o_ce every 2nd clock
    phase <= 3; frames(6);                                   -- pseudo-random o_ce
    phase <= 4;                                              -- mode changes mid-line
    at_hpos(20); vtotal <= 34; vsstart <= 29; vsend <= 31; frames(4);
    at_hpos(5);  vtotal <= 27; vsstart <= 25; vsend <= 26; vdisp <= 22; vmax <= 21; frames(4);
    at_hpos(30); htotal <= 47; hsstart <= 42; hsend <= 44; frames(4);
    at_hpos(25); vtotal <= 30; vsstart <= 26; vsend <= 28; vdisp <= 24; vmax <= 23; htotal <= 50; frames(4);
    phase <= 5;                                              -- VRR, input frame faster
    vrr <= '1'; vrrmax <= 40; ihtot <= 36; ivtot <= 26; frames(10);
    ivtot <= 34; frames(10);                                 -- input frame slower
    phase <= 6; ivtot <= 27; frames(10);                     -- VRR + random o_ce
    vrr <= '0'; ivtot <= 30; frames(4);
    REPORT "cycles " & integer'image(ncyc) & " frames " & integer'image(nvs) &
           " line steps " & integer'image(nlines_seen) & " vrr jumps " & integer'image(nvrr) &
           " mismatches " & integer'image(nmis);
    IF nmis = 0 AND nvs > 60 AND nvrr > 0 THEN
      REPORT "PASS";
    ELSE
      REPORT "FAIL" SEVERITY error;
    END IF;
    done <= true;
    WAIT;
  END PROCESS;
END ARCHITECTURE;
