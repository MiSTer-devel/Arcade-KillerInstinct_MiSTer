library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_sync_fifo is
end entity;

architecture test of tb_sync_fifo is
   constant CLK_PERIOD : time := 10 ns;

   signal clk       : std_logic := '0';
   signal reset     : std_logic := '1';
   signal din       : std_logic_vector(7 downto 0) := (others => '0');
   signal wr        : std_logic := '0';
   signal full      : std_logic;
   signal near_full : std_logic;
   signal dout      : std_logic_vector(7 downto 0);
   signal rd        : std_logic := '0';
   signal empty     : std_logic;
   signal near_empty: std_logic;
begin
   clk <= not clk after CLK_PERIOD / 2;

   dut: entity work.SyncFifoFallThroughMLAB
      generic map
      (
         SIZE              => 8,
         DATAWIDTH         => 8,
         NEARFULLDISTANCE  => 6,
         NEAREMPTYDISTANCE => 1
      )
      port map
      (
         clk       => clk,
         reset     => reset,
         Din       => din,
         Wr        => wr,
         Full      => full,
         NearFull  => near_full,
         Dout      => dout,
         Rd        => rd,
         Empty     => empty,
         NearEmpty => near_empty
      );

   stimulus: process
      procedure tick is
      begin
         wait until rising_edge(clk);
         wait for 1 ns;
      end procedure;
   begin
      tick;
      tick;
      reset <= '0';
      tick;

      -- This FIFO deliberately uses the all-ones count as full, so SIZE=8
      -- stores seven entries. Fill it, then prove an eighth write is rejected.
      for i in 0 to 6 loop
         din <= std_logic_vector(to_unsigned(i, din'length));
         wr  <= '1';
         tick;
      end loop;
      wr <= '0';

      assert full = '1'
         report "FIFO did not assert Full at its effective capacity"
         severity failure;
      assert dout = x"00"
         report "FIFO head changed while filling"
         severity failure;

      din <= x"EE";
      wr  <= '1';
      tick;
      wr <= '0';

      assert full = '1'
         report "A rejected full-queue write changed occupancy"
         severity failure;
      assert dout = x"00"
         report "A write while full overwrote the unread FIFO head"
         severity failure;

      for i in 0 to 6 loop
         assert dout = std_logic_vector(to_unsigned(i, dout'length))
            report "FIFO ordering changed after a rejected full-queue write"
            severity failure;
         rd <= '1';
         tick;
         rd <= '0';
      end loop;

      assert empty = '1'
         report "FIFO did not empty after reading all accepted entries"
         severity failure;

      -- Refill and exercise the boundary used by the CPU transaction queue:
      -- a full FIFO may accept a replacement only when its head is read on
      -- the same edge. Occupancy and ordering must both remain unchanged.
      reset <= '1';
      tick;
      tick;
      reset <= '0';
      tick;

      for i in 0 to 6 loop
         din <= std_logic_vector(to_unsigned(16 + i, din'length));
         wr  <= '1';
         tick;
      end loop;
      wr <= '0';

      assert full = '1' and dout = x"10"
         report "FIFO was not ready for the full pop/push test"
         severity failure;

      din <= x"AA";
      wr  <= '1';
      rd  <= '1';
      tick;
      wr <= '0';
      rd <= '0';

      assert full = '1'
         report "Simultaneous full-queue pop/push changed occupancy"
         severity failure;
      assert dout = x"11"
         report "Simultaneous full-queue pop/push exposed the wrong head"
         severity failure;

      for i in 0 to 5 loop
         assert dout = std_logic_vector(to_unsigned(17 + i, dout'length))
            report "FIFO ordering changed during a full pop/push"
            severity failure;
         rd <= '1';
         tick;
         rd <= '0';
      end loop;

      assert dout = x"AA"
         report "Replacement entry was not retained at the FIFO tail"
         severity failure;
      rd <= '1';
      tick;
      rd <= '0';

      assert empty = '1'
         report "FIFO did not empty after the full pop/push test"
         severity failure;

      report "PASS: transaction FIFO full-boundary behavior" severity note;
      finish;
   end process;
end architecture;
