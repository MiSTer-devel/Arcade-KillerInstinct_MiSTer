library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;   
use STD.textio.all;

library mem;
use work.pFunctions.all;

entity cpu_datacache is
   generic
   (
      LITTLE_ENDIAN : boolean := false;
      -- A 64-bit store that misses allocates its line WITHOUT reading it from
      -- SDRAM. See "SKIPPING THE STORE-MISS FILL" in the architecture.
      SKIP_FILL     : boolean := false
   );
   port 
   (
      clk1x             : in  std_logic;
      clk93             : in  std_logic;
      clk2x             : in  std_logic;
      -- One reset per domain; see the note in cpu_instrcache.vhd.
      reset_1x          : in  std_logic;
      reset_93          : in  std_logic;
      ce_93             : in  std_logic;
      stall             : in  unsigned(4 downto 0);
      stall4            : in  std_logic;
      fifo_block        : in  std_logic;
      
      slow_in           : in  std_logic_vector(3 downto 0); 
      force_wb_in       : in  std_logic;
      write_through_in  : in  std_logic := '0';
      
      ram_request       : out std_logic := '0';
      ram_reqAddr       : out unsigned(31 downto 0) := (others => '0');
      ram_active        : in  std_logic := '0';
      ram_grant         : in  std_logic := '0';
      ram_done          : in  std_logic := '0';
      ddr3_DOUT         : in  std_logic_vector(63 downto 0);
      ddr3_DOUT_READY   : in  std_logic;
      
      writeback_ena     : out std_logic := '0';
      writeback_addr    : out unsigned(31 downto 0) := (others => '0');
      writeback_data    : out std_logic_vector(63 downto 0) := (others => '0');
      -- Which of the line's four qwords the write-back carries, bit i for the
      -- qword at offset 8i. A qword the cache never read in holds nothing, so
      -- its SDRAM words must be left alone. Valid from the first write-back
      -- beat until the cache leaves WRITEBACKDONE, which is after the line
      -- has been taken as one transaction.
      writeback_mask    : out std_logic_vector(3 downto 0) := (others => '1');
      
      tag_addr          : in  unsigned(31 downto 0);
      
      read_ena          : in  std_logic;
      RW_addr           : in  unsigned(31 downto 0);
      RW_64             : in  std_logic;
      read_busy         : out std_logic;
      read_done         : out std_logic;
      read_data         : out std_logic_vector(63 downto 0) := (others => '0');
      
      write_ena         : in  std_logic;
      write_be          : in  std_logic_vector(7 downto 0);
      write_data        : in  std_logic_vector(63 downto 0);
      write_done        : out  std_logic;
      
      CacheCommandEna   : in  std_logic;
      CacheCommand      : in  unsigned(4 downto 0);
      CachecommandStall : out std_logic;
      CachecommandDone  : out std_logic := '0';
      
      TagLo_Valid       : in  std_logic;
      TagLo_Dirty       : in  std_logic;
      TagLo_Addr        : in  unsigned(19 downto 0);
      
      writeTagEna       : out std_logic := '0';
      writeTagValue     : out unsigned(21 downto 0) := (others => '0');

      debug_state       : out std_logic_vector(3 downto 0) := (others => '0');
      -- Why stage 4 is waiting on this cache, for the stall census. Hardware
      -- showed DC - stall4 on a CACHED access - at 98% of a whole frame, so
      -- these separate the two causes with opposite fixes: the cache queued
      -- behind another bus master, or the cache doing its own extra traffic.
      --   perf_miss       one pulse per allocating miss (a line fill starts)
      --   perf_req_denied REQUESTING the bus and being refused it
      --   perf_writeback  evicting a dirty line (write-back traffic)
      --
      -- req_denied measured 0.5-0.9% of DC on hardware, so the cache asks for
      -- the bus and is essentially never refused: arbitration is not the
      -- problem, and the time is the cache's own fill latency. perf_miss makes
      -- that divisible - DC cycles over miss count is cycles per miss, and
      -- both fields are scaled by 256 in the census so the ratio survives
      -- unchanged. ~20-30 says the misses are normal and there are simply too
      -- many of them; ~200+ says the memory path itself is the problem.
      --
      -- A dropped perf_wait_bus used to sit here. It was
      -- "state /= IDLE and ram_grant = '0'" and read 97-99% of DC in every
      -- row, which is close to a definition rather than a measurement: the
      -- cache only holds the bus for the data beats.
      perf_miss         : out std_logic := '0';
      -- The fill interval, split exhaustively rather than sampled by proxy.
      --
      -- Four taps chosen by reasoning about which signal ought to represent
      -- the delay all read ~zero while the CPU sat stalled. What has worked
      -- every time is a partition with a sum check - UC + DC = stall4 held to
      -- within 1 across every capture. So this splits the FILL state itself:
      --
      --   perf_fill_wait  in FILL, no data beat has arrived yet
      --   perf_fill_data  in FILL, beats arriving, line not yet complete
      --   perf_fill_hold  in FILL, every beat in, waiting for ram_done
      --
      -- Mutually exclusive and together the whole of FILL, so none of them can
      -- quietly read zero while the time goes somewhere else. All three are
      -- clk93 levels, so they count in CPU cycles directly.
      --
      -- The third exists because ram_done is NOT the last beat: it is
      -- mem_finished_read in cpu.vhd, which comes off response_cdc_deliver_93
      -- at the end of a clk1x-to-clk93 mailbox round trip. Hardware put 80% of
      -- a fill in the beat phase while the SDRAM read was only half of that,
      -- so the tail after the data is the thing to size.
      --
      -- "Every beat in" is the design's own fill_active_2x, not a beat count
      -- of my own: ddr3_DOUT_READY is a per-beat pulse from the bridge but a
      -- held level in tb_ki_datacache_writeback, so counting its edges works
      -- on hardware and silently sees one beat in simulation. fill_active_2x
      -- is set on the grant and cleared after the fourth beat either way. It
      -- is a clk1x level read from clk93; it changes once per fill, so the
      -- worst case is attributing a cycle to the neighbouring phase.
      -- Is this miss the NEXT line after the previous one? A next-line
      -- prefetcher needs no instruction-level parallelism, which matters
      -- because the CPU retires only ~2.6 instructions per miss in the frames
      -- where the data cache dominates - there is nothing to overlap, but a
      -- linear stream can still be run ahead of.
      --
      -- Counted at line granularity, so it answers exactly the question a
      -- prefetcher would ask: was address(31:5) one more than last time.
      perf_stride_hit   : out std_logic := '0';
      -- Does this miss repeat the PREVIOUS delta? Hardware put next-line
      -- misses at 0 of 10,752 in the frame where the data cache owns 98% of
      -- the time, which is not what random access looks like - random would
      -- land on the next line occasionally by chance. A pattern that never
      -- touches consecutive lines is what a constant NON-UNIT stride does,
      -- so measure that instead: same line delta as last time, delta not
      -- zero. A strided prefetcher works on this where a next-line one
      -- cannot, and like next-line it needs no instruction-level
      -- parallelism - of which these frames have almost none.
      perf_delta_hit    : out std_logic := '0';
      perf_fill_wait    : out std_logic := '0';
      perf_fill_data    : out std_logic := '0';
      perf_fill_hold    : out std_logic := '0';
      perf_req_denied   : out std_logic := '0';
      perf_writeback    : out std_logic := '0';
      -- High in WAYFIX: one cycle per load that hit in the way the prediction
      -- did not pick. Each such load costs the CPU 2 cycles, not 1 -
      -- tb_ki_perfbench measures 2.00: WAYFIX itself, and stage 3's release,
      -- which for any load that leaves IDLE waits a further edge for
      -- writebackNew (READWAIT pays the same). See the note below.
      perf_way_slow     : out std_logic := '0';
      -- Fill traffic, counted per event:
      --
      --   perf_wb_line      one pulse per write-back (its first beat)
      --   perf_fill_store   one pulse per fill a STORE caused
      --   perf_fill_skip    one pulse per store miss that allocated its line
      --                     without a fill (SKIP_FILL)
      --   perf_fill_absent  one pulse per fill of a line already in the cache,
      --                     for a qword a skipped fill left out
      --
      -- Hardware measured the heavy frames' store-miss fills before SKIP_FILL
      -- existed: 97% of them were never read, every one a line written whole
      -- by 64-bit stores. perf_fill_skip is those fills not happening, and
      -- perf_fill_absent what it costs when a skipped qword is wanted after
      -- all. The census shadows that measured it (written qwords, read-before-
      -- written, store coverage) are in git history; docs/OPTIMIZATION-HISTORY.md
      -- has what they found.
      perf_wb_line      : out std_logic := '0';
      perf_fill_store   : out std_logic := '0';
      perf_fill_skip    : out std_logic := '0';
      perf_fill_absent  : out std_logic := '0';
      SS_reset          : in  std_logic
   );
end entity;

architecture arch of cpu_datacache is

   -- 2-WAY SET-ASSOCIATIVE, 16 KB: 256 sets x 2 ways x 32-byte lines, write
   -- back, LRU - the geometry of the real R4600's D-cache. It replaced a
   -- direct-mapped cache of the same size because tools/mame_dcache_sim.py
   -- showed KI's per-frame block copies taking 12% fewer misses and 41% fewer
   -- dirty write-backs with two ways: the reads stop evicting the working
   -- buffer's dirty lines. See docs/OPTIMIZATION-HISTORY.md.
   --
   -- The set index is address(12..5). The stored tag is still address(31..12),
   -- so a hit compares address(31..13). Index cache ops name their way with
   -- address bit 13, as the R4600's do; hit ops act on whichever way hits.
   --
   -- WAY PREDICTION. Both ways' tags and data are read in parallel, one stage
   -- early, exactly as the single way was. Selecting the data with the tag
   -- compare would put a 19-bit compare in front of the load path, which
   -- already failed timing by 0.9 ns before this change - so the data comes
   -- from the way most recently used in its set instead. That is one bit per
   -- set, read from its own RAM alongside the tags, so the select is a RAM
   -- output like the data itself. The compares still decide hit or miss. A
   -- hit in the OTHER way is correct but late: it goes through WAYFIX, which
   -- delivers from the way that hit on the RAMs' next read. That is READWAIT's
   -- mechanism and rests on the same fact: every cached load stalls stage 3
   -- in its issue cycle (the load-delay stall in cpu.vhd), so ce_fetch is low
   -- and the data RAMs re-read the load's own address. An assertion below
   -- checks it. The trace put the prediction right on 96% of load hits.
   --
   -- The same bit is the LRU state. It is written in the access's own IDLE
   -- cycle, not registered first: the access after a load reads it at the end
   -- of the NEXT cycle, the load-delay bubble, which is exactly where a
   -- registered write would land. It has no bypass: a store followed at once
   -- by an access to the same set reads it on the same edge it is written,
   -- and gets the old value or nothing useful. That costs a cycle or picks a
   -- worse victim - a load there goes through READWAIT and never uses the
   -- prediction - but it can never give a wrong answer.
   --
   -- SKIPPING THE STORE-MISS FILL (SKIP_FILL). In the heavy frames seven
   -- misses in ten were stores, and hardware found 97% of those fills were
   -- never read: the line was written whole, every qword by a 64-bit store,
   -- before anything loaded it. So a 64-bit store that misses takes its line
   -- without the SDRAM read, and the cache records which qwords it really
   -- holds - four ABSENT bits per line, beside the tag:
   --
   --   * the store miss writes back a dirty victim as before, then tags the
   --     line with every qword but its own absent and writes the store (the
   --     ALLOC state, one cycle, no SDRAM traffic);
   --   * a 64-bit store to an absent qword of a resident line is a hit, and
   --     clears the qword's bit in the tag rewrite every store hit already
   --     makes;
   --   * a load of an absent qword, or a narrower store into one, is not a
   --     hit: the line takes a fill that writes only its absent qwords, then
   --     completes as any miss does;
   --   * a write-back carries the present qwords as writeback_mask, and the
   --     SDRAM burst writes nothing for the rest.
   --
   -- The bits ride in the tag RAM so the tag's read-after-write bypass
   -- (tag_newData) covers them. That bypass is now what keeps a store's data:
   -- a stale absent bit would let a later fill overwrite a stored qword. The
   -- dirty bit relied on it already.

   signal ce_fetch         : std_logic;

   type t_tag  is array(0 to 1) of std_logic_vector(25 downto 0);
   type t_data is array(0 to 1) of std_logic_vector(63 downto 0);

   -- tags: absent(3..0) & dirty & valid & address(31..12), one RAM per way.
   -- Absent bit i is the qword at offset 8i; always zero without SKIP_FILL.
   signal tag_address_a    : std_logic_vector(7 downto 0);
   signal tag_wdata        : t_tag;
   signal tag_wren_w       : std_logic_vector(1 downto 0);
   signal tag_address_b    : std_logic_vector(7 downto 0);
   signal tag_q_b          : t_tag;
   signal tag_newEna       : std_logic_vector(1 downto 0) := "00";
   signal tag_newData      : t_tag := (others => (others => '0'));
   signal tag_w            : t_tag;
   -- line_hit_w: the way holds the line. hit_w: it can also serve this access
   -- - the qword is present, or a 64-bit store is about to make it so.
   signal line_hit_w       : std_logic_vector(1 downto 0);
   signal line_hit         : std_logic;
   signal qabs_w           : std_logic_vector(1 downto 0);
   signal hit_w            : std_logic_vector(1 downto 0);
   signal read_hit         : std_logic;
   signal hit_way          : std_logic;
   signal fast_hit         : std_logic;
   signal hit_dirty        : std_logic;
   signal hit_absent       : std_logic_vector(3 downto 0);
   signal victim_way       : std_logic;
   signal index_op         : std_logic;
   signal sel_way          : std_logic;
   signal tag_compare      : std_logic_vector(25 downto 0);
   -- A store that covers its whole qword, the qword's bit if so, and whether
   -- a miss by this store may skip its fill.
   signal store_full       : std_logic;
   signal store_clear      : std_logic_vector(3 downto 0);
   signal skip_ok          : std_logic;

   -- most recently used way, one bit per set: the prediction and the LRU state
   signal mru_wren         : std_logic;
   signal mru_waddr        : std_logic_vector(7 downto 0);
   signal mru_wdata        : std_logic_vector(0 downto 0);
   signal mru_q            : std_logic_vector(0 downto 0);
   signal pred_way         : std_logic;
   -- The way every state but IDLE reads and writes, latched in IDLE.
   signal data_way         : std_logic := '0';

   signal tag_addr_1       : unsigned(31 downto 0) := (others => '0');
   signal tag_addr_low     : unsigned(4 downto 0) := (others => '0');
   signal tag_read_addr    : unsigned(13 downto 0) := (others => '0');
   signal fillAddr         : unsigned(31 downto 0) := (others => '0');

   -- data
   signal fill_line_saved  : unsigned(7 downto 0) := (others => '0');
   signal fill_line_2x     : unsigned(7 downto 0) := (others => '0');
   signal fill_way_2x      : std_logic := '0';
   signal fill_way_now     : std_logic;
   signal fill_beat_2x     : unsigned(1 downto 0) := (others => '0');
   signal fill_active_2x   : std_logic := '0';
   signal fill_grant       : std_logic;
   -- The qwords a fill writes: all four, or a line's absent ones. Latched in
   -- IDLE like fill_line_saved, and like it read from clk1x.
   signal fill_mask        : std_logic_vector(3 downto 0) := (others => '1');
   signal fill_mask_2x     : std_logic_vector(3 downto 0) := (others => '1');
   signal fill_mask_now    : std_logic_vector(3 downto 0);
   signal fill_beat_now    : unsigned(1 downto 0);
   signal cache_ram_addr_a : std_logic_vector(9 downto 0);
   signal cache_wr_a       : std_logic;
   signal cache_wr_a_w     : std_logic_vector(1 downto 0);

   signal cache_address_b  : std_logic_vector(9 downto 0);
   signal cache_data_b     : std_logic_vector(63 downto 0);
   signal cache_we_w       : std_logic_vector(1 downto 0);
   signal cache_be_b       : std_logic_vector(7 downto 0);
   signal cache_q_w        : t_data;
   signal cache_q_b        : std_logic_vector(63 downto 0);

   signal write_be_rot     : std_logic_vector(7 downto 0);
   signal write_be_1       : std_logic_vector(7 downto 0);

   signal write_data_rot   : std_logic_vector(63 downto 0);
   signal write_data_1     : std_logic_vector(63 downto 0);

   -- The present qwords of the line being written back; see writeback_mask.
   signal wb_mask          : std_logic_vector(3 downto 0) := (others => '1');

   -- state machine
   type tState is
   (
      IDLE,
      CLEARCACHE,
      FILL,
      READWAIT,
      WAITSLOW,
      WRITEBACK1ADDR,
      WRITEBACK1READ,
      WRITEBACK1WRITE,
      WRITEBACK2WRITE,
      WRITEBACK3WRITE,
      WRITEBACK4WRITE,
      WRITEBACKDONE,
      COMMANDPROCESS,
      COMMANDDONE,
      -- Last, so every older state keeps its debug_state number.
      WAYFIX,
      -- A skipped fill: tag the line and take the store (SKIP_FILL).
      ALLOC
   );
   signal state : tstate := IDLE;

   signal writeMode        : std_logic := '0';
   signal fillNext         : std_logic := '0';
   -- After the victim's write-back, ALLOC instead of FILL.
   signal allocNext        : std_logic := '0';
   signal write_ena_1      : std_logic := '0';

   signal clearAddr        : std_logic_vector(7 downto 0) := (others => '0');

   signal isCommand        : std_logic := '0';
   signal isWB             : std_logic := '0';

   signal tag_wren_cmd     : std_logic := '0';
   signal tag_addr_cmd     : std_logic_vector(7 downto 0) := (others => '0');
   signal tag_data_cmd     : std_logic_vector(25 downto 0) := (others => '0');
   -- Which ways a command, fill or clear tag write goes to.
   signal tag_way_cmd      : std_logic_vector(1 downto 0) := "00";

   -- slow
   signal slow       : unsigned(3 downto 0) := (others => '0');
   signal slow_on    : std_logic := '0';
   signal slowcnt    : unsigned(3 downto 0) := (others => '0');

   signal force_wb   : std_logic := '0';
   signal wb_done    : std_logic := '0';
   signal fill_beat_seen : std_logic := '0';
   signal perf_miss_i    : std_logic;
   signal last_miss_line : unsigned(26 downto 0) := (others => '0');
   signal last_miss_seen : std_logic := '0';
   signal stride_hit_i   : std_logic := '0';
   signal delta_hit_i    : std_logic := '0';
   signal last_delta     : unsigned(26 downto 0) := (others => '0');
   signal last_delta_ok  : std_logic := '0';

begin

   debug_state <= std_logic_vector(to_unsigned(tState'pos(state), 4));
   fill_grant <= ram_grant and ram_active;

   -- See the port comments. Reading ram_request back is fine here - the state
   -- machine already does it below - so req_denied can be exact.
   perf_req_denied <= ram_request and (not ram_grant);

   -- Exactly the IDLE branch that starts a fill, so one cycle per miss: the
   -- state machine has no clock enable and leaves IDLE the next cycle. The
   -- write-through miss above it is excluded because it allocates nothing.
   perf_stride_hit <= stride_hit_i;
   perf_delta_hit  <= delta_hit_i;
   perf_fill_wait <= '1' when (state = FILL and fill_beat_seen = '0') else '0';
   perf_fill_data <= '1' when (state = FILL and fill_beat_seen = '1' and
                               fill_active_2x = '1') else '0';
   perf_fill_hold <= '1' when (state = FILL and fill_beat_seen = '1' and
                               fill_active_2x = '0') else '0';

   perf_miss <= perf_miss_i;
   perf_miss_i <= '1' when (state = IDLE and
                          (read_ena = '1' or write_ena = '1') and
                          read_hit = '0' and
                          (write_ena = '0' or write_through_in = '0')) else '0';
   perf_writeback <= '1' when (state = WRITEBACK1ADDR  or state = WRITEBACK1READ or
                               state = WRITEBACK1WRITE or state = WRITEBACK2WRITE or
                               state = WRITEBACK3WRITE or state = WRITEBACK4WRITE or
                               state = WRITEBACKDONE) else '0';
   perf_way_slow  <= '1' when (state = WAYFIX) else '0';

   perf_wb_line     <= '1' when (state = WRITEBACK1WRITE) else '0';
   perf_fill_store  <= '1' when (state = FILL and ram_done = '1' and writeMode = '1') else '0';
   perf_fill_skip   <= '1' when (state = ALLOC) else '0';
   -- A miss in the IDLE branch that fills a resident line.
   perf_fill_absent <= perf_miss_i and line_hit;

   writeback_mask <= wb_mask;

   ce_fetch <= '1' when (stall = 0 and ce_93 = '1') else '0';

   ------------------ tags

   tag_address_a  <= tag_addr_cmd when (tag_wren_cmd = '1') else
                     std_logic_vector(tag_addr_1(12 downto 5));
   tag_address_b  <= std_logic_vector(tag_addr(12 downto 5));

   gtag : for w in 0 to 1 generate
   begin
      -- A command, fill or clear write goes to the ways it names; otherwise a
      -- store hit rewrites its own way's entry with the dirty bit set.
      -- A store hit also makes its qword present if it covers all of it.
      tag_wren_w(w) <= '1' when (tag_wren_cmd = '1' and tag_way_cmd(w) = '1') else
                       '1' when (tag_wren_cmd = '0' and state = IDLE and
                                 write_ena = '1' and hit_w(w) = '1') else
                       '0';
      tag_wdata(w)  <= tag_data_cmd when (tag_wren_cmd = '1') else
                       (tag_w(w)(25 downto 22) and (not store_clear)) &
                       (not write_through_in) & tag_w(w)(20 downto 0);

      itagram : entity mem.dpram
      generic map
      (
         addr_width  => 8,
         data_width  => 26 -- 4 absent bits + dirty + valid + 20 bits(31..12) of address
      )
      port map
      (
         clock_a     => clk93,
         address_a   => tag_address_a,
         data_a      => tag_wdata(w),
         wren_a      => tag_wren_w(w),

         clock_b     => clk93,
         clken_b     => ce_fetch,
         address_b   => tag_address_b,
         data_b      => 26x"0",
         wren_b      => '0',
         q_b         => tag_q_b(w)
      );

      tag_w(w)      <= tag_newData(w) when (tag_newEna(w) = '1') else tag_q_b(w);
      line_hit_w(w) <= '1' when (unsigned(tag_w(w)(19 downto 1)) = RW_addr(31 downto 13) and
                                 tag_w(w)(20) = '1') else '0';
      qabs_w(w)     <= '0' when (not SKIP_FILL) else
                       tag_w(w)(22 + to_integer(RW_addr(4 downto 3)));
      hit_w(w)      <= line_hit_w(w) and ((not qabs_w(w)) or store_full);
   end generate;

   line_hit   <= line_hit_w(0) or line_hit_w(1);
   read_hit   <= hit_w(0) or hit_w(1);
   -- The way holding the line, whether or not it can serve this access.
   hit_way    <= line_hit_w(1);
   -- A hit in the predicted way is an ordinary one-cycle hit.
   fast_hit   <= hit_w(1) when (pred_way = '1') else hit_w(0);
   hit_dirty  <= (line_hit_w(0) and tag_w(0)(21)) or (line_hit_w(1) and tag_w(1)(21));
   hit_absent <= "0000"                   when (not SKIP_FILL) else
                 tag_w(1)(25 downto 22)   when (line_hit_w(1) = '1') else
                 tag_w(0)(25 downto 22);

   -- Every byte of the qword: only a 64-bit store's enables are all set, and
   -- rotating a 32-bit store's halves cannot make them so.
   store_full  <= '1' when (SKIP_FILL and write_ena = '1' and write_be = x"FF") else '0';
   store_clear <= "0000" when (store_full = '0') else
                  "0001" when (RW_addr(4 downto 3) = "00") else
                  "0010" when (RW_addr(4 downto 3) = "01") else
                  "0100" when (RW_addr(4 downto 3) = "10") else
                  "1000";
   -- A write-through store allocates nothing, and a forced write-back sends
   -- the whole line straight after its fill, so neither skips it.
   skip_ok     <= '1' when (store_full = '1' and write_through_in = '0' and force_wb = '0') else '0';
   -- Replace an invalid way first, else the least recently used one.
   victim_way <= '0' when (tag_w(0)(20) = '0') else
                 '1' when (tag_w(1)(20) = '0') else
                 not pred_way;

   index_op   <= '1' when (CacheCommandEna = '1' and
                           (CacheCommand = 5x"01" or CacheCommand = 5x"05" or
                            CacheCommand = 5x"09")) else '0';

   -- The way the IDLE bookkeeping refers to: an index op's own way, the way
   -- holding the line - a hit, or a fill of its absent qwords - or on a miss
   -- the victim about to be replaced.
   sel_way    <= RW_addr(13) when (index_op = '1') else
                 hit_way     when (line_hit = '1') else
                 victim_way;

   -- The victim's (or an index op's) tag, for write-back addresses and index
   -- ops. Deliberately NOT chosen by the hit compare: a hit line's tag is the
   -- access's own address, which the hit branches below use directly, and
   -- keeping the compare out of this 22-bit mux keeps it off these paths.
   tag_compare <= tag_w(1) when ((index_op = '1' and RW_addr(13) = '1') or
                                 (index_op = '0' and victim_way = '1')) else
                  tag_w(0);

   -- Every allocating data access makes its way the most recently used: the
   -- way that hit, or the victim about to be filled. Combinational, for the
   -- reason in the note at the top.
   mru_wren     <= '1' when (state = IDLE and (read_ena = '1' or write_ena = '1') and
                             not (write_ena = '1' and read_hit = '0' and
                                  write_through_in = '1')) else '0';
   mru_waddr    <= std_logic_vector(tag_addr_1(12 downto 5));
   mru_wdata(0) <= sel_way;

   imru : entity mem.dpram
   generic map
   (
      addr_width  => 8,
      data_width  => 1
   )
   port map
   (
      clock_a     => clk93,
      address_a   => mru_waddr,
      data_a      => mru_wdata,
      wren_a      => mru_wren,

      clock_b     => clk93,
      clken_b     => ce_fetch,
      address_b   => tag_address_b,
      data_b      => "0",
      wren_b      => '0',
      q_b         => mru_q
   );

   -- '1' only when it really reads '1': the simulation model can return X for
   -- a set written in the same cycle, and a prediction is only a hint.
   pred_way <= '1' when (mru_q(0) = '1') else '0';

   --------- data

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (reset_1x = '1') then
            fill_active_2x <= '0';
            fill_line_2x   <= (others => '0');
            fill_way_2x    <= '0';
            fill_beat_2x   <= (others => '0');
            fill_mask_2x   <= (others => '1');
         elsif (fill_grant = '1') then
            fill_active_2x <= '1';
            fill_line_2x   <= fill_line_saved;
            fill_way_2x    <= data_way;
            fill_mask_2x   <= fill_mask;
            fill_beat_2x   <= (others => '0');
            if (ddr3_DOUT_READY = '1') then
               fill_beat_2x <= "01";
            end if;
         elsif (ram_active = '0') then
            -- The transaction this window belongs to is over. See the note on
            -- cache_wr_a below.
            fill_active_2x <= '0';
         elsif (fill_active_2x = '1' and ddr3_DOUT_READY = '1') then
            if (fill_beat_2x = "11") then
               fill_active_2x <= '0';
            else
               fill_beat_2x <= fill_beat_2x + 1;
            end if;
         end if;
      end if;
   end process;

   cache_ram_addr_a <= std_logic_vector(fill_line_saved & "00") when (fill_grant = '1') else
                       std_logic_vector(fill_line_2x & fill_beat_2x);

   -- A fill of a resident line's absent qwords must not overwrite the qwords
   -- the CPU stored: each beat writes only if its qword is in the fill's mask.
   fill_beat_now    <= "00" when (fill_grant = '1') else fill_beat_2x;
   fill_mask_now    <= fill_mask when (fill_grant = '1') else fill_mask_2x;
   cache_wr_a       <= (fill_active_2x or fill_grant) and ddr3_DOUT_READY and ram_active and
                       fill_mask_now(to_integer(fill_beat_now));

   -- A fill writes the victim's way: data_way until the grant latches it.
   fill_way_now     <= data_way when (fill_grant = '1') else fill_way_2x;
   cache_wr_a_w(0)  <= cache_wr_a and (not fill_way_now);
   cache_wr_a_w(1)  <= cache_wr_a and fill_way_now;

   gway : for w in 0 to 1 generate
   begin
      glane : for i in 0 to 7 generate
      begin
         icache: entity work.dpram
         generic map
         (
            addr_width  => 10,
            data_width  => 8
         )
         port map
         (
            clock_a     => clk1x,
            address_a   => cache_ram_addr_a,
            data_a      => ddr3_DOUT(((i * 8) + 7) downto (i*8)),
            wren_a      => cache_wr_a_w(w),

            clock_b     => clk93,
            address_b   => cache_address_b,
            data_b      => cache_data_b(((i * 8) + 7) downto (i*8)),
            wren_b      => cache_we_w(w) and cache_be_b(i),
            q_b         => cache_q_w(w)(((i * 8) + 7) downto (i*8))
         );
      end generate;
   end generate;

   cache_address_b <= std_logic_vector(tag_read_addr(12 downto 3)) when (state /= IDLE) else
                      std_logic_vector(tag_addr_1(12 downto 3)) when (ce_fetch = '0' or write_ena = '1') else
                      std_logic_vector(tag_addr(12 downto 3));

   -- In IDLE, the predicted way; in every other state - WAYFIX included - the
   -- way the state machine latched. The state machine is one-hot, so this is
   -- one LUT per bit: two RAM outputs, pred_way, state.IDLE and data_way.
   cache_q_b <= cache_q_w(1) when ((state = IDLE and pred_way = '1') or
                                   (state /= IDLE and data_way = '1')) else
                cache_q_w(0);

   little_endian_writes : if LITTLE_ENDIAN generate
      write_be_rot   <= write_be when (RW_64 = '1' or RW_addr(2) = '0') else
                        write_be(3 downto 0) & write_be(7 downto 4);
      write_data_rot <= write_data when (RW_64 = '1' or RW_addr(2) = '0') else
                        write_data(31 downto 0) & write_data(63 downto 32);
   end generate;

   big_endian_writes : if not LITTLE_ENDIAN generate
      write_be_rot   <= write_be when (RW_addr(2) = '0' and RW_64 = '0') else
                        write_be(3 downto 0) & write_be(7 downto 4);
      write_data_rot <= write_data when (RW_addr(2) = '0' and RW_64 = '0') else
                        write_data(31 downto 0) & write_data(63 downto 32);
   end generate;

   cache_data_b    <= write_data_1 when (stall4 = '1') else write_data_rot;
   cache_be_b      <= write_be_1   when (stall4 = '1') else write_be_rot;

   -- A store writes the way that hit; the store that caused a fill writes the
   -- filled way once the line is in, and a store that skipped it in ALLOC.
   cache_we_w(0)   <= '1' when ((state = IDLE and hit_w(0) = '1' and write_ena = '1') or
                                (writeMode = '1' and state = FILL and ram_done = '1' and
                                 data_way = '0') or
                                (state = ALLOC and data_way = '0')) else '0';
   cache_we_w(1)   <= '1' when ((state = IDLE and hit_w(1) = '1' and write_ena = '1') or
                                (writeMode = '1' and state = FILL and ram_done = '1' and
                                 data_way = '1') or
                                (state = ALLOC and data_way = '1')) else '0';

   write_done      <= '1'     when (write_through_in = '1' and
                                    state = IDLE and write_ena = '1' and
                                    fifo_block = '0') else
                       wb_done when (force_wb = '1') else
                       '1'     when ((state = IDLE and read_hit = '1' and write_ena = '1') or (writeMode = '1' and state = FILL and ram_done = '1')) else
                       '1'     when (state = ALLOC) else
                       '0';

   read_busy       <= '1' when (state = READWAIT or state = WAITSLOW or state = FILL or
                                state = WAYFIX) else '0';

   read_done       <= '1' when (state = IDLE and write_ena_1 = '0' and fast_hit = '1' and read_ena = '1' and slow_on = '0') else
                      '1' when (state = READWAIT) else
                      '1' when (state = WAYFIX) else
                      '1' when (state = WAITSLOW and slowcnt = 0) else
                      '1' when (writeMode = '0' and state = FILL and ram_done = '1') else
                      '0';

   read_data       <= cache_q_b                        when (RW_addr(2 downto 0) = "000") else
                      8x"0"  & cache_q_b(63 downto  8) when (RW_addr(2 downto 0) = "001") else
                      16x"0" & cache_q_b(63 downto 16) when (RW_addr(2 downto 0) = "010") else
                      24x"0" & cache_q_b(63 downto 24) when (RW_addr(2 downto 0) = "011") else
                      32x"0" & cache_q_b(63 downto 32) when (RW_addr(2 downto 0) = "100") else
                      40x"0" & cache_q_b(63 downto 40) when (RW_addr(2 downto 0) = "101") else
                      48x"0" & cache_q_b(63 downto 48) when (RW_addr(2 downto 0) = "110") else
                      56x"0" & cache_q_b(63 downto 56); -- when (RW_addr(2 downto 0) = "111")

   CachecommandStall <= '1' when (CacheCommandEna = '1' and CacheCommand = 5x"01") else
                        '1' when (CacheCommandEna = '1' and CacheCommand = 5x"05") else
                        '1' when (CacheCommandEna = '1' and CacheCommand = 5x"09") else
                        '1' when (CacheCommandEna = '1' and CacheCommand = 5x"0D") else
                        '1' when (CacheCommandEna = '1' and CacheCommand = 5x"11") else
                        '1' when (CacheCommandEna = '1' and CacheCommand = 5x"15") else
                        '1' when (CacheCommandEna = '1' and CacheCommand = 5x"19") else
                        '0';

   process (clk93)
   begin
      if rising_edge(clk93) then

         ram_request       <= '0';
         writeback_ena     <= '0';
         stride_hit_i      <= '0';
         delta_hit_i       <= '0';
         -- perf_miss is one cycle per allocating miss; sample the line address
         -- on it and compare against the previous one, and the delta against
         -- the previous delta.
         if (perf_miss_i = '1') then
            last_miss_line <= RW_addr(31 downto 5);
            last_miss_seen <= '1';
            if (last_miss_seen = '1') then
               last_delta    <= RW_addr(31 downto 5) - last_miss_line;
               last_delta_ok <= '1';
               if (RW_addr(31 downto 5) = last_miss_line + 1) then
                  stride_hit_i <= '1';
               end if;
               if (last_delta_ok = '1' and
                   (RW_addr(31 downto 5) - last_miss_line) = last_delta and
                   (RW_addr(31 downto 5) - last_miss_line) /= 0) then
                  delta_hit_i <= '1';
               end if;
            end if;
         end if;
         CachecommandDone  <= '0';
         tag_wren_cmd      <= '0';
         wb_done           <= '0';
         writeTagEna       <= '0';

         -- synthesis translate_off
         -- READWAIT and WAYFIX deliver the data RAMs' NEXT read, so that read
         -- must be of the load's own doubleword. In the CPU it is because
         -- ce_fetch is low in the load's IDLE cycle - every load sets stall3 as
         -- it enters stage 3 - but nothing in this file guarantees it.
         if (state = IDLE and SS_reset = '0' and read_ena = '1' and read_hit = '1' and
             slow_on = '0' and (write_ena_1 = '1' or fast_hit = '0') and
             cache_address_b /= std_logic_vector(tag_addr_1(12 downto 3))) then
            report "cpu_datacache: a load left IDLE for READWAIT/WAYFIX but the data RAMs are re-reading another address"
               severity failure;
         end if;
         -- ALLOC's tag and store land in the same cycle; see the state.
         if (state = ALLOC and tag_wren_cmd /= '1') then
            report "cpu_datacache: ALLOC without its tag write" severity failure;
         end if;
         -- Only a 64-bit store may skip its fill, and only a line with an
         -- absent qword may be filled around its present ones.
         if (state = ALLOC and (writeMode /= '1' or write_be_1 /= x"FF")) then
            report "cpu_datacache: ALLOC for an access that is not a 64-bit store" severity failure;
         end if;
         if (state = FILL and ram_request = '1' and fill_mask = "0000") then
            report "cpu_datacache: a fill with no qword to write" severity failure;
         end if;
         -- synthesis translate_on

         if (ce_fetch = '1') then
            tag_addr_1   <= tag_addr;
            tag_newEna   <= "00";
            for w in 0 to 1 loop
               if (tag_wren_w(w) = '1') then
                  tag_newData(w) <= tag_wdata(w);
                  if (tag_address_a = std_logic_vector(tag_addr(12 downto 5))) then
                     tag_newEna(w) <= '1';
                  end if;
               end if;
            end loop;
         else
            for w in 0 to 1 loop
               if (tag_wren_w(w) = '1') then
                  tag_newData(w) <= tag_wdata(w);
                  if (tag_address_a = std_logic_vector(tag_addr_1(12 downto 5))) then
                     tag_newEna(w) <= '1';
                  end if;
               end if;
            end loop;
         end if;

         force_wb <= force_wb_in;

         slow    <= unsigned(slow_in);
         slow_on <= '0';
         if (slow > 0) then
            slow_on <= '1';
         end if;

         if (slowcnt > 0) then
            slowcnt <= slowcnt - 1;
         end if;

         if (SS_reset = '1') then
            state          <= CLEARCACHE;
            clearAddr      <= (others => '0');
         else

            case(state) is

               when IDLE =>
                  writeMode      <= write_ena;
                  write_be_1     <= write_be_rot;
                  write_data_1   <= write_data_rot;
                  fillNext       <= '0';
                  write_ena_1    <= write_ena;
                  fillAddr       <= unsigned(tag_compare(19 downto 1)) & RW_addr(12 downto 5) & "00000";
                  fill_line_saved <= tag_addr_1(12 downto 5);
                  tag_addr_low   <= tag_addr_1(4 downto 0);
                  tag_read_addr  <= tag_addr_1(13 downto 0);
                  isCommand      <= '0';
                  isWB           <= '0';
                  allocNext      <= '0';
                  ram_reqAddr    <= RW_addr(31 downto 0);
                  tag_data_cmd   <= "0000" & (write_ena and (not write_through_in)) &
                                    '1' & std_logic_vector(RW_addr(31 downto 12)); -- default for fill
                  tag_addr_cmd   <= std_logic_vector(tag_addr_1(12 downto 5));
                  writeback_addr <= unsigned(tag_compare(19 downto 1)) & RW_addr(12 downto 5) & "00000";
                  -- The victim's (or an index op's) present qwords; the hit
                  -- write-backs below name their own line's.
                  wb_mask        <= not tag_compare(25 downto 22);
                  fill_mask      <= "1111";
                  data_way       <= sel_way;
                  if (sel_way = '1') then
                     tag_way_cmd <= "10";
                  else
                     tag_way_cmd <= "01";
                  end if;

                  if (write_ena = '1' and read_hit = '0' and
                      write_through_in = '1') then
                     -- Write-through misses are committed by the CPU memory
                     -- path without allocating a cache line.
                     state <= IDLE;

                  elsif ((read_ena = '1' or write_ena = '1') and read_hit = '0' and
                         line_hit = '1') then
                     -- The line is here but this qword is not: a load of it,
                     -- or a store that does not cover it. Fill the absent
                     -- qwords only - nothing is evicted, so nothing is written
                     -- back - and the line keeps its dirty bit.
                     state          <= FILL;
                     ram_request    <= '1';
                     fill_beat_seen <= '0';
                     fill_mask      <= hit_absent;
                     tag_data_cmd(21) <= hit_dirty or (write_ena and (not write_through_in));
                     if (write_ena = '1' and force_wb = '1') then
                        isWB <= '1';
                     end if;

                  elsif ((read_ena = '1' or write_ena = '1') and read_hit = '0') then
                     if (skip_ok = '1') then
                        -- Only the store's own qword will be in the line.
                        tag_data_cmd(25 downto 22) <= not store_clear;
                     end if;
                     -- tag_compare is the victim here, so this is its dirty bit.
                     if (tag_compare(21) = '1') then
                        state          <= WRITEBACK1ADDR;
                        tag_read_addr(4 downto 0) <= "00000";
                        fillNext       <= '1';
                        allocNext      <= skip_ok;
                     elsif (skip_ok = '1') then
                        state          <= ALLOC;
                        tag_wren_cmd   <= '1';
                     else
                        state          <= FILL;
                        ram_request    <= '1';
                        fill_beat_seen <= '0';
                        if (write_ena = '1' and force_wb = '1') then
                           isWB <= '1';
                        end if;
                     end if;

                  elsif (write_ena = '1' and read_hit = '1' and force_wb = '1') then
                     state          <= WRITEBACK1ADDR;
                     isWB           <= '1';
                     tag_read_addr(4 downto 0) <= "00000";
                     writeback_addr <= RW_addr(31 downto 5) & "00000";
                     wb_mask        <= not (hit_absent and (not store_clear));

                  elsif (read_ena = '1' and slow_on = '1') then
                     state       <= WAITSLOW;
                     slowcnt     <= slow - 1;

                  elsif (write_ena_1 = '1' and read_ena = '1' and read_hit = '1') then
                     state <= READWAIT;

                  elsif (read_ena = '1' and read_hit = '1' and fast_hit = '0') then
                     -- A hit, but in the way the prediction did not pick.
                     state <= WAYFIX;

                  elsif (CacheCommandEna = '1') then
                     state          <= COMMANDPROCESS;
                     isCommand      <= '1';
                     tag_read_addr(4 downto 0) <= "00000";
                     writeTagValue  <= tag_compare(20) & tag_compare(21) & unsigned(tag_compare(19 downto 0)); -- valid & dirty & 20 bit address

                     case (CacheCommand) is

                        -- A command's "hit" is the line being resident, absent
                        -- qwords or not. A line that stays valid keeps its absent
                        -- bits: they are what stops its empty qwords being read
                        -- or written back.
                        when 5x"01" => -- dcache index write back invalidate
                           if (tag_compare(21 downto 20) = "11") then
                              state          <= WRITEBACK1ADDR;
                           end if;
                           tag_wren_cmd    <= '1';
                           tag_data_cmd    <= "000000" & tag_compare(19 downto 0);

                        when 5x"05" => -- dcache index load tag
                           writeTagEna <= '1';

                        when 5x"09" => -- dcache index store tag
                           tag_wren_cmd    <= '1';
                           tag_data_cmd    <= tag_compare(25 downto 22) & TagLo_Dirty & TagLo_Valid &
                                              std_logic_vector(TagLo_Addr);

                        when 5x"0D" => -- dcache create dirty exclusive
                           -- A line that hits is just re-tagged dirty; on a miss
                           -- the victim is taken and written back if dirty.
                           if (line_hit = '0' and tag_compare(21) = '1') then
                              state          <= WRITEBACK1ADDR;
                           end if;
                           tag_wren_cmd    <= '1';
                           if (line_hit = '1') then
                              tag_data_cmd <= hit_absent & "11" & std_logic_vector(RW_addr(31 downto 12));
                           else
                              tag_data_cmd <= "0000" & "11" & std_logic_vector(RW_addr(31 downto 12));
                           end if;

                        when 5x"11" => -- dcache hit invalidate
                           if (line_hit = '1') then
                              tag_wren_cmd    <= '1';
                              tag_data_cmd    <= "000000" & std_logic_vector(RW_addr(31 downto 12));
                           end if;

                        when 5x"15" => -- dcache hit write back invalidate
                           if (line_hit = '1') then
                              if (hit_dirty = '1') then
                                 state          <= WRITEBACK1ADDR;
                                 writeback_addr <= RW_addr(31 downto 5) & "00000";
                                 wb_mask        <= not hit_absent;
                              end if;
                              tag_wren_cmd    <= '1';
                              tag_data_cmd    <= "000000" & std_logic_vector(RW_addr(31 downto 12));
                           end if;

                        when 5x"19" => -- dcache hit write back
                           if (line_hit = '1' and hit_dirty = '1') then -- should this really check for dirty?
                              state          <= WRITEBACK1ADDR;
                              writeback_addr <= RW_addr(31 downto 5) & "00000";
                              wb_mask        <= not hit_absent;
                              tag_wren_cmd   <= '1';
                              tag_data_cmd   <= hit_absent & "01" & std_logic_vector(RW_addr(31 downto 12));
                           end if;

                        when others => state <= IDLE;
                     end case;

                  end if;

               when CLEARCACHE =>
                  tag_wren_cmd <= '1';
                  tag_way_cmd  <= "11";
                  tag_addr_cmd <= clearAddr;
                  tag_data_cmd <= (others => '0');
                  if (clearAddr /= 8x"FF") then
                     clearAddr <= std_logic_vector(unsigned(clearAddr) + 1);
                  else
                     state          <= IDLE;
                  end if;

               when FILL =>
                  if (ram_request = '1') then
                     tag_wren_cmd   <= '1';
                  end if;
                  -- ddr3_DOUT_READY is SHARED with the instruction cache
                  -- (cpu.vhd feeds both from one signal), so an unqualified
                  -- test sets this on the other cache's beats. Hardware showed
                  -- exactly that: F1 read 0 in a frame with heavy instruction
                  -- traffic, because the flag was already set on entry.
                  -- fill_active_2x is set by THIS cache's fill_grant, so it
                  -- qualifies the beat as ours.
                  if (ddr3_DOUT_READY = '1' and fill_active_2x = '1') then
                     fill_beat_seen <= '1';
                  end if;
                  if (ram_done = '1') then
                     state          <= IDLE;
                     if (isWB = '1') then
                        state          <= WRITEBACK1ADDR; 
                        writeback_addr <= fillAddr(31 downto 5) & "00000";
                     end if;
                  end if;
                  
               when READWAIT =>
                  state <= IDLE;
                  
               when WAITSLOW =>
                  if (slowcnt = 0) then
                     state <= IDLE;
                  end if;
                  
               when WRITEBACK1ADDR =>
                  if (fifo_block = '0') then
                     state <= WRITEBACK1READ;
                  end if;
               
               when WRITEBACK1READ =>
                  state            <= WRITEBACK1WRITE;
                  tag_read_addr(3) <= '1';
               
               when WRITEBACK1WRITE =>
                  state          <= WRITEBACK2WRITE;
                  writeback_ena  <= '1';
                  tag_read_addr(4 downto 3) <= "10";
                  if LITTLE_ENDIAN then
                     writeback_data <= cache_q_b;
                  else
                     writeback_data <= cache_q_b(31 downto 0) & cache_q_b(63 downto 32);
                  end if;
               
               when WRITEBACK2WRITE =>
                  state             <= WRITEBACK3WRITE;
                  writeback_ena     <= '1';
                  if LITTLE_ENDIAN then
                     writeback_data <= cache_q_b;
                  else
                     writeback_data <= cache_q_b(31 downto 0) & cache_q_b(63 downto 32);
                  end if;
                  writeback_addr(3) <= '1';
                  -- The cache RAM read is registered, so the address presented
                  -- HERE selects the word that beat 4 writes back. Without it
                  -- the address stays at "10" through WRITEBACK3WRITE, beat 4
                  -- re-reads word 2, and the last 8 bytes of every dirty line
                  -- are lost. The donor's 16-byte line only needed two beats
                  -- and did not expose this. See
                  -- sim/tb_ki_datacache_writeback.sv.
                  tag_read_addr(4 downto 3) <= "11";

               when WRITEBACK3WRITE =>
                  state          <= WRITEBACK4WRITE;
                  writeback_ena  <= '1';
                  if LITTLE_ENDIAN then
                     writeback_data <= cache_q_b;
                  else
                     writeback_data <= cache_q_b(31 downto 0) & cache_q_b(63 downto 32);
                  end if;
                  writeback_addr(4 downto 3) <= "10";
                  tag_read_addr(4 downto 3) <= "11";

               when WRITEBACK4WRITE =>
                  state          <= WRITEBACKDONE;
                  writeback_ena  <= '1';
                  if LITTLE_ENDIAN then
                     writeback_data <= cache_q_b;
                  else
                     writeback_data <= cache_q_b(31 downto 0) & cache_q_b(63 downto 32);
                  end if;
                  writeback_addr(4 downto 3) <= "11";

               when WRITEBACKDONE =>
                  tag_read_addr(4 downto 0) <= tag_addr_low;
                  if (fifo_block = '0') then
                     fillNext <= '0';
                     if (fillNext = '1' and allocNext = '1') then
                        -- The victim is out; take the line without its fill.
                        state        <= ALLOC;
                        tag_wren_cmd <= '1';
                     elsif (fillNext = '1') then
                        state       <= FILL;
                        ram_request <= '1';
                        -- The IDLE -> FILL path clears this, and so must
                        -- this one: left set from the previous fill, the
                        -- wait for the first beat of a fill that follows a
                        -- writeback is filed as F3 and F1 reads 0. That
                        -- skewed every hardware split with dirty misses.
                        -- Perf-only: nothing else reads fill_beat_seen.
                        fill_beat_seen <= '0';
                        if (writeMode = '1' and force_wb = '1') then
                           isWB <= '1';
                        end if;
                     else
                        state             <= IDLE;
                        CachecommandDone  <= isCommand;
                        wb_done           <= isWB;
                     end if;
                  end if;
                  
               when COMMANDPROCESS =>
                  state <= COMMANDDONE;
                  
               when COMMANDDONE =>
                  state             <= IDLE;
                  CachecommandDone  <= '1';
                  
               when WAYFIX =>
                  state <= IDLE;

               -- One cycle, entered with tag_wren_cmd set: the line's tag -
               -- only the store's qword present - is written in this cycle,
               -- the store's data with it (cache_we_w), and write_done
               -- releases stage 4. The next access sees the tag through
               -- tag_newData exactly as it would after a FILL.
               when ALLOC =>
                  state <= IDLE;

            end case;

         end if;

      end if;
   end process;

end architecture;
