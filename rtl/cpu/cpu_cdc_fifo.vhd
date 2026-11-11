library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- A DUAL-CLOCK FIFO for the CPU's memory response mailbox.
--
-- Why a FIFO. A mailbox that carries ONE transaction makes the sender wait
-- for an acknowledge that has crossed back before it can hand over the next:
-- a round trip of dead time between consecutive transactions. On the
-- response side that dead time is the bridge's - it may not start the next
-- transaction until clk2x has taken the previous completion - which is why
-- it shows up between back-to-back cache misses. A FIFO pays the crossing
-- once and then pipelines over it, instead of once per transaction.
--
-- The crossing. The two clocks are phase-aligned outputs of one PLL at an
-- integer ratio, and the paths between them are timed (KillerInstinct.sdc),
-- so each side compares against the other's gray-coded pointer register
-- itself, with no synchroniser. A write and the pointer that exposes it land
-- on the same edge, so the reader sees the entry complete on its next one.
-- The payload array is written in clk_wr and read combinationally in clk_rd.
--
-- ADDR_BITS is at least 1 (a depth of two). Depth two is enough to stop a
-- consumer's delay from reaching the producer; deeper only helps if the
-- producer bursts.
entity cpu_cdc_fifo is
   generic (
      WIDTH     : integer := 64;
      ADDR_BITS : integer := 1
   );
   port (
      -- write side
      clk_wr   : in  std_logic;
      reset_wr : in  std_logic;
      wr       : in  std_logic;
      din      : in  std_logic_vector(WIDTH - 1 downto 0);
      full     : out std_logic;
      -- '1' when the read side has consumed everything written. Derived from
      -- the read pointer AFTER it has crossed, so it lags: it says "not yet"
      -- for longer than the truth and never the other way round.
      wr_empty : out std_logic;

      -- read side. dout is the head whenever empty is '0' (fall-through), so
      -- a consumer reads it in the same cycle it decides to take it.
      clk_rd   : in  std_logic;
      reset_rd : in  std_logic;
      rd       : in  std_logic;
      dout     : out std_logic_vector(WIDTH - 1 downto 0);
      empty    : out std_logic
   );
end entity;

architecture arch of cpu_cdc_fifo is

   constant DEPTH : integer := 2 ** ADDR_BITS;

   type t_mem is array (0 to DEPTH - 1) of std_logic_vector(WIDTH - 1 downto 0);
   signal mem : t_mem := (others => (others => '0'));

   -- Registers, not a memory block. Left to itself Quartus infers a dual-clock
   -- altsyncram here and spends THREE M10K blocks on two 107-bit entries, in
   -- a design whose block memory is nearly full. This FIFO exists to be
   -- shallow: a depth beyond a handful of entries should change this to
   -- "MLAB" and re-measure rather than leave it on "logic".
   attribute ramstyle : string;
   attribute ramstyle of mem : signal is "logic";

   -- One bit wider than the index, so a full FIFO is distinguishable from an
   -- empty one by the extra bit alone.
   signal wr_bin       : unsigned(ADDR_BITS downto 0) := (others => '0');
   signal rd_bin       : unsigned(ADDR_BITS downto 0) := (others => '0');
   signal wr_bin_next  : unsigned(ADDR_BITS downto 0);
   signal rd_bin_next  : unsigned(ADDR_BITS downto 0);
   signal wr_gray      : std_logic_vector(ADDR_BITS downto 0) := (others => '0');
   signal rd_gray      : std_logic_vector(ADDR_BITS downto 0) := (others => '0');
   signal wr_gray_next : std_logic_vector(ADDR_BITS downto 0);
   signal rd_gray_next : std_logic_vector(ADDR_BITS downto 0);

   signal full_i  : std_logic := '0';
   -- COMBINATIONAL, unlike full. A registered empty would deassert one read
   -- cycle after the write pointer arrived, and this FIFO sits on the return
   -- path of a cache miss: that cycle is paid by every fill. Registering full
   -- costs nothing by comparison - a full FIFO is a case the bridge does not
   -- reach - so it keeps the shorter path on the side that has the room.
   signal empty_i : std_logic;

   function to_gray(b : unsigned) return std_logic_vector is
   begin
      return std_logic_vector(b xor ('0' & b(b'high downto 1)));
   end function;

   -- The gray code a write pointer takes when it has lapped the read pointer:
   -- the same code with its top TWO bits inverted. Written as a function so it
   -- needs no null slice at ADDR_BITS = 1.
   function lapped(g : std_logic_vector) return std_logic_vector is
      variable r : std_logic_vector(g'range);
   begin
      r := g;
      r(g'high)     := not g(g'high);
      r(g'high - 1) := not g(g'high - 1);
      return r;
   end function;

begin

   wr_bin_next  <= wr_bin + 1 when (wr = '1' and full_i = '0')  else wr_bin;
   rd_bin_next  <= rd_bin + 1 when (rd = '1' and empty_i = '0') else rd_bin;
   wr_gray_next <= to_gray(wr_bin_next);
   rd_gray_next <= to_gray(rd_bin_next);

   empty_i  <= '1' when (rd_gray = wr_gray) else '0';

   full     <= full_i;
   empty    <= empty_i;
   wr_empty <= '1' when (wr_gray = rd_gray) else '0';
   dout     <= mem(to_integer(rd_bin(ADDR_BITS - 1 downto 0)));

   process (clk_wr)
   begin
      if (rising_edge(clk_wr)) then
         if (reset_wr = '1') then
            wr_bin       <= (others => '0');
            wr_gray      <= (others => '0');
            full_i       <= '0';
         else
            if (wr = '1' and full_i = '0') then
               mem(to_integer(wr_bin(ADDR_BITS - 1 downto 0))) <= din;
            end if;
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;
            -- Compared against the read pointer as it stands BEFORE this edge,
            -- so full may be held one cycle past the truth. That direction is
            -- safe; the other would overwrite an entry.
            if (wr_gray_next = lapped(rd_gray)) then
               full_i <= '1';
            else
               full_i <= '0';
            end if;
         end if;
      end if;
   end process;

   process (clk_rd)
   begin
      if (rising_edge(clk_rd)) then
         if (reset_rd = '1') then
            rd_bin       <= (others => '0');
            rd_gray      <= (others => '0');
         else
            rd_bin  <= rd_bin_next;
            rd_gray <= rd_gray_next;
         end if;
      end if;
   end process;

end architecture;
