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
      SKIP_FILL     : boolean := false;
      -- After a load's line fills, fetch the NEXT line in the background into
      -- a staging register, and let a miss on that line fill from it. See
      -- "READING AHEAD" in the architecture.
      READ_AHEAD    : boolean := false;
      -- A PARTIAL store to a framebuffer line (RW_fb) skips its fill too,
      -- with the line's written bytes tracked beside its tag. Needs
      -- SKIP_FILL. See "PARTIAL FRAMEBUFFER STORES" in the architecture.
      FB_PARTIAL    : boolean := false;
      -- A write-back followed by an ALLOC does not wait for the clk1x side to
      -- take the line (WRITEBACKDONE); see there. Needs the line's mask
      -- latched with its words, which cpu.vhd does.
      WB_EARLY      : boolean := false;
      -- The CPU stalls stage 3 behind a load only when the next instruction
      -- reads the loaded register (cpu.vhd's LOAD_INTERLOCK), so ce_fetch can
      -- be high in a load's IDLE cycle. See "LOADS WITHOUT THE BUBBLE".
      LOAD_INTERLOCK : boolean := false;
      -- A store that hits parks in a one-entry buffer instead of writing the
      -- data RAMs in its own cycle. See "THE STORE BUFFER".
      STORE_BUFFER   : boolean := false
   );
   port 
   (
      clk1x             : in  std_logic;
      clk93             : in  std_logic;
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
      -- The same line's bytes, bit 8i+j for byte j of qword i: every byte of
      -- a present qword, and of an absent one only those a partial
      -- framebuffer store wrote (FB_PARTIAL). Held with writeback_mask.
      writeback_bytes   : out std_logic_vector(31 downto 0) := (others => '1');
      
      tag_addr          : in  unsigned(31 downto 0);
      -- The instruction in stage 3 is a load: the data RAMs' read this cycle
      -- is its. The store buffer drains only when it is not.
      next_load         : in  std_logic := '1';
      
      read_ena          : in  std_logic;
      RW_addr           : in  unsigned(31 downto 0);
      RW_64             : in  std_logic;
      -- The access is to a framebuffer page (cpu.vhd's executeMemFB).
      RW_fb             : in  std_logic := '0';
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

      -- High while the tags clear after reset (CLEARCACHE). An access
      -- presented then is lost - the state machine takes one only in IDLE -
      -- so cpu.vhd holds the first fetch until it falls (boot_hold).
      clear_busy        : out std_logic;
      debug_state       : out std_logic_vector(4 downto 0) := (others => '0');
      -- Why stage 4 is waiting on this cache, for the stall census. These
      -- separate the two causes of DC - stall4 on a CACHED access - which
      -- have opposite fixes: the cache queued behind another bus master, or
      -- the cache doing its own extra traffic.
      --   perf_miss       one pulse per allocating miss (a line fill starts)
      --   perf_writeback  evicting a dirty line (write-back traffic)
      --
      -- perf_miss makes DC divisible - DC cycles over miss count is cycles
      -- per miss. The census exports DC in units of 256 cycles and MC as a
      -- plain count, so scale DC back up before dividing. ~20-30 says the
      -- misses are normal and there are simply too many of them; ~200+ says
      -- the memory path itself is the problem.
      perf_miss         : out std_logic := '0';
      -- The same miss, when it lands in the board's SRAM rather than its DRAM.
      --
      -- KI has TWO memory devices: 512 KiB of 20ns SRAM at 0x00000000 (16x
      -- IDT71256SA20Y) and 8 MiB of Fast Page Mode DRAM at 0x08000000 (16x
      -- MT4C4001). This core serves the framebuffer pages from on-chip M10K
      -- and EVERYTHING ELSE from SDRAM, so the low 192 KiB of what the board
      -- builds from 20ns SRAM costs a miss to SDRAM here. Pairing this with
      -- perf_miss gives the split: perf_miss_low is the SRAM region, and
      -- perf_miss - perf_miss_low is the DRAM region.
      --
      -- RW_addr is PHYSICAL here - ki_board_pkg puts low RAM at 0x00000000
      -- and main RAM at 0x08000000, and the bridge compares the address it
      -- receives against those - so the test is just the top bits being zero.
      perf_miss_low     : out std_logic := '0';
      -- The fill interval, split exhaustively rather than sampled by proxy:
      -- a partition of the FILL state itself, with a sum check.
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
      -- at the end of a clk1x-to-clk93 mailbox round trip, so the tail after
      -- the data is a cost of its own.
      --
      -- "Every beat in" is the design's own fill_active_2x, not a separate
      -- beat count: ddr3_DOUT_READY is a per-beat pulse from the bridge but
      -- can be a held level in a testbench, so counting its edges works on
      -- hardware and silently sees one beat in simulation. fill_active_2x
      -- is set on the grant and cleared after the fourth beat either way. It
      -- is a clk1x level read from clk93; it changes once per fill, so the
      -- worst case is attributing a cycle to the neighbouring phase.
      -- Is this miss the NEXT line after the previous one? A next-line
      -- prefetcher needs no instruction-level parallelism, which matters
      -- because the CPU retires only a few instructions per miss in the frames
      -- where the data cache dominates - there is nothing to overlap, but a
      -- linear stream can still be run ahead of.
      --
      -- Counted at line granularity, so it answers exactly the question a
      -- prefetcher would ask: was address(31:5) one more than last time.
      -- Load misses only, against the previous load miss: store misses skip
      -- their fill and a read-ahead would not help them.
      perf_stride_hit   : out std_logic := '0';
      -- Does this miss repeat the PREVIOUS delta? A pattern that never
      -- touches consecutive lines is what a constant NON-UNIT stride does,
      -- so this counts that: same line delta as last time, delta not zero. A
      -- strided prefetcher works on this where a next-line one cannot, and
      -- like next-line it needs no instruction-level parallelism.
      perf_delta_hit    : out std_logic := '0';
      perf_fill_wait    : out std_logic := '0';
      perf_fill_data    : out std_logic := '0';
      perf_fill_hold    : out std_logic := '0';
      perf_writeback    : out std_logic := '0';
      -- High in WAYFIX: one cycle per load that hit in the way the prediction
      -- did not pick. Each such load costs the CPU 2 cycles, not 1: WAYFIX
      -- itself, and stage 3's release, which for any load that leaves IDLE
      -- waits a further edge for writebackNew (READWAIT pays the same). See
      -- the note below.
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
      -- In the heavy frames almost all store-miss fills are never read: the
      -- line is written whole by 64-bit stores. perf_fill_skip is those fills
      -- not happening, and perf_fill_absent what it costs when a skipped
      -- qword is wanted after all.
      perf_wb_line      : out std_logic := '0';
      perf_fill_store   : out std_logic := '0';
      perf_fill_skip    : out std_logic := '0';
      perf_fill_absent  : out std_logic := '0';
      -- Read ahead (READ_AHEAD). ra_request asks the scheduler, at its lowest
      -- priority, for the four qwords of the line at ra_reqAddr; they arrive
      -- in ra_data, stable from ra_done until the next read-ahead completes.
      -- ra_store is every store entering the write FIFO - write-backs and
      -- uncached stores alike - with its address: one landing in the line
      -- being read ahead makes the copy stale.
      --   perf_ra_issue  one pulse per read-ahead issued
      --   perf_ra_used   one pulse per miss that filled from the staged line
      ra_request        : out std_logic := '0';
      ra_reqAddr        : out unsigned(31 downto 0) := (others => '0');
      ra_done           : in  std_logic := '0';
      ra_data           : in  std_logic_vector(255 downto 0) := (others => '0');
      ra_store          : in  std_logic := '0';
      ra_store_addr     : in  unsigned(31 downto 0) := (others => '0');
      perf_ra_issue     : out std_logic := '0';
      perf_ra_used      : out std_logic := '0';
      SS_reset          : in  std_logic
   );
end entity;

architecture arch of cpu_datacache is

   -- Sets, as a power of two: 256, the R4600's, which with two 32-byte ways
   -- is its 16 KB. The rest of the geometry derives from it (IDX_HI below),
   -- including which address bit an index cache op takes its way from.
   constant SET_BITS : integer := 8;

   -- The index is address(IDX_HI downto 5) and the line within it
   -- address(4 downto 0). The stored tag is address(31 downto 12) - that is
   -- what the architecture's TagLo carries - so a hit compares only the part
   -- above the index, tag(19 downto TAG_LO) against address(31 downto
   -- IDX_HI + 1).
   constant IDX_HI : integer := SET_BITS + 4;
   constant TAG_LO : integer := SET_BITS - 7;

   -- 2-WAY SET-ASSOCIATIVE: 2**SET_BITS sets x 2 ways x 32-byte lines, write
   -- back, LRU - 16 KB, the geometry of the real R4600's D-cache. Two ways
   -- rather than one because of KI's per-frame block copies: with two ways
   -- the reads stop evicting the working buffer's dirty lines.
   --
   -- The set index is address(IDX_HI..5) and the stored tag address(31..12),
   -- so a hit compares address(31..IDX_HI+1). Index cache ops name their way
   -- with address bit IDX_HI+1, the bit just above the index - bit 13, as the
   -- R4600's is; hit ops act on whichever way hits.
   --
   -- WAY PREDICTION. Both ways' tags and data are read in parallel, one stage
   -- early. Selecting the data with the tag compare would put a 19-bit
   -- compare in front of the load path, which has no timing to spare - so
   -- the data comes from the way most recently used in its set instead. That is one bit per
   -- set, read from its own RAM alongside the tags, so the select is a RAM
   -- output like the data itself. The compares still decide hit or miss. A
   -- hit in the OTHER way is correct but late: it goes through WAYFIX, which
   -- delivers from the way that hit on the RAMs' next read. That is READWAIT's
   -- mechanism and rests on the same fact: every cached load stalls stage 3
   -- in its issue cycle (the load-delay stall in cpu.vhd), so ce_fetch is low
   -- and the data RAMs re-read the load's own address. An assertion below
   -- checks it.
   --
   -- LOADS WITHOUT THE BUBBLE (LOAD_INTERLOCK). The load-delay stall above is
   -- then taken only when the instruction behind the load reads its register,
   -- as on the R4600, and otherwise that instruction executes in stage 3 while
   -- the load is here in IDLE - ce_fetch high, so the data RAMs read ITS
   -- address, not the load's. Three things follow. A load that needs the
   -- RAMs' next read - READWAIT, WAYFIX, WAITSLOW - goes through REREAD first,
   -- one cycle in which they read the load's own doubleword. read_data's
   -- alignment comes from RW_addr, which belongs to the next instruction once
   -- stage 3 moves on, so it is latched here in IDLE (rd_low). And an access
   -- can reach IDLE straight from a busy cycle, whose RAM read was
   -- tag_read_addr, so ram_stale - the store-then-load flag - is also set by
   -- every busy state. Each costs the cycle the bubble would otherwise hide,
   -- and only on the loads that take those paths; the common hit loses its
   -- bubble.
   --
   -- THE STORE BUFFER (STORE_BUFFER). Without it a store that hits writes the
   -- data RAMs through port b in its own IDLE cycle, so the RAMs cannot read
   -- the next access's address then, and a load straight after a store goes
   -- through READWAIT. In KI2's background renderer that is the bottom of
   -- three loops against the top, every store and load to different lines.
   -- With it the store parks - address, way, data, byte enables - and the
   -- RAMs read on as if it were not there; its tag is updated at once. It is
   -- written when the port is free:
   --   * in IDLE with nothing presented, the pipeline moving and stage 3 not
   --     a load (next_load), so nobody wants this cycle's read;
   --   * by the next store to another doubleword, which parks in its place (a
   --     store to the same doubleword and way merges instead);
   --   * by a load of the buffered doubleword, which then re-reads (REREAD);
   --   * by a command;
   --   * in the first cycle of FILL, the dirty victim's WRITEBACK1ADDR and
   --     FILLRA_WAIT, which leave the port idle - so a line is never read,
   --     written back, filled around or copied over while a store to it waits.
   -- ALLOC, READWAIT, WAYFIX, REREAD and WAITSLOW keep it: none touches a line
   -- that can hold it (the buffered line is dirty, so it is never evicted
   -- without the write-back). Nothing selecting the RAM address depends on the
   -- tag compare.
   --
   -- The same bit is the LRU state. It is written in the access's own IDLE
   -- cycle, not registered first: the access after a load reads it at the end
   -- of the NEXT cycle, the load-delay bubble, which is exactly where a
   -- registered write would land. It has no bypass: a store followed at once
   -- by an access to the same set reads it on the same edge it is written,
   -- and gets the old value - the RAM is OLD_DATA across its ports (gmru),
   -- in simulation and on hardware alike. That costs a cycle or picks a
   -- worse victim - a load there goes through READWAIT and never uses the
   -- prediction - but it can never give a wrong answer.
   --
   -- SKIPPING THE STORE-MISS FILL (SKIP_FILL). In the heavy frames most
   -- misses are stores, and almost none of those fills are ever read: the
   -- line is written whole, every qword by a 64-bit store, before anything
   -- loads it. So a 64-bit store that misses takes its line
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
   -- (tag_newData) covers them. That bypass is what keeps a store's data: a
   -- stale absent bit would let a later fill overwrite a stored qword. The
   -- dirty bit relies on it too.
   --
   -- READING AHEAD (READ_AHEAD). KI's heavy frames miss almost always on the
   -- line after the previous miss, so when a load's line fills, the line
   -- after it is fetched in the background, and a miss on it fills from that
   -- copy in a few cycles instead of a full SDRAM round trip.
   --
   -- The copy lives OUTSIDE the cache, in cpu.vhd's staging register, because
   -- nothing inside can safely change while the CPU runs on: the CPU presents
   -- a cache access for exactly one cycle, so the cache cannot make it wait in
   -- IDLE, and its RAMs and tags are the CPU's between misses. The background
   -- part is therefore only a bridge transaction and a register. The cache is
   -- touched where it always is - in a miss, with stage 4 held:
   --
   --   * a miss on the staged line - a load, or a store that needs its line -
   --     takes the victim exactly as any miss does (write-back included),
   --     then copies the four staged qwords into it, FILLRA_COPY, instead of
   --     asking the bridge; a copy still in flight is waited for, FILLRA_WAIT;
   --   * that miss, if a load, asks for the NEXT line, so a stream runs on;
   --   * a 64-bit store that skips its fill takes ALLOC as before and throws
   --     the copy away - defensively: the line it leaves is dirty, so its
   --     eviction's write-back would make the copy stale anyway;
   --   * any store to the staged line reaching the write FIFO after the
   --     read-ahead was asked for - a write-back or an uncached store - makes
   --     the copy stale, and a miss on it then fills the ordinary way;
   --   * the line after is only asked for inside the same 4 KB page, so a
   --     read-ahead can never step out of the memory the load was in.
   --
   -- A read-ahead of a line already in the cache is harmless: a hit never
   -- looks at the copy, and by the time that line can miss it has been
   -- evicted - dirty through a write-back the FIFO sees, or clean and so
   -- still what SDRAM holds.
   --
   -- What it costs: the bridge serves one transaction at a time, so a miss on
   -- some OTHER line while a read-ahead is in flight - its fill, or its
   -- victim's write-back - waits for the read-ahead first, up to a round trip.
   --
   -- ARMING (ra_arm). In KI1's fight scenes few load misses are on the next
   -- line, and reading ahead for all of them would put that wait on nearly
   -- every miss. So a read-ahead is asked for only when the load miss that
   -- would trigger it was ITSELF on the line after the previous load miss -
   -- the same test SH counts. A stream arms on its second miss and stays
   -- armed (a miss served from the copy is still a next-line miss); scattered
   -- misses never arm it.

   signal ce_fetch         : std_logic;

   type t_tag  is array(0 to 1) of std_logic_vector(57 downto 0);
   type t_data is array(0 to 1) of std_logic_vector(63 downto 0);

   -- tags: bytes(31..0) & absent(3..0) & dirty & valid & address(31..12),
   -- one RAM per way. Absent bit i is the qword at offset 8i; always zero
   -- without SKIP_FILL. bytes(8i+7..8i) are the bytes of an ABSENT qword i a
   -- partial framebuffer store has written; meaningless for a present one,
   -- always zero without FB_PARTIAL.
   signal tag_address_a    : std_logic_vector(SET_BITS - 1 downto 0);
   signal tag_wdata        : t_tag;
   signal tag_wren_w       : std_logic_vector(1 downto 0);
   signal tag_address_b    : std_logic_vector(SET_BITS - 1 downto 0);
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
   signal tag_compare      : std_logic_vector(57 downto 0);
   -- A store that covers its whole qword, the qword's bit if so, and whether
   -- a miss by this store may skip its fill.
   signal store_full       : std_logic;
   -- A partial framebuffer store (FB_PARTIAL): it may allocate without a fill
   -- or hit an absent qword. store_ok is either kind; store_bytes the store's
   -- bytes placed in the line.
   signal store_part       : std_logic;
   signal store_ok         : std_logic;
   signal store_bytes      : std_logic_vector(31 downto 0);
   -- The hit line's written bytes, and its bytes and absent qwords as this
   -- store will leave them.
   signal hit_bytes        : std_logic_vector(31 downto 0);
   signal hit_bytes_st     : std_logic_vector(31 downto 0);
   signal hit_absent_st    : std_logic_vector(3 downto 0);
   signal alloc_part_1     : std_logic := '0';
   signal store_clear      : std_logic_vector(3 downto 0);
   signal skip_ok          : std_logic;

   -- most recently used way, one bit per set: the prediction and the LRU state
   signal mru_wren         : std_logic;
   signal mru_waddr        : std_logic_vector(7 downto 0);
   signal mru_wdata        : std_logic_vector(0 downto 0);
   signal mru_q            : std_logic_vector(0 downto 0) := "0";
   signal pred_way         : std_logic;
   -- The way every state but IDLE reads and writes, latched in IDLE.
   signal data_way         : std_logic := '0';

   signal tag_addr_1       : unsigned(31 downto 0) := (others => '0');
   signal tag_addr_low     : unsigned(4 downto 0) := (others => '0');
   signal tag_read_addr    : unsigned(SET_BITS + 5 downto 0) := (others => '0');
   signal fillAddr         : unsigned(31 downto 0) := (others => '0');

   -- data
   signal fill_line_saved  : unsigned(SET_BITS - 1 downto 0) := (others => '0');
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
   signal wb_bytes         : std_logic_vector(31 downto 0) := (others => '1');
   -- The bytes a fill must NOT overwrite - a resident line's partially
   -- written absent qwords - latched with fill_mask, read from clk1x.
   signal fill_bytes       : std_logic_vector(31 downto 0) := (others => '0');
   signal fill_bytes_2x    : std_logic_vector(31 downto 0) := (others => '0');
   signal fill_bytes_now   : std_logic_vector(31 downto 0);
   signal fill_keep        : std_logic_vector(7 downto 0);

   -- A line's qwords to write back and their bytes: a present qword whole, an
   -- absent one only for the bytes a partial store left in it.
   function wb_q(absent : std_logic_vector(3 downto 0);
                 bytes  : std_logic_vector(31 downto 0)) return std_logic_vector is
      variable r : std_logic_vector(3 downto 0);
   begin
      for q in 0 to 3 loop
         if (absent(q) = '0' or bytes(q * 8 + 7 downto q * 8) /= x"00") then
            r(q) := '1';
         else
            r(q) := '0';
         end if;
      end loop;
      return r;
   end function;
   function wb_b(absent : std_logic_vector(3 downto 0);
                 bytes  : std_logic_vector(31 downto 0)) return std_logic_vector is
      variable r : std_logic_vector(31 downto 0);
   begin
      for q in 0 to 3 loop
         if (absent(q) = '0') then
            r(q * 8 + 7 downto q * 8) := x"FF";
         else
            r(q * 8 + 7 downto q * 8) := bytes(q * 8 + 7 downto q * 8);
         end if;
      end loop;
      return r;
   end function;
   -- The qwords whose eight bytes are all written.
   function q_full(bytes : std_logic_vector(31 downto 0)) return std_logic_vector is
      variable r : std_logic_vector(3 downto 0);
   begin
      for q in 0 to 3 loop
         if (bytes(q * 8 + 7 downto q * 8) = x"FF") then r(q) := '1'; else r(q) := '0'; end if;
      end loop;
      return r;
   end function;

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
      ALLOC,
      -- A miss on the read-ahead's line: wait for the copy, copy it in, finish.
      FILLRA_WAIT,
      FILLRA_COPY,
      FILLRA_DONE,
      -- LOAD_INTERLOCK: the RAMs read the load's own doubleword, for the
      -- READWAIT or WAYFIX (reread_wf) that follows.
      REREAD
   );
   signal state : tstate := IDLE;

   signal writeMode        : std_logic := '0';
   signal fillNext         : std_logic := '0';
   -- After the victim's write-back, ALLOC instead of FILL.
   signal allocNext        : std_logic := '0';
   -- The data RAMs' output is not the doubleword of the access now in IDLE
   -- (tag_addr_1's): last cycle a store addressed them, or - with
   -- LOAD_INTERLOCK - the cache was busy and they read tag_read_addr. A load
   -- then re-reads through READWAIT.
   signal ram_stale        : std_logic := '0';
   -- LOAD_INTERLOCK: the load's own RW_addr(2 downto 0), for read_data once
   -- the cache has left IDLE; and REREAD's successor, WAYFIX if set.
   signal rd_low           : unsigned(2 downto 0) := (others => '0');
   signal rd_sel           : unsigned(2 downto 0);
   signal reread_wf        : std_logic := '0';
   -- STORE_BUFFER: the parked store, and this cycle's decisions about it.
   signal sb_valid         : std_logic := '0';
   signal sb_addr          : unsigned(IDX_HI downto 3) := (others => '0');
   signal sb_way           : std_logic := '0';
   signal sb_data          : std_logic_vector(63 downto 0) := (others => '0');
   signal sb_be            : std_logic_vector(7 downto 0) := (others => '0');
   signal sb_ok            : std_logic;   -- a store may park: write-back, no debug mode
   signal sb_same          : std_logic;   -- the access in IDLE is to the buffered doubleword
   signal sb_park          : std_logic;   -- a store takes the (freed) entry
   signal sb_merge         : std_logic;   -- a store merges into it
   signal sb_drain_idle    : std_logic;
   signal sb_drain         : std_logic;   -- it is written to the RAMs at this edge
   signal st_direct_a      : std_logic;   -- a store in IDLE may write the RAMs itself
   -- synthesis translate_off
   signal ram_rd_1         : std_logic_vector(IDX_HI - 3 downto 0) := (others => '0');
   -- synthesis translate_on

   signal clearAddr        : std_logic_vector(7 downto 0) := (others => '0');

   signal isCommand        : std_logic := '0';
   signal isWB             : std_logic := '0';

   signal tag_wren_cmd     : std_logic := '0';
   signal tag_addr_cmd     : std_logic_vector(SET_BITS - 1 downto 0) := (others => '0');
   signal tag_data_cmd     : std_logic_vector(57 downto 0) := (others => '0');
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
   -- The read-ahead is armed only while load misses keep landing on the next
   -- line; see READING AHEAD.
   signal ra_arm         : std_logic := '0';

   -- Read ahead; see READING AHEAD. RA_FLIGHT: asked for, not back. RA_VALID:
   -- back and still what SDRAM holds.
   type tRA is (RA_NONE, RA_FLIGHT, RA_VALID);
   signal ra_state       : tRA := RA_NONE;
   signal ra_poison      : std_logic := '0';
   -- One cycle: a read-ahead copy of the line being written back was dropped
   -- when the victim was chosen (see the dirty-victim branch in IDLE). A
   -- testbench counts it with ra_poison_now, the drop it pre-empts.
   signal ra_vdrop       : std_logic := '0';
   signal ra_poison_now  : std_logic;
   -- The staged line, as address(31..5).
   signal ra_line        : unsigned(26 downto 0) := (others => '0');
   -- This access's line is the staged one.
   signal ra_match       : std_logic;
   -- The miss behind a write-back fills from the staged line.
   signal fillRA         : std_logic := '0';
   signal ra_qword       : std_logic_vector(63 downto 0);

begin

   debug_state <= std_logic_vector(to_unsigned(tState'pos(state), 5));
   clear_busy  <= '1' when (state = CLEARCACHE) else '0';
   fill_grant <= ram_grant and ram_active;

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
   -- Below 0x0008_0000: the board's SRAM. perf_miss_i is combinational on
   -- state = IDLE with read_ena/write_ena, so RW_addr holds this access's
   -- address in the same cycle.
   perf_miss_low <= perf_miss_i when (RW_addr(31 downto 19) = 0) else '0';
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
   writeback_bytes <= wb_bytes;

   ra_match <= '1' when (READ_AHEAD and ra_state /= RA_NONE and
                         RW_addr(31 downto 5) = ra_line) else '0';
   -- A store to the staged line in this very cycle: physical line bits, so a
   -- KSEG1 store and a KSEG0 write-back of the same memory both count.
   ra_poison_now <= '1' when (READ_AHEAD and ra_store = '1' and ra_state /= RA_NONE and
                              ra_store_addr(28 downto 5) = ra_line(23 downto 0)) else '0';
   ra_qword <= ra_data( 63 downto   0) when (tag_read_addr(4 downto 3) = "00") else
               ra_data(127 downto  64) when (tag_read_addr(4 downto 3) = "01") else
               ra_data(191 downto 128) when (tag_read_addr(4 downto 3) = "10") else
               ra_data(255 downto 192);
   perf_ra_used <= '1' when (state = FILLRA_WAIT and ra_state = RA_VALID and
                             ra_poison_now = '0' and
                             ra_line = ram_reqAddr(31 downto 5)) else '0';

   ce_fetch <= '1' when (stall = 0 and ce_93 = '1') else '0';

   ------------------ tags

   tag_address_a  <= tag_addr_cmd when (tag_wren_cmd = '1') else
                     std_logic_vector(tag_addr_1(IDX_HI downto 5));
   tag_address_b  <= std_logic_vector(tag_addr(IDX_HI downto 5));

   gtag : for w in 0 to 1 generate
   begin
      -- A command, fill or clear write goes to the ways it names; otherwise a
      -- store hit rewrites its own way's entry with the dirty bit set.
      -- A store hit also makes its qword present if it covers all of it, or
      -- if with the bytes partial stores already wrote it now covers all of it.
      tag_wren_w(w) <= '1' when (tag_wren_cmd = '1' and tag_way_cmd(w) = '1') else
                       '1' when (tag_wren_cmd = '0' and state = IDLE and
                                 write_ena = '1' and hit_w(w) = '1') else
                       '0';
      tag_wdata(w)  <= tag_data_cmd when (tag_wren_cmd = '1') else
                       (tag_w(w)(57 downto 26) or store_bytes) &
                       (tag_w(w)(25 downto 22) and (not store_clear) and
                        (not q_full(tag_w(w)(57 downto 26) or store_bytes))) &
                       (not write_through_in) & tag_w(w)(20 downto 0);

      itagram : entity mem.dpram
      generic map
      (
         addr_width  => SET_BITS,
         data_width  => 58 -- 32 byte bits + 4 absent bits + dirty + valid + 20 bits(31..12) of address
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
         data_b      => 58x"0",
         wren_b      => '0',
         q_b         => tag_q_b(w)
      );

      tag_w(w)      <= tag_newData(w) when (tag_newEna(w) = '1') else tag_q_b(w);
      line_hit_w(w) <= '1' when (unsigned(tag_w(w)(19 downto TAG_LO)) = RW_addr(31 downto IDX_HI + 1) and
                                 tag_w(w)(20) = '1') else '0';
      qabs_w(w)     <= '0' when (not SKIP_FILL) else
                       tag_w(w)(22 + to_integer(RW_addr(4 downto 3)));
      hit_w(w)      <= line_hit_w(w) and ((not qabs_w(w)) or store_ok);
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
   hit_bytes  <= (others => '0')          when (not FB_PARTIAL) else
                 tag_w(1)(57 downto 26)   when (line_hit_w(1) = '1') else
                 tag_w(0)(57 downto 26);
   hit_bytes_st  <= hit_bytes or store_bytes;
   hit_absent_st <= hit_absent and (not store_clear) and (not q_full(hit_bytes_st));

   -- Every byte of the qword: only a 64-bit store's enables are all set, and
   -- rotating a 32-bit store's halves cannot make them so.
   store_full  <= '1' when (SKIP_FILL and write_ena = '1' and write_be = x"FF") else '0';
   store_clear <= "0000" when (store_full = '0') else
                  "0001" when (RW_addr(4 downto 3) = "00") else
                  "0010" when (RW_addr(4 downto 3) = "01") else
                  "0100" when (RW_addr(4 downto 3) = "10") else
                  "1000";
   -- PARTIAL FRAMEBUFFER STORES (FB_PARTIAL). KI2 draws its background with
   -- unaligned sdl/sdr, so most of the doubleword stores into its framebuffer
   -- are partial, and most of its framebuffer line allocations would fill
   -- lines the routine then overwrites end to end. So a partial store to a
   -- framebuffer line is treated as a full one is: a miss allocates without
   -- a fill, and a hit on an absent qword is a hit. What makes that safe is the byte field
   -- beside the tag: a load of an absent qword fills it around the bytes
   -- stored (fill_keep), a write-back sends only them (writeback_bytes into
   -- the framebuffer RAM's byte enables), and a qword whose eight bytes are
   -- all stored becomes present. Only framebuffer lines, because their
   -- write-back can mask bytes: SDRAM here ignores DQM, which is why SKIP_FILL
   -- itself stays qword-granular.
   store_part  <= '1' when (FB_PARTIAL and SKIP_FILL and write_ena = '1' and RW_fb = '1' and
                            write_through_in = '0' and write_be /= x"FF") else '0';
   store_ok    <= store_full or store_part;
   gstb : for q in 0 to 3 generate
      store_bytes(q * 8 + 7 downto q * 8) <= write_be_rot when (store_part = '1' and
                                                                to_integer(RW_addr(4 downto 3)) = q)
                                             else x"00";
   end generate;
   -- A write-through store allocates nothing, and a forced write-back sends
   -- the whole line straight after its fill, so neither skips it.
   skip_ok     <= '1' when (store_ok = '1' and write_through_in = '0' and force_wb = '0') else '0';
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
   sel_way    <= RW_addr(IDX_HI + 1) when (index_op = '1') else
                 hit_way     when (line_hit = '1') else
                 victim_way;

   -- The victim's (or an index op's) tag, for write-back addresses and index
   -- ops. Deliberately NOT chosen by the hit compare: a hit line's tag is the
   -- access's own address, which the hit branches below use directly, and
   -- keeping the compare out of this 22-bit mux keeps it off these paths.
   tag_compare <= tag_w(1) when ((index_op = '1' and RW_addr(IDX_HI + 1) = '1') or
                                 (index_op = '0' and victim_way = '1')) else
                  tag_w(0);

   -- Every allocating data access makes its way the most recently used: the
   -- way that hit, or the victim about to be filled. Combinational, for the
   -- reason in the note at the top.
   mru_wren     <= '1' when (state = IDLE and (read_ena = '1' or write_ena = '1') and
                             not (write_ena = '1' and read_hit = '0' and
                                  write_through_in = '1')) else '0';
   mru_waddr    <= std_logic_vector(tag_addr_1(IDX_HI downto 5));
   mru_wdata(0) <= sel_way;

   -- One M10K on one clock, read before it is written in the same process:
   -- OLD_DATA. A read of the set being written on that edge returns the bit
   -- as it was. A two-clock dpram would leave that read DONT_CARE - X in
   -- simulation, unspecified on the board - and LOAD_MERGE_BYPASS does
   -- exactly that read on every pair it bypasses: the ldr straight behind
   -- its ldl, the same line. Old data predicts that line's
   -- way whenever it was already the most recent in its set, the usual case.
   gmru : block
      type t_mru is array (0 to 2**SET_BITS - 1) of std_logic_vector(0 downto 0);
      signal mru_mem : t_mru := (others => "0");
      attribute ramstyle : string;
      attribute ramstyle of mru_mem : signal is "M10K";
   begin
      process (clk93)
      begin
         if rising_edge(clk93) then
            if (ce_fetch = '1') then
               mru_q <= mru_mem(to_integer(unsigned(tag_address_b)));
            end if;
            if (mru_wren = '1') then
               mru_mem(to_integer(unsigned(mru_waddr))) <= mru_wdata;
            end if;
         end if;
      end process;
   end block;

   -- '1' only when it really reads '1': a prediction is only a hint.
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
            fill_bytes_2x  <= (others => '0');
         elsif (fill_grant = '1') then
            fill_active_2x <= '1';
            fill_line_2x   <= fill_line_saved;
            fill_way_2x    <= data_way;
            fill_mask_2x   <= fill_mask;
            fill_bytes_2x  <= fill_bytes;
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
   -- And within a qword it writes, not the bytes a partial store left there.
   fill_bytes_now   <= fill_bytes when (fill_grant = '1') else fill_bytes_2x;
   gkeep : for i in 0 to 7 generate
      fill_keep(i) <= fill_bytes_now(to_integer(fill_beat_now) * 8 + i);
   end generate;

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
            addr_width  => SET_BITS + 2,
            data_width  => 8
         )
         port map
         (
            clock_a     => clk1x,
            address_a   => cache_ram_addr_a,
            data_a      => ddr3_DOUT(((i * 8) + 7) downto (i*8)),
            wren_a      => cache_wr_a_w(w) and (not fill_keep(i)),

            clock_b     => clk93,
            address_b   => cache_address_b,
            data_b      => cache_data_b(((i * 8) + 7) downto (i*8)),
            wren_b      => cache_we_w(w) and cache_be_b(i),
            q_b         => cache_q_w(w)(((i * 8) + 7) downto (i*8))
         );
      end generate;
   end generate;

   -- STORE_BUFFER. sb_same is registers against registers; st_direct_a is the
   -- address side of "this store may write the RAMs itself", deliberately
   -- without the tag compare (sb_park/sb_merge have it, for the enables).
   sb_ok       <= '1' when (STORE_BUFFER and write_through_in = '0' and force_wb = '0' and
                            slow_on = '0') else '0';
   sb_same     <= '1' when (STORE_BUFFER and sb_valid = '1' and
                            sb_addr = tag_addr_1(IDX_HI downto 3)) else '0';
   st_direct_a <= '1' when (not STORE_BUFFER or sb_ok = '0' or sb_same = '1') else '0';
   sb_park     <= '1' when (state = IDLE and write_ena = '1' and read_hit = '1' and sb_ok = '1' and
                            (sb_valid = '0' or sb_same = '0')) else '0';
   sb_merge    <= '1' when (state = IDLE and write_ena = '1' and read_hit = '1' and sb_ok = '1' and
                            sb_same = '1' and hit_way = sb_way) else '0';
   sb_drain_idle <= '1' when (STORE_BUFFER and state = IDLE and sb_valid = '1' and
                              ((read_ena = '0' and write_ena = '0' and CacheCommandEna = '0' and
                                ce_fetch = '1' and next_load = '0') or
                               (write_ena = '1' and sb_ok = '1' and sb_same = '0') or
                               (read_ena = '1' and sb_same = '1') or
                               CacheCommandEna = '1')) else '0';
   sb_drain    <= '1' when (sb_drain_idle = '1' or
                            (STORE_BUFFER and sb_valid = '1' and
                             ((state = FILL and ram_request = '1') or
                              state = WRITEBACK1ADDR or state = FILLRA_WAIT))) else '0';

   cache_address_b <= std_logic_vector(sb_addr) when (sb_drain = '1') else
                      std_logic_vector(tag_read_addr(IDX_HI downto 3)) when (state /= IDLE) else
                      std_logic_vector(tag_addr_1(IDX_HI downto 3)) when (ce_fetch = '0' or
                                                                          (write_ena = '1' and st_direct_a = '1')) else
                      std_logic_vector(tag_addr(IDX_HI downto 3));

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

   -- FILLRA_COPY writes the staged line's qwords as the bridge would have
   -- delivered them, every byte.
   cache_data_b    <= ra_qword     when (state = FILLRA_COPY) else
                      sb_data      when (sb_drain = '1') else
                      write_data_1 when (stall4 = '1') else write_data_rot;
   cache_be_b      <= x"FF"        when (state = FILLRA_COPY) else
                      sb_be        when (sb_drain = '1') else
                      write_be_1   when (stall4 = '1') else write_be_rot;

   -- A store writes the way that hit; the store that caused a fill writes the
   -- filled way once the line is in, and a store that skipped it in ALLOC.
   cache_we_w(0)   <= '1' when ((state = IDLE and hit_w(0) = '1' and write_ena = '1' and
                                 sb_park = '0' and sb_merge = '0') or
                                (sb_drain = '1' and sb_way = '0') or
                                (writeMode = '1' and state = FILL and ram_done = '1' and
                                 data_way = '0') or
                                (state = ALLOC and data_way = '0') or
                                (state = FILLRA_COPY and data_way = '0') or
                                (writeMode = '1' and state = FILLRA_DONE and
                                 data_way = '0')) else '0';
   cache_we_w(1)   <= '1' when ((state = IDLE and hit_w(1) = '1' and write_ena = '1' and
                                 sb_park = '0' and sb_merge = '0') or
                                (sb_drain = '1' and sb_way = '1') or
                                (writeMode = '1' and state = FILL and ram_done = '1' and
                                 data_way = '1') or
                                (state = ALLOC and data_way = '1') or
                                (state = FILLRA_COPY and data_way = '1') or
                                (writeMode = '1' and state = FILLRA_DONE and
                                 data_way = '1')) else '0';

   write_done      <= '1'     when (write_through_in = '1' and
                                    state = IDLE and write_ena = '1' and
                                    fifo_block = '0') else
                       wb_done when (force_wb = '1') else
                       '1'     when ((state = IDLE and read_hit = '1' and write_ena = '1') or (writeMode = '1' and state = FILL and ram_done = '1')) else
                       '1'     when (state = ALLOC) else
                       '1'     when (writeMode = '1' and state = FILLRA_DONE) else
                       '0';

   read_busy       <= '1' when (state = READWAIT or state = WAITSLOW or state = FILL or
                                state = WAYFIX or state = FILLRA_WAIT or state = REREAD or
                                state = FILLRA_COPY or state = FILLRA_DONE) else '0';

   read_done       <= '1' when (state = IDLE and ram_stale = '0' and fast_hit = '1' and read_ena = '1' and
                                slow_on = '0' and sb_same = '0') else
                      '1' when (state = READWAIT) else
                      '1' when (state = WAYFIX) else
                      '1' when (state = WAITSLOW and slowcnt = 0) else
                      '1' when (writeMode = '0' and state = FILL and ram_done = '1') else
                      '0';

   -- A load answered outside IDLE may have the next instruction's RW_addr by
   -- then (LOAD_INTERLOCK); rd_low is its own.
   rd_sel          <= RW_addr(2 downto 0) when (not LOAD_INTERLOCK or state = IDLE) else rd_low;

   read_data       <= cache_q_b                        when (rd_sel = "000") else
                      8x"0"  & cache_q_b(63 downto  8) when (rd_sel = "001") else
                      16x"0" & cache_q_b(63 downto 16) when (rd_sel = "010") else
                      24x"0" & cache_q_b(63 downto 24) when (rd_sel = "011") else
                      32x"0" & cache_q_b(63 downto 32) when (rd_sel = "100") else
                      40x"0" & cache_q_b(63 downto 40) when (rd_sel = "101") else
                      48x"0" & cache_q_b(63 downto 48) when (rd_sel = "110") else
                      56x"0" & cache_q_b(63 downto 56); -- when (rd_sel = "111")

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
         ra_request        <= '0';
         perf_ra_issue     <= '0';
         ra_vdrop          <= '0';
         stride_hit_i      <= '0';
         delta_hit_i       <= '0';
         -- perf_miss is one cycle per allocating miss; sample the line address
         -- on it and compare against the previous one, and the delta against
         -- the previous delta.
         --
         -- LOAD misses only. A read-ahead can only save a load, and KI's heavy
         -- frames are 64-bit store streams whose consecutive store misses
         -- already skip their fill: counting those would make SH read high for
         -- exactly the traffic a read-ahead cannot help.
         if (perf_miss_i = '1' and read_ena = '1' and write_ena = '0') then
            last_miss_line <= RW_addr(31 downto 5);
            last_miss_seen <= '1';
            -- Disarm on a miss that is not the next line, arm on one that is.
            ra_arm         <= '0';
            if (last_miss_seen = '1') then
               last_delta    <= RW_addr(31 downto 5) - last_miss_line;
               last_delta_ok <= '1';
               if (RW_addr(31 downto 5) = last_miss_line + 1) then
                  stride_hit_i <= '1';
                  ra_arm       <= '1';
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
         -- With LOAD_INTERLOCK a load whose IDLE cycle has ce_fetch high goes
         -- through REREAD instead, which the next check covers.
         if (state = IDLE and SS_reset = '0' and read_ena = '1' and read_hit = '1' and
             slow_on = '0' and (ram_stale = '1' or fast_hit = '0') and
             not (LOAD_INTERLOCK and ce_fetch = '1') and
             cache_address_b /= std_logic_vector(tag_addr_1(IDX_HI downto 3))) then
            report "cpu_datacache: a load left IDLE for READWAIT/WAYFIX but the data RAMs are re-reading another address"
               severity failure;
         end if;
         -- Every load answered from the data RAMs gets the doubleword they
         -- read on the previous edge: its own. In IDLE that is tag_addr_1's,
         -- elsewhere tag_read_addr's.
         ram_rd_1 <= cache_address_b;
         if (SS_reset = '0' and read_done = '1' and state = IDLE and
             ram_rd_1 /= std_logic_vector(tag_addr_1(IDX_HI downto 3))) then
            report "cpu_datacache: a load hit in IDLE on a data RAM read of another doubleword"
               severity failure;
         end if;
         if (SS_reset = '0' and read_done = '1' and
             (state = READWAIT or state = WAYFIX or state = WAITSLOW) and
             ram_rd_1 /= std_logic_vector(tag_read_addr(IDX_HI downto 3))) then
            report "cpu_datacache: a load answered from a data RAM read of another doubleword"
               severity failure;
         end if;
         -- A load asks for the next read-ahead as its copy begins, so the
         -- staged copy (ra_data) must not change under the four COPY cycles
         -- that read it: no read-ahead lands during FILLRA_COPY.
         if (SS_reset = '0' and READ_AHEAD and state = FILLRA_COPY and ra_done = '1') then
            report "cpu_datacache: a read-ahead landed while the previous one was being copied in"
               severity failure;
         end if;
         -- STORE_BUFFER: a load never answers in IDLE from RAMs that lack the
         -- buffered store; nothing reads, copies over or fills a line while a
         -- store to it waits; a drain never shares the port with a store's
         -- own write.
         if (SS_reset = '0' and state = IDLE and read_done = '1' and sb_same = '1') then
            report "cpu_datacache: a load hit in IDLE on the buffered doubleword" severity failure;
         end if;
         if (SS_reset = '0' and sb_valid = '1' and
             (state = WRITEBACK1READ or state = FILLRA_COPY or
              (state = FILL and ram_done = '1') or (state = FILLRA_DONE and writeMode = '1'))) then
            report "cpu_datacache: a line read or written while a store waits in the buffer" severity failure;
         end if;
         if (SS_reset = '0' and state = ALLOC and sb_valid = '1' and sb_way = data_way and
             sb_addr(IDX_HI downto 5) = tag_read_addr(IDX_HI downto 5)) then
            report "cpu_datacache: ALLOC over the line the buffered store belongs to" severity failure;
         end if;
         if (SS_reset = '0' and sb_drain = '1' and state = IDLE and write_ena = '1' and
             read_hit = '1' and sb_park = '0' and sb_merge = '0') then
            report "cpu_datacache: a drain and a store's own write in one cycle" severity failure;
         end if;
         -- ALLOC's tag and store land in the same cycle; see the state.
         if (state = ALLOC and tag_wren_cmd /= '1') then
            report "cpu_datacache: ALLOC without its tag write" severity failure;
         end if;
         -- Only a 64-bit store - or, with FB_PARTIAL, a partial framebuffer
         -- store - may skip its fill, and only a line with an
         -- absent qword may be filled around its present ones.
         if (state = ALLOC and (writeMode /= '1' or (write_be_1 /= x"FF" and alloc_part_1 = '0'))) then
            report "cpu_datacache: ALLOC for an access that is neither a 64-bit store nor a partial framebuffer store" severity failure;
         end if;
         if (state = FILL and ram_request = '1' and fill_mask = "0000") then
            report "cpu_datacache: a fill with no qword to write" severity failure;
         end if;
         -- The copy is a whole line into a victim: never around present qwords.
         if (state = FILLRA_COPY and fill_mask /= "1111") then
            report "cpu_datacache: a read-ahead copy into a line with present qwords" severity failure;
         end if;
         -- Only one read-ahead is ever outstanding.
         if (ra_request = '1' and ra_state /= RA_FLIGHT) then
            report "cpu_datacache: a read-ahead asked for without being in flight" severity failure;
         end if;
         -- A read-ahead completion is only ever the one in flight.
         if (READ_AHEAD and ra_done = '1' and ra_state /= RA_FLIGHT) then
            report "cpu_datacache: a read-ahead completed that was not in flight" severity failure;
         end if;
         -- synthesis translate_on

         if (ce_fetch = '1') then
            tag_addr_1   <= tag_addr;
            tag_newEna   <= "00";
            for w in 0 to 1 loop
               if (tag_wren_w(w) = '1') then
                  tag_newData(w) <= tag_wdata(w);
                  if (tag_address_a = std_logic_vector(tag_addr(IDX_HI downto 5))) then
                     tag_newEna(w) <= '1';
                  end if;
               end if;
            end loop;
         else
            for w in 0 to 1 loop
               if (tag_wren_w(w) = '1') then
                  tag_newData(w) <= tag_wdata(w);
                  if (tag_address_a = std_logic_vector(tag_addr_1(IDX_HI downto 5))) then
                     tag_newEna(w) <= '1';
                  end if;
               end if;
            end loop;
         end if;

         force_wb <= force_wb_in;

         -- STORE_BUFFER: written at this edge, freed; a store that hits takes it
         -- or merges into it. Applies in every state (drains happen outside IDLE).
         if (sb_drain = '1') then
            sb_valid <= '0';
         end if;
         if (sb_park = '1') then
            sb_valid <= '1';
            sb_addr  <= tag_addr_1(IDX_HI downto 3);
            sb_way   <= hit_way;
            sb_data  <= write_data_rot;
            sb_be    <= write_be_rot;
         elsif (sb_merge = '1') then
            for b in 0 to 7 loop
               if (write_be_rot(b) = '1') then
                  sb_data(b * 8 + 7 downto b * 8) <= write_data_rot(b * 8 + 7 downto b * 8);
               end if;
            end loop;
            sb_be <= sb_be or write_be_rot;
         end if;
         if (SS_reset = '1') then
            sb_valid <= '0';
         end if;

         -- LOAD_INTERLOCK: a busy cycle's RAM read was tag_read_addr; the
         -- access that enters when it ends must re-read. See ram_stale.
         if ((LOAD_INTERLOCK or STORE_BUFFER) and state /= IDLE) then
            ram_stale <= '1';
         end if;

         -- Read-ahead bookkeeping. A store to the staged line makes the copy
         -- stale: in flight it is poisoned and dropped when it lands, landed
         -- it is dropped now.
         if (READ_AHEAD) then
            if (ra_state = RA_FLIGHT and ra_done = '1') then
               if (ra_poison = '1' or ra_poison_now = '1') then
                  ra_state <= RA_NONE;
               else
                  ra_state <= RA_VALID;
               end if;
            elsif (ra_poison_now = '1') then
               if (ra_state = RA_FLIGHT) then
                  ra_poison <= '1';
               else
                  ra_state <= RA_NONE;
               end if;
            end if;
         end if;

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
                  -- The port did not read the next access's doubleword: a
                  -- store wrote through it, or the buffer drained. A store
                  -- that parks leaves it reading on.
                  ram_stale      <= sb_drain_idle or (write_ena and st_direct_a);
                  rd_low         <= RW_addr(2 downto 0);
                  fillAddr       <= unsigned(tag_compare(19 downto TAG_LO)) & RW_addr(IDX_HI downto 5) & "00000";
                  fill_line_saved <= tag_addr_1(IDX_HI downto 5);
                  tag_addr_low   <= tag_addr_1(4 downto 0);
                  tag_read_addr  <= tag_addr_1(13 downto 0);
                  isCommand      <= '0';
                  isWB           <= '0';
                  allocNext      <= '0';
                  fillRA         <= '0';
                  ram_reqAddr    <= RW_addr(31 downto 0);
                  tag_data_cmd   <= x"00000000" & "0000" & (write_ena and (not write_through_in)) &
                                    '1' & std_logic_vector(RW_addr(31 downto 12)); -- default for fill
                  tag_addr_cmd   <= std_logic_vector(tag_addr_1(IDX_HI downto 5));
                  writeback_addr <= unsigned(tag_compare(19 downto TAG_LO)) & RW_addr(IDX_HI downto 5) & "00000";
                  -- The victim's (or an index op's) present qwords; the hit
                  -- write-backs below name their own line's.
                  wb_mask        <= wb_q(tag_compare(25 downto 22), tag_compare(57 downto 26));
                  wb_bytes       <= wb_b(tag_compare(25 downto 22), tag_compare(57 downto 26));
                  fill_mask      <= "1111";
                  fill_bytes     <= (others => '0');
                  alloc_part_1   <= store_part;
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
                     fill_bytes     <= hit_bytes;
                     tag_data_cmd(21) <= hit_dirty or (write_ena and (not write_through_in));
                     if (write_ena = '1' and force_wb = '1') then
                        isWB <= '1';
                     end if;

                  elsif ((read_ena = '1' or write_ena = '1') and read_hit = '0') then
                     if (skip_ok = '1') then
                        -- Only the store's own qword will be in the line.
                        tag_data_cmd(25 downto 22) <= not store_clear;
                        tag_data_cmd(57 downto 26) <= store_bytes;
                     end if;
                     -- A 64-bit store to the staged line skips its fill: the
                     -- line it leaves is newer than the copy, so drop the copy
                     -- - now if it has landed, when it lands if it is still in
                     -- flight. Dropping an in-flight one outright would let
                     -- the next read-ahead be asked for while this one's line
                     -- is still coming, and take it as its own.
                     if (skip_ok = '1' and ra_match = '1') then
                        if (ra_state = RA_FLIGHT and ra_done = '0') then
                           ra_poison <= '1';
                        else
                           ra_state <= RA_NONE;
                        end if;
                     end if;
                     -- tag_compare is the victim here, so this is its dirty bit.
                     if (tag_compare(21) = '1') then
                        state          <= WRITEBACK1ADDR;
                        tag_read_addr(4 downto 0) <= "00000";
                        fillNext       <= '1';
                        allocNext      <= skip_ok;
                        fillRA         <= ra_match and (not skip_ok) and (not force_wb);
                        -- Drop a read-ahead copy of the VICTIM now. A store to a
                        -- staged line normally drops it when the store reaches
                        -- the write FIFO (ra_store), and for a write-back that
                        -- is when cpu.vhd issues the staged line - which with
                        -- WB_EARLY can be after this cache has left for an
                        -- ALLOC and taken another miss. A load missing on the
                        -- victim then would be served, through FILLRA, the line
                        -- as it was before the bytes being written back. The
                        -- ordinary FILL is safe - it is held behind the
                        -- write-back.
                        if (READ_AHEAD and ra_state /= RA_NONE and
                            ra_line = unsigned(tag_compare(19 downto TAG_LO)) & RW_addr(IDX_HI downto 5)) then
                           ra_poison <= '1';
                           ra_vdrop  <= '1';
                           if (ra_state /= RA_FLIGHT or ra_done = '1') then
                              ra_state <= RA_NONE;
                           end if;
                        end if;
                     elsif (skip_ok = '1') then
                        state          <= ALLOC;
                        tag_wren_cmd   <= '1';
                     elsif (ra_match = '1' and force_wb = '0') then
                        -- The staged line: copy it in rather than ask the bridge.
                        state          <= FILLRA_WAIT;
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
                     wb_mask        <= wb_q(hit_absent_st, hit_bytes_st);
                     wb_bytes       <= wb_b(hit_absent_st, hit_bytes_st);

                  elsif (read_ena = '1' and slow_on = '1') then
                     state       <= WAITSLOW;
                     slowcnt     <= slow - 1;
                     -- One more cycle, to read the load's own doubleword.
                     if ((LOAD_INTERLOCK and ce_fetch = '1') or sb_same = '1') then
                        slowcnt  <= slow;
                     end if;

                  elsif (read_ena = '1' and read_hit = '1' and sb_same = '1') then
                     -- The buffered doubleword: the buffer drains at this edge
                     -- and the load reads it back.
                     state     <= REREAD;
                     reread_wf <= '0';

                  elsif (ram_stale = '1' and read_ena = '1' and read_hit = '1') then
                     state <= READWAIT;
                     if (LOAD_INTERLOCK and ce_fetch = '1') then
                        state     <= REREAD;
                        reread_wf <= '0';
                     end if;

                  elsif (read_ena = '1' and read_hit = '1' and fast_hit = '0') then
                     -- A hit, but in the way the prediction did not pick.
                     state <= WAYFIX;
                     if (LOAD_INTERLOCK and ce_fetch = '1') then
                        state     <= REREAD;
                        reread_wf <= '1';
                     end if;

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
                           tag_data_cmd    <= x"00000000" & "000000" & tag_compare(19 downto 0);

                        when 5x"05" => -- dcache index load tag
                           writeTagEna <= '1';

                        when 5x"09" => -- dcache index store tag
                           tag_wren_cmd    <= '1';
                           tag_data_cmd    <= tag_compare(57 downto 22) & TagLo_Dirty & TagLo_Valid &
                                              std_logic_vector(TagLo_Addr);

                        when 5x"0D" => -- dcache create dirty exclusive
                           -- A line that hits is just re-tagged dirty; on a miss
                           -- the victim is taken and written back if dirty.
                           if (line_hit = '0' and tag_compare(21) = '1') then
                              state          <= WRITEBACK1ADDR;
                           end if;
                           tag_wren_cmd    <= '1';
                           if (line_hit = '1') then
                              tag_data_cmd <= hit_bytes & hit_absent & "11" & std_logic_vector(RW_addr(31 downto 12));
                           else
                              tag_data_cmd <= x"00000000" & "0000" & "11" & std_logic_vector(RW_addr(31 downto 12));
                           end if;

                        when 5x"11" => -- dcache hit invalidate
                           if (line_hit = '1') then
                              tag_wren_cmd    <= '1';
                              tag_data_cmd    <= x"00000000" & "000000" & std_logic_vector(RW_addr(31 downto 12));
                           end if;

                        when 5x"15" => -- dcache hit write back invalidate
                           if (line_hit = '1') then
                              if (hit_dirty = '1') then
                                 state          <= WRITEBACK1ADDR;
                                 writeback_addr <= RW_addr(31 downto 5) & "00000";
                                 wb_mask        <= wb_q(hit_absent, hit_bytes);
                              wb_bytes       <= wb_b(hit_absent, hit_bytes);
                              end if;
                              tag_wren_cmd    <= '1';
                              tag_data_cmd    <= x"00000000" & "000000" & std_logic_vector(RW_addr(31 downto 12));
                           end if;

                        when 5x"19" => -- dcache hit write back
                           if (line_hit = '1' and hit_dirty = '1') then -- should this really check for dirty?
                              state          <= WRITEBACK1ADDR;
                              writeback_addr <= RW_addr(31 downto 5) & "00000";
                              wb_mask        <= wb_q(hit_absent, hit_bytes);
                              wb_bytes       <= wb_b(hit_absent, hit_bytes);
                              tag_wren_cmd   <= '1';
                              tag_data_cmd   <= hit_bytes & hit_absent & "01" & std_logic_vector(RW_addr(31 downto 12));
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
                  -- test sets this on the other cache's beats.
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
                     -- A load's whole line is in: read the next one ahead.
                     if (READ_AHEAD and writeMode = '0' and fill_mask = "1111" and
                         isWB = '0' and write_through_in = '0' and
                         ra_state /= RA_FLIGHT and ra_arm = '1' and
                         ram_reqAddr(11 downto 5) /= "1111111") then
                        ra_state      <= RA_FLIGHT;
                        ra_poison     <= '0';
                        ra_line       <= ram_reqAddr(31 downto 5) + 1;
                        ra_reqAddr    <= (ram_reqAddr(31 downto 5) + 1) & "00000";
                        ra_request    <= '1';
                        perf_ra_issue <= '1';
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
                  -- are lost.
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
                  -- The four words are staged, the last this cycle, and cpu.vhd
                  -- holds the line's mask with them: an ALLOC, which asks
                  -- nothing of memory, need not wait for the line to cross.
                  -- Anything that does - a FILL, a read-ahead copy - still
                  -- waits, and a later miss's write-back waits for the queue
                  -- in WRITEBACK1ADDR.
                  if (fifo_block = '0' or
                      (WB_EARLY and fillNext = '1' and allocNext = '1')) then
                     fillNext <= '0';
                     if (fillNext = '1' and allocNext = '1') then
                        -- The victim is out; take the line without its fill.
                        state        <= ALLOC;
                        tag_wren_cmd <= '1';
                     elsif (fillNext = '1' and fillRA = '1') then
                        state        <= FILLRA_WAIT;
                     elsif (fillNext = '1') then
                        state       <= FILL;
                        ram_request <= '1';
                        -- The IDLE -> FILL path clears this, and so must
                        -- this one: left set from the previous fill, the
                        -- wait for the first beat of a fill that follows a
                        -- writeback is filed as F3 and F1 reads 0.
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

               -- The data RAMs read tag_read_addr, the load's own doubleword,
               -- as in every state but IDLE; its READWAIT or WAYFIX delivers it.
               when REREAD =>
                  if (reread_wf = '1') then
                     state <= WAYFIX;
                  else
                     state <= READWAIT;
                  end if;

               -- One cycle, entered with tag_wren_cmd set: the line's tag -
               -- only the store's qword present - is written in this cycle,
               -- the store's data with it (cache_we_w), and write_done
               -- releases stage 4. The next access sees the tag through
               -- tag_newData exactly as it would after a FILL.
               when ALLOC =>
                  state <= IDLE;

               -- The miss's victim is free. Take the staged line if it is
               -- back and still good; if it was dropped - a store to it - or
               -- replaced, fill the ordinary way.
               when FILLRA_WAIT =>
                  if (ra_state = RA_VALID and ra_poison_now = '0' and
                      ra_line = ram_reqAddr(31 downto 5)) then
                     state          <= FILLRA_COPY;
                     ra_state       <= RA_NONE;
                     tag_wren_cmd   <= '1';
                     tag_read_addr(4 downto 0) <= "00000";
                     -- A load asks for the line after now, as the copy
                     -- starts, not five cycles later when it ends: a stream
                     -- is held to the bridge's one line a round trip, and
                     -- asking at the end would spend these cycles outside
                     -- it. The staged copy the four COPY cycles read changes
                     -- only when the new read-ahead lands, a round trip away
                     -- (asserted).
                     if (writeMode = '0' and write_through_in = '0' and ra_arm = '1' and
                         ram_reqAddr(11 downto 5) /= "1111111") then
                        ra_state      <= RA_FLIGHT;
                        ra_poison     <= '0';
                        ra_line       <= ram_reqAddr(31 downto 5) + 1;
                        ra_reqAddr    <= (ram_reqAddr(31 downto 5) + 1) & "00000";
                        ra_request    <= '1';
                        perf_ra_issue <= '1';
                     end if;
                  elsif (ra_state = RA_NONE or ra_line /= ram_reqAddr(31 downto 5)) then
                     state          <= FILL;
                     ram_request    <= '1';
                     fill_beat_seen <= '0';
                  end if;

               -- A qword a cycle into the victim's way, qword 0 first. The
               -- tag goes in with the first, as a fill's does.
               when FILLRA_COPY =>
                  if (tag_read_addr(4 downto 3) = "11") then
                     state                     <= FILLRA_DONE;
                     tag_read_addr(4 downto 0) <= tag_addr_low;
                  else
                     tag_read_addr(4 downto 3) <= tag_read_addr(4 downto 3) + 1;
                  end if;

               -- A store lands its own data now; a load reads its qword back
               -- through READWAIT, whose RAM read this cycle presents. (A
               -- load asked for the line after as the copy began.)
               when FILLRA_DONE =>
                  if (writeMode = '1') then
                     state <= IDLE;
                  else
                     state <= READWAIT;
                  end if;

            end case;

         end if;

      end if;
   end process;

end architecture;
