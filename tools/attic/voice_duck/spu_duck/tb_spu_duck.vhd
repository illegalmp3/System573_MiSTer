-- tb_spu_duck: psx_patches 0035 on the real spu.vhd (GHDL). One voice playing the SPU
-- noise generator (no sample RAM needed) at full volume; the run is repeated per
-- generic DUCK_MODE / DUCK_VOICE and the output written to a text file. The check
-- (run_spu_duck.sh) compares runs sample by sample: mode 00 must equal the voice not
-- being ducked; 01 = half, 10 = quarter, 11 = silence.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;
library psx;

entity tb_spu_duck is
   generic (DUCK_MODE : integer := 0; DUCK_VOICE : integer := 0; OUTFILE : string := "out.txt");
end entity;

architecture arch of tb_spu_duck is
   signal clk1x, clk2x : std_logic := '1';
   signal clk2xIndex   : std_logic := '0';
   signal clk1xToggle, clk1xToggle2x : std_logic := '0';
   signal reset        : std_logic := '1';
   signal bus_addr     : unsigned(9 downto 0) := (others => '0');
   signal bus_dataWrite: std_logic_vector(15 downto 0) := (others => '0');
   signal bus_write    : std_logic := '0';
   signal sdram_ena, sdram_rnw : std_logic;
   signal sdram_done   : std_logic := '0';
   signal sdram_Adr    : std_logic_vector(18 downto 0);
   signal spu_tick     : std_logic;
   signal outl, outr   : std_logic_vector(15 downto 0);
   signal duck         : std_logic_vector(23 downto 0) := (others => '0');
   signal mem_ack, mem_ready : std_logic := '0';
   signal done_sim     : boolean := false;
   signal n_req, n_done : integer := 0;
begin
   clk1x <= not clk1x after 15 ns;
   clk2x <= not clk2x after 7.5 ns;
   -- clock index, exactly as upstream psx/sim/spu/src/tb/tb.vhd
   process (clk1x) begin if rising_edge(clk1x) then clk1xToggle <= not clk1xToggle; end if; end process;
   process (clk2x) begin
      if rising_edge(clk2x) then
         clk1xToggle2x <= clk1xToggle;
         clk2xIndex    <= '0';
         if (clk1xToggle2x = clk1xToggle) then clk2xIndex <= '1'; end if;
      end if;
   end process;
   duck(DUCK_VOICE) <= '1';

   -- SPU RAM in "SDRAM": answer every request with zeros two clocks later
   -- (one answer per request: sdram_ena is held until sdram_done, so a request is
   -- only taken when idle and not in the cycle right after an answer)
   process (clk1x)
      variable cnt  : integer := 0;
      variable hold : boolean := false;
   begin
      if rising_edge(clk1x) then
         sdram_done <= '0';
         if sdram_done = '1' then n_done <= n_done + 1; end if;
         if cnt > 0 then
            cnt := cnt - 1;
            if cnt = 0 then sdram_done <= '1'; hold := true; end if;
         elsif hold then
            hold := false;
         elsif sdram_ena = '1' then
            cnt := 2; n_req <= n_req + 1;
         end if;
      end if;
   end process;

   -- debug: voice 0's per-sample values while it is processed (first samples only)
   process (clk1x)
      alias idx  is <<signal .tb_spu_duck.ispu.index : integer range 0 to 23>>;
      alias smp  is <<signal .tb_spu_duck.ispu.sample : signed(15 downto 0)>>;
      alias vol  is <<signal .tb_spu_duck.ispu.volume : signed(16 downto 0)>>;
      alias chl  is <<signal .tb_spu_duck.ispu.chanLeft : signed(17 downto 0)>>;
      alias adv  is <<signal .tb_spu_duck.ispu.adsrVolumeNew : signed(15 downto 0)>>;
      alias nl   is <<signal .tb_spu_duck.ispu.noiseLevel : unsigned(15 downto 0)>>;
      variable shown : integer := 0;
      variable s0, v0, c0, a0 : integer := 0;
      variable n0 : unsigned(15 downto 0);
   begin
      if rising_edge(clk1x) then
         if idx = 0 then
            s0 := to_integer(smp); v0 := to_integer(vol); c0 := to_integer(chl); a0 := to_integer(adv); n0 := nl;
         end if;
         if spu_tick = '1' and shown < 12 and reset = '0' then
            shown := shown + 1;
            report "v0: sample=" & integer'image(s0) & " vol=" & integer'image(v0) &
                   " chanL=" & integer'image(c0) & " adsrNew=" & integer'image(a0) & " noise=" & to_hstring(n0);
         end if;
      end if;
   end process;

   ispu : entity psx.spu
   port map (
      clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, ce => '1', reset => reset,
      SPUon => '1', SPUIRQTrigger => '0', useSDRAM => '1', REPRODUCIBLESPUIRQ => '0', REPRODUCIBLESPUDMA => '0',
      REVERBOFF => '1', cpuPaused => '0', spu_tick => spu_tick, cd_left => (others => '0'), cd_right => (others => '0'),
      irqOut => open, sound_timeout => open, sound_out_left => outl, sound_out_right => outr,
      bus_addr => bus_addr, bus_dataWrite => bus_dataWrite, bus_read => '0', bus_write => bus_write, bus_dataRead => open,
      spu_dmaRequest => open, dma_read => '0', dma_readdata => open, dma_write => '0', dma_writedata => (others => '0'),
      sdram_dataWrite => open, sdram_Adr => sdram_Adr, sdram_be => open, sdram_rnw => sdram_rnw, sdram_ena => sdram_ena,
      sdram_dataRead => (others => '0'), sdram_done => sdram_done,
      mem_request => open, mem_BURSTCNT => open, mem_ADDR => open, mem_DIN => open, mem_BE => open, mem_WE => open, mem_RD => open,
      mem_ack => '0', mem_DOUT => (others => '0'), mem_DOUT_READY => '0',
      SS_reset => '0', loading_savestate => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren => '0', SS_rden => '0', SS_DataRead => open, SS_idle => open,
      SS_RAM_dataWrite => (others => '0'), SS_RAM_Adr => (others => '0'), SS_RAM_request => '0', SS_RAM_rnw => '0',
      SS_RAM_dataRead => open, SS_RAM_done => open,
      s573_duck => duck, s573_duck_mode => std_logic_vector(to_unsigned(DUCK_MODE, 2)));

   process
      procedure wr(a : integer; d : std_logic_vector(15 downto 0)) is
      begin
         wait until rising_edge(clk1x);
         bus_addr <= to_unsigned(a, 10); bus_dataWrite <= d; bus_write <= '1';
         wait until rising_edge(clk1x);
         bus_write <= '0';
         for i in 0 to 20 loop wait until rising_edge(clk1x); end loop;
      end procedure;
      file f : text open write_mode is OUTFILE;
      variable l : line;
      variable n : integer := 0;
   begin
      for i in 0 to 50 loop wait until rising_edge(clk1x); end loop;
      reset <= '0';
      for i in 0 to 50 loop wait until rising_edge(clk1x); end loop;
      wr(16#1AA#, x"FF00");          -- SPUCNT: enable, unmute, noise shift 15 step 3 (fastest)
      wr(16#180#, x"3FFF"); wr(16#182#, x"3FFF");     -- main volume
      wr(16#000#, x"3FFF"); wr(16#002#, x"3FFF");     -- voice 0 volume
      wr(16#004#, x"1000");                            -- pitch
      wr(16#006#, x"0200");                            -- start address
      wr(16#008#, x"000F"); wr(16#00A#, x"0000");      -- ADSR: fastest attack, sustain level max
      wr(16#194#, x"0001");                            -- voice 0: noise
      wr(16#188#, x"0001");                            -- KEYON voice 0
      while n < 300 loop
         wait until rising_edge(clk1x);
         if spu_tick = '1' then
            n := n + 1;
            if (n mod 25) = 0 then
               report "n=" & integer'image(n) &
                  " CNT=" & to_hstring(<<signal .tb_spu_duck.ispu.CNT : std_logic_vector(15 downto 0)>>) &
                  " VOL=" & to_hstring(<<signal .tb_spu_duck.ispu.VOLUME_LEFT : std_logic_vector(15 downto 0)>>) &
                  " CURVOL=" & to_hstring(<<signal .tb_spu_duck.ispu.CURVOL_L : std_logic_vector(15 downto 0)>>) &
                  " NOISE=" & to_hstring(<<signal .tb_spu_duck.ispu.NOISEMODE : std_logic_vector(31 downto 0)>>) &
                  " ENDX=" & to_hstring(<<signal .tb_spu_duck.ispu.ENDX : std_logic_vector(31 downto 0)>>) &
                  " soundleft=" & integer'image(to_integer(<<signal .tb_spu_duck.ispu.soundleft : signed(23 downto 0)>>)) &
                  " adsrVol=" & integer'image(to_integer(<<signal .tb_spu_duck.ispu.adsrVolume : signed(15 downto 0)>>)) &
                  " outl=" & integer'image(to_integer(signed(outl))) &
                  " KEYON=" & to_hstring(<<signal .tb_spu_duck.ispu.KEYON : std_logic_vector(31 downto 0)>>) &
                  " req=" & integer'image(n_req) & " done=" & integer'image(n_done) & " ena=" & std_logic'image(sdram_ena);
            end if;
            if n > 100 then
               write(l, to_integer(signed(outl))); write(l, string'(" ")); write(l, to_integer(signed(outr)));
               writeline(f, l);
            end if;
         end if;
      end loop;
      report "done" severity note;
      done_sim <= true;
      std.env.finish;
   end process;
end architecture;
