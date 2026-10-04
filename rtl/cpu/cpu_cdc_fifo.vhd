library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- A DUAL-CLOCK FIFO for the CPU's two memory mailboxes.
--
-- Why a FIFO. A mailbox that carries ONE transaction makes the sender wait
-- for an acknowledge that has crossed back before it can hand over the next:
-- two synchroniser round trips of dead time between consecutive transactions.
-- On the response side that dead time is the bridge's - it may not start the
-- next transaction until clk93 has taken the previous completion - which is
-- why it shows up between back-to-back cache misses.
--
-- What it does NOT change is the crossing's LATENCY. Two flops each way is
-- what makes a crossing safe against a clock edge landing mid-transition, and
-- a FIFO still pays them. The gain is that the latency is paid once and then
-- pipelined over, instead of once per transaction.
--
-- Why gray-coded pointers. Exactly one bit changes per increment, so a pointer
-- sampled while it is changing reads either the old value or the new one and
-- never a mixture of the two - the property a two-phase toggle has, for a
-- counter rather than a single bit. The payload array is written in clk_wr
-- and read combinationally in clk_rd: an entry is complete at least two clk_rd
-- edges before the pointer that exposes it arrives, which is the bundled-data
-- argument.
--
-- ADDR_BITS is at least 1 (a depth of two). Depth two is enough to stop a
-- consumer's delay from reaching the producer; deeper only helps if the
-- producer bursts.
entity cpu_cdc_fifo is
   generic (
      WIDTH     : integer := 64;
      ADDR_BITS : integer := 1;
      -- Each side compares against the other's gray pointer register itself,
      -- not its synchronised copy: for clocks that are phase-aligned outputs
      -- of one PLL, with the paths between them timed. A write and the
      -- pointer that exposes it land on the same edge, so the reader sees the
      -- entry complete on its next one.
      SYNC      : boolean := false
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
   -- altsyncram here and spends THREE M10K blocks on two 108-bit entries, in
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

   signal rd_gray_meta : std_logic_vector(ADDR_BITS downto 0) := (others => '0');
   signal rd_gray_sync : std_logic_vector(ADDR_BITS downto 0) := (others => '0');
   signal wr_gray_meta : std_logic_vector(ADDR_BITS downto 0) := (others => '0');
   signal wr_gray_sync : std_logic_vector(ADDR_BITS downto 0) := (others => '0');

   -- What each side compares against: the other's pointer, synchronised or
   -- (SYNC) not.
   signal wr_gray_seen : std_logic_vector(ADDR_BITS downto 0);
   signal rd_gray_seen : std_logic_vector(ADDR_BITS downto 0);

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

   wr_gray_seen <= wr_gray when SYNC else wr_gray_sync;
   rd_gray_seen <= rd_gray when SYNC else rd_gray_sync;

   empty_i  <= '1' when (rd_gray = wr_gray_seen) else '0';

   full     <= full_i;
   empty    <= empty_i;
   wr_empty <= '1' when (wr_gray = rd_gray_seen) else '0';
   dout     <= mem(to_integer(rd_bin(ADDR_BITS - 1 downto 0)));

   process (clk_wr)
   begin
      if (rising_edge(clk_wr)) then

         rd_gray_meta <= rd_gray;
         rd_gray_sync <= rd_gray_meta;

         if (reset_wr = '1') then
            wr_bin       <= (others => '0');
            wr_gray      <= (others => '0');
            full_i       <= '0';
            rd_gray_meta <= (others => '0');
            rd_gray_sync <= (others => '0');
         else
            if (wr = '1' and full_i = '0') then
               mem(to_integer(wr_bin(ADDR_BITS - 1 downto 0))) <= din;
            end if;
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;
            -- Compared against the read pointer as it stands BEFORE this edge,
            -- so full may be held one cycle past the truth. That direction is
            -- safe; the other would overwrite an entry.
            if (wr_gray_next = lapped(rd_gray_seen)) then
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

         wr_gray_meta <= wr_gray;
         wr_gray_sync <= wr_gray_meta;

         if (reset_rd = '1') then
            rd_bin       <= (others => '0');
            rd_gray      <= (others => '0');
            wr_gray_meta <= (others => '0');
            wr_gray_sync <= (others => '0');
         else
            rd_bin  <= rd_bin_next;
            rd_gray <= rd_gray_next;
         end if;
      end if;
   end process;

end architecture;
