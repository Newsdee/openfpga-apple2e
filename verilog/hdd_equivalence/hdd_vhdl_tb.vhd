-------------------------------------------------------------------------------
-- HDD equivalence harness - GHDL GOLDEN (original VHDL via documented shim)
--
-- Instantiates golden/hdd.vhd (byte-for-byte copy of
-- Apple-II_MiSTer/rtl/hdd.vhd with a 4-line case-construct shim for GHDL 6 -
-- see that file's header) + the ORIGINAL hdd_rom.vhd. Drives the shared
-- stimulus schedule (identical to hdd_verilog_tb.sv - keep in lockstep) and
-- writes a per-cycle CSV trace for run_equivalence.ps1 to compare
-- field-by-field against the Verilator candidate trace.
--
-- TRACE INVARIANT (both TBs): stim(0) is set at t=0. Loop: wait until the
-- falling edge, trace row c (state after the DUT processed stim(c), fully
-- settled), then set stim(c+1).
--
-- Schedule (cycles c):
--   0..3      reset
--   10..265   ROM sweep: IO_SELECT, RD=1, A = C600 + (c-10)      [256 addrs]
--   266..267  ROM drain: hold IO_SELECT + A=C6FF (2-stage readout)
--   300..399  REG round-trips: C0F3..C0F7 write/read, DS strobed
--   500..699  EXE: C0F0 execute matrix + pseudo-mix, DS strobed
--   798..800  arm READ (unit=70, cmd=01), execute (sec_addr -> 0)
--   802..1825 WALK: 512x C0F8 write, 1 idle cycle between strobes
--   1900..2923 VERIFY1: 512x C0F8 read (CPU port read-back + 511->0 wrap)
--   3000..4023 RAMREAD: 512x ram port read (ram_do)
--   4100..5123 RAMWRITE: 512x ram port write (ram_we)
--   5200..6223 VERIFY2: 512x C0F8 read of the ram-written pattern
--   6300..6359 CMD02: 10x C0F8 write, then C0F2=02 (sec_addr reset)
--   6400..6440 HOLD: DS held across 4 C0F8 reads (latched-increment case)
--   7000..    idle
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity hdd_vhdl_tb is
  generic (
    TRACE_FILE : string := "build/vhdl_trace.csv"
  );
end entity;

architecture test of hdd_vhdl_tb is
  signal clk : std_logic := '0';
  signal reset : std_logic := '0';
  signal io_select : std_logic := '0';
  signal device_select : std_logic := '0';
  signal a : unsigned(15 downto 0) := (others => '0');
  signal rd : std_logic := '0';
  signal d_in : unsigned(7 downto 0) := (others => '0');
  signal d_out : unsigned(7 downto 0);
  signal sector : unsigned(15 downto 0);
  signal hdd_read : std_logic;
  signal hdd_write : std_logic;
  signal hdd_mounted : std_logic := '0';
  signal hdd_protect : std_logic := '0';
  signal ram_addr : unsigned(8 downto 0) := (others => '0');
  signal ram_di : unsigned(7 downto 0) := (others => '0');
  signal ram_do : unsigned(7 downto 0);
  signal ram_we : std_logic := '0';
begin

  clk <= not clk after 7 ns;

  dut : entity work.hdd
    port map (
      CLK_14M => clk,
      IO_SELECT => io_select,
      DEVICE_SELECT => device_select,
      RESET => reset,
      A => a,
      RD => rd,
      D_IN => d_in,
      D_OUT => d_out,
      sector => sector,
      hdd_read => hdd_read,
      hdd_write => hdd_write,
      hdd_mounted => hdd_mounted,
      hdd_protect => hdd_protect,
      ram_addr => ram_addr,
      ram_di => ram_di,
      ram_do => ram_do,
      ram_we => ram_we
    );

  -- (No collision monitor here: GHDL 6/GNAT cannot read DUT internals
  -- hierarchically. The schedule never creates a CPU-C0F8-write + ram_we
  -- same-address cycle - the RAMWRITE phase runs with DS=0 and the C0F8
  -- walk phases with ram_we=0 - so the unreachable case cannot arise. The
  -- SV TB keeps a monitor as belt-and-braces.)

  stim : process
    file tf : text open write_mode is TRACE_FILE;
    variable ln : line;
    variable c : integer := 0;
    variable c_next, i, w, s : integer;
    variable ram_do_int : integer;
  begin
    -- stim(0): reset high, everything else idle defaults
    reset <= '1';

    write(ln, string'("CYCLE,RESET,IO_SELECT,DEVICE_SELECT,RD,A_LOW,D_IN,D_OUT,SECTOR,HDD_READ,HDD_WRITE,MOUNTED,PROTECT,RAM_ADDR,RAM_WE,RAM_DI,RAM_DO"));
    writeline(tf, ln);
    flush(tf);

    while c < 7600 loop
      wait until falling_edge(clk);

      -- trace row c: state after the DUT processed stim(c), fully settled
      write(ln, integer'image(c)); write(ln, ',');
      write(ln, std_logic'image(reset)); write(ln, ',');
      write(ln, std_logic'image(io_select)); write(ln, ',');
      write(ln, std_logic'image(device_select)); write(ln, ',');
      write(ln, std_logic'image(rd)); write(ln, ',');
      write(ln, integer'image(to_integer(a(3 downto 0)))); write(ln, ',');
      write(ln, integer'image(to_integer(d_in))); write(ln, ',');
      write(ln, integer'image(to_integer(d_out))); write(ln, ',');
      write(ln, integer'image(to_integer(sector))); write(ln, ',');
      write(ln, std_logic'image(hdd_read)); write(ln, ',');
      write(ln, std_logic'image(hdd_write)); write(ln, ',');
      write(ln, std_logic'image(hdd_mounted)); write(ln, ',');
      write(ln, std_logic'image(hdd_protect)); write(ln, ',');
      -- PORTS ONLY (GHDL 6 cannot read DUT internals). sec_addr's subtleties
      -- (one-clock-late increment, latched flag, 511->0 wrap) are observable
      -- through the D_OUT/ram_do byte sequences - a stronger, behaviour-level
      -- proof than internal observability.
      --
      -- ram_do: the donor starts it 'U' (no init, no reset); 'U' reports as
      -- -1 and the runner ignores those fields (the Verilog port starts at
      -- 0, behaviour-identical: U and 0 can both never compare as 1).
      write(ln, integer'image(to_integer(ram_addr))); write(ln, ',');
      write(ln, std_logic'image(ram_we)); write(ln, ',');
      write(ln, integer'image(to_integer(ram_di))); write(ln, ',');
      ram_do_int := -1;
      -- bit-0 guard suffices: the DUT writes whole bytes from fully-defined
      -- D_IN/ram_di, so an element is either all-'U' (unwritten) or fully
      -- defined - a mixed pattern is impossible. (GHDL 6/GNAT also rejects
      -- the 'not in ''0''..''1''' range test, so no per-bit loop here.)
      if ram_do(0) /= 'U' and ram_do(0) /= 'X' then
        ram_do_int := to_integer(ram_do);
      end if;
      write(ln, integer'image(ram_do_int));
      writeline(tf, ln);
      flush(tf);

      -- set stim(c+1)
      c_next := c + 1;
      if c < 7599 then
        -- defaults (machine idle)
        reset <= '0';
        io_select <= '0';
        device_select <= '0';
        rd <= '0';
        a <= x"0000";
        d_in <= x"00";
        ram_addr <= (others => '0');
        ram_di <= x"00";
        ram_we <= '0';
        hdd_mounted <= '0';
        hdd_protect <= '0';

        if c_next < 4 then
          reset <= '1';
        elsif c_next >= 10 and c_next <= 265 then
          io_select <= '1';
          rd <= '1';
          a <= to_unsigned(16#C600# + (c_next - 10), 16);
        elsif c_next >= 266 and c_next <= 267 then
          -- drain: the ROM readout is two registered stages (hdd_rom dout,
          -- then D_OUT); hold IO_SELECT+last address so ROM[255] reaches
          -- D_OUT before the FF default overwrites it
          io_select <= '1';
          rd <= '1';
          a <= X"C6FF";
        elsif c_next >= 300 and c_next <= 399 then
          i := c_next - 300;
          device_select <= '1';
          if i mod 2 = 0 then
            w := i / 2;
            rd <= '0';
            a <= to_unsigned(16#C0F3# + (w mod 5), 16);
            d_in <= to_unsigned((w * 3 + 1) mod 256, 8);
          else
            rd <= '1';
            a <= to_unsigned(16#C0F3# + ((i / 2) mod 5), 16);
          end if;
        elsif c_next >= 500 and c_next <= 699 then
          i := c_next - 500;
          hdd_mounted <= '1';
          s := i / 2;
          if i mod 2 = 0 then
            device_select <= '1';
            case s mod 20 is
              when 0 => rd <= '0'; a <= x"C0F3"; d_in <= x"70";
              when 1 => rd <= '1'; a <= x"C0F0";
              when 2 => hdd_mounted <= '0'; rd <= '1'; a <= x"C0F0";
              when 3 => hdd_mounted <= '1'; rd <= '0'; a <= x"C0F3"; d_in <= x"00";
              when 4 => rd <= '1'; a <= x"C0F0";
              when 5 => rd <= '0'; a <= x"C0F3"; d_in <= x"70";
              when 6 => rd <= '0'; a <= x"C0F2"; d_in <= x"01";
              when 7 => rd <= '1'; a <= x"C0F0";
              when 8 => hdd_mounted <= '0'; rd <= '1'; a <= x"C0F0";
              when 9 => hdd_mounted <= '1'; rd <= '0'; a <= x"C0F2"; d_in <= x"02";
              when 10 => rd <= '1'; a <= x"C0F0";
              when 11 => hdd_protect <= '1'; rd <= '1'; a <= x"C0F0";
              when 12 => hdd_protect <= '0'; hdd_mounted <= '0'; rd <= '1'; a <= x"C0F0";
              when 13 => hdd_mounted <= '1'; rd <= '0'; a <= x"C0F2"; d_in <= x"03";
              when 14 => rd <= '1'; a <= x"C0F0";
              when 15 => rd <= '1'; a <= x"C0F1";
              when 16 =>
                hdd_protect <= '0';
                rd <= '0'; a <= x"C0F2";
                d_in <= to_unsigned((s * 3) mod 4, 8);
              when 17 =>
                rd <= '1'; a <= x"C0F0";
              when others =>
                if (s mod 7) = 3 then hdd_protect <= '1'; end if;
                if (s / 20) mod 2 = 0 then
                  rd <= '0';
                  a <= to_unsigned(16#C0F3# + ((s mod 5)), 16);
                  d_in <= to_unsigned((s * 7 + 11) mod 256, 8);
                else
                  rd <= '1'; a <= x"C0F0";
                end if;
            end case;
          end if;
        elsif c_next = 798 then
          device_select <= '1'; rd <= '0'; a <= x"C0F3"; d_in <= x"70";
          hdd_mounted <= '1'; hdd_protect <= '0';
        elsif c_next = 799 then
          device_select <= '1'; rd <= '0'; a <= x"C0F2"; d_in <= x"01";
        elsif c_next = 800 then
          device_select <= '1'; rd <= '1'; a <= x"C0F0";   -- execute: sec_addr -> 0
        elsif c_next >= 802 and c_next <= 1825 then
          i := c_next - 802;
          if i mod 2 = 0 then
            device_select <= '1'; rd <= '0'; a <= x"C0F8";
            d_in <= to_unsigned(((i / 2) * 31 + 7) mod 256, 8);
          end if;
        elsif c_next >= 1900 and c_next <= 2923 then
          i := c_next - 1900;
          if i mod 2 = 0 then
            device_select <= '1'; rd <= '1'; a <= x"C0F8";
          end if;
        elsif c_next >= 3000 and c_next <= 4023 then
          i := c_next - 3000;
          if i mod 2 = 0 then
            ram_addr <= to_unsigned(i / 2, 9);
          end if;
        elsif c_next >= 4100 and c_next <= 5123 then
          i := c_next - 4100;
          if i mod 2 = 0 then
            ram_we <= '1';
            ram_addr <= to_unsigned(i / 2, 9);
            ram_di <= to_unsigned(((i / 2) * 13 + 3) mod 256, 8);
          end if;
        elsif c_next >= 5200 and c_next <= 6223 then
          i := c_next - 5200;
          if i mod 2 = 0 then
            device_select <= '1'; rd <= '1'; a <= x"C0F8";
          end if;
        elsif c_next >= 6300 and c_next <= 6359 then
          i := c_next - 6300;
          if i < 20 then
            if i mod 2 = 0 then
              device_select <= '1'; rd <= '0'; a <= x"C0F8";
              d_in <= to_unsigned((i / 2) + 40, 8);
            end if;
          elsif i = 22 then
            device_select <= '1'; rd <= '0'; a <= x"C0F2"; d_in <= x"02";
          elsif i >= 24 and i < 44 then
            if i mod 2 = 0 then
              device_select <= '1'; rd <= '1'; a <= x"C0F8";
            end if;
          end if;
        elsif c_next >= 6400 and c_next <= 6440 then
          i := c_next - 6400;
          if i < 8 then
            -- hold DS HIGH across 4 consecutive C0F8 reads: the increment
            -- flag latches; it may only fire once DS is released (the
            -- one-clock-late branch). Exercises select_d/increment
            -- interplay.
            device_select <= '1'; rd <= '1'; a <= x"C0F8";
          end if;
        end if;
      end if;
      c := c + 1;
    end loop;
    -- (no close(tf): GHDL 6 does not import std.textio.close; every line is
    -- flushed on write, so the trace is complete)
    report "hdd_vhdl_tb: trace complete" severity note;
    std.env.finish;
    wait;
  end process;
end architecture;
