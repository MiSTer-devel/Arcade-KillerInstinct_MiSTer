library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;   
use STD.textio.all;

library mem;
use work.pFunctions.all;

entity cpu_datacache is
   generic
   (
      LITTLE_ENDIAN : boolean := false
   );
   port 
   (
      clk1x             : in  std_logic;
      clk2x             : in  std_logic;
      -- One reset per domain; see the note in cpu_instrcache.vhd.
      reset_1x          : in  std_logic;
      reset_2x          : in  std_logic;
      stall             : in  unsigned(4 downto 0);
      stall4            : in  std_logic;
      fifo_block        : in  std_logic;
      
      write_through_in  : in  std_logic := '0';
      
      ram_request       : out std_logic := '0';
      ram_reqAddr       : out unsigned(31 downto 0) := (others => '0');
      ram_active        : in  std_logic := '0';
      ram_grant         : in  std_logic := '0';
      ram_done          : in  std_logic := '0';
      -- This fill's own access is to the line's last qword, the beat that
      -- arrives last: cpu.vhd holds its ram_done a cycle (datacache_fill_due).
      fill_last_q       : out std_logic;
      -- The staged write-back is a framebuffer miss's victim, and that
      -- miss's fill has not been answered (see FILLING FIRST). cpu.vhd
      -- issues the staged line only when this is low.
      wb_hold           : out std_logic := '0';
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
      -- framebuffer store wrote. Held with writeback_mask.
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
      -- per miss.
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
      -- The fill interval, split exhaustively rather than sampled by proxy:
      -- a partition of the FILL state itself, with a sum check.
      --
      --   perf_fill_wait  in FILL, no data beat has arrived yet
      --   perf_fill_data  in FILL, beats arriving, line not yet complete
      --   perf_fill_hold  in FILL, every beat in, waiting for ram_done
      --
      -- Mutually exclusive and together the whole of FILL, so none of them can
      -- quietly read zero while the time goes somewhere else. All three are
      -- clk2x levels, so they count in CPU cycles directly.
      --
      -- The third exists because ram_done is NOT the last beat: it is
      -- mem_finished_read in cpu.vhd, which comes off response_cdc_deliver_2x
      -- at the end of a clk1x-to-clk2x mailbox round trip, so the tail after
      -- the data is a cost of its own.
      --
      -- "Every beat in" is the design's own fill_active_1x, not a separate
      -- beat count: ddr3_DOUT_READY is a per-beat pulse from the bridge but
      -- can be a held level in a testbench, so counting its edges works on
      -- hardware and silently sees one beat in simulation. fill_active_1x
      -- is set on the grant and cleared after the fourth beat either way. It
      -- is a clk1x level read from clk2x; it changes once per fill, so the
      -- worst case is attributing a cycle to the neighbouring phase.
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
      --                     without a fill
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
      -- Read ahead. ra_request asks the scheduler, at its lowest priority,
      -- for the four qwords of the line at ra_reqAddr; they arrive in
      -- ra_data, stable from ra_done until the next read-ahead's data comes:
      -- its completion, or the first qword of one that comes back a qword at
      -- a time (ra_wr).
      -- ra_store is every store entering the write FIFO - write-backs and
      -- uncached stores alike - with its address: one landing in the line
      -- being read ahead makes the copy stale.
      --   perf_ra_issue  one pulse per read-ahead issued
      --   perf_ra_used   one pulse per miss that filled from the staged line
      ra_request        : out std_logic := '0';
      ra_reqAddr        : out unsigned(31 downto 0) := (others => '0');
      -- The read-ahead is a stream's: the copy that asked for it had waited
      -- for its own line (FILLRA_WAIT longer than its one cycle). Changes
      -- with ra_reqAddr.
      ra_reqStream      : out std_logic := '0';
      ra_done           : in  std_logic := '0';
      ra_data           : in  std_logic_vector(255 downto 0) := (others => '0');
      ra_store          : in  std_logic := '0';
      ra_store_addr     : in  unsigned(31 downto 0) := (others => '0');
      -- ra_data took a qword on the last edge: a line that comes back a
      -- qword at a time (cpu.vhd's direct read-ahead), its fourth beside
      -- ra_done.
      ra_wr             : in  std_logic := '0';
      -- The chained read-ahead. ra_chain_ok: the arm - the cache waits in
      -- FILLRA_WAIT for its own line's read-ahead, and the copy would ask
      -- for the line after,
      -- ra_chain_addr, which ra_chain_sdram (cpu.vhd) says the direct port
      -- can read. ra_chain_taken: cpu.vhd launched that line on the last
      -- edge.
      ra_chain_ok       : out std_logic := '0';
      ra_chain_addr     : out unsigned(31 downto 0) := (others => '0');
      ra_chain_sdram    : in  std_logic := '0';
      ra_chain_taken    : in  std_logic := '0';
      -- A fill request raised while the line before it is still landing may
      -- leave now (cpu.vhd, fast_go_q); see EARLY RESTART.
      tail_q_ok         : in  std_logic := '0';
      perf_ra_issue     : out std_logic := '0';
      perf_ra_used      : out std_logic := '0'
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
   -- mechanism: a load that stalls stage 3 in its issue cycle (the load-delay
   -- stall in cpu.vhd) has ce_fetch low, so the data RAMs re-read its own
   -- address; one that does not goes through REREAD first (below). An
   -- assertion below checks it.
   --
   -- LOADS WITHOUT THE BUBBLE. The load-delay stall above is taken only
   -- when the instruction behind the load reads its register (cpu.vhd's
   -- load_use), as on the R4600, and otherwise that instruction executes in stage 3 while
   -- the load is here in IDLE - ce_fetch high, so the data RAMs read ITS
   -- address, not the load's. Three things follow. A load that needs the
   -- RAMs' next read - READWAIT or WAYFIX - goes through REREAD first,
   -- one cycle in which they read the load's own doubleword. read_data's
   -- alignment comes from RW_addr, which belongs to the next instruction once
   -- stage 3 moves on, so it is latched here in IDLE (rd_low). And an access
   -- can reach IDLE straight from a busy cycle, whose RAM read was
   -- tag_read_addr, so ram_stale - the store-then-load flag - is also set by
   -- every busy state. Each costs the cycle the bubble would otherwise hide,
   -- and only on the loads that take those paths; the common hit loses its
   -- bubble.
   --
   -- THE STORE BUFFER. A store that hits does not write the data RAMs
   -- through port b in its own IDLE cycle: that would keep the RAMs from
   -- reading the next access's address then, and send a load straight after
   -- a store through READWAIT - in KI2's background renderer the bottom of
   -- three loops against the top, every store and load to different lines.
   -- The store parks instead - address, way, data, byte enables - and the
   -- RAMs read on as if it were not there; its tag is updated at once. It is
   -- written when the port is free:
   --   * in IDLE with nothing presented, the pipeline moving and stage 3 not
   --     a load (next_load), so nobody wants this cycle's read;
   --   * by the next store to another doubleword, which parks in its place (a
   --     store to the same doubleword and way merges instead);
   --   * by a load of the buffered doubleword, which then re-reads (REREAD) -
   --     unless it is forwarded, below;
   --   * by a command;
   --   * in the first cycle of FILL, the dirty victim's WRITEBACK1ADDR and
   --     FILLRA_WAIT, which leave the port idle - so a line is never read,
   --     written back, filled around or copied over while a store to it waits.
   -- ALLOC, READWAIT, WAYFIX and REREAD keep it: none touches a line
   -- that can hold it (the buffered line is dirty, so it is never evicted
   -- without the write-back). Nothing selecting the RAM address depends on the
   -- tag compare.
   --
   -- FORWARDING. A load in IDLE on the buffered doubleword that
   -- hits the predicted way, whose doubleword the data RAMs read last cycle
   -- (sb_rd_ok), is answered there and then: the RAMs' read with the
   -- buffer's bytes over it. A read in a cycle that wrote the same address
   -- is good too: port b reads new data across its own write. The buffer is not drained for it -
   -- it stays parked, the next store to the doubleword merges in, and the
   -- RAMs read on, so the access after the load is not stale. sb_rd_ok also
   -- holds where ram_stale is set by a store that MERGED: the RAMs then read
   -- the store's own doubleword, which is the load's. The bytes are merged
   -- only when the buffered store is in the predicted way - the same
   -- doubleword index in the other way is another line - and the select
   -- (sb_fwd_sel) is registers and the MRU RAM's output, never the tag
   -- compare: a load the select picks wrongly is not answered (read_done).
   -- Every other load of the buffered doubleword drains it and re-reads.
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
   -- SKIPPING THE STORE-MISS FILL. In the heavy frames most
   -- misses are stores, and almost none of those fills are ever read: the
   -- line is written whole, every qword by a 64-bit store, before anything
   -- loads it. So a 64-bit store that misses takes its line
   -- without the SDRAM read, and the cache records which qwords it really
   -- holds - four ABSENT bits per line, beside the tag:
   --
   --   * the store miss writes back a dirty victim as any miss does, then
   --     tags the line with every qword but its own absent and writes the
   --     store (the
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
   -- READING AHEAD. KI's heavy frames miss almost always on the
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
   --   * that load is answered in the copy's last cycle, from the staging
   --     register itself, not read back from the RAM after the copy:
   --     the copy ends that cycle, so the cache is in IDLE when
   --     the next access comes, as after any answer; a store lands its data
   --     in FILLRA_DONE;
   --   * a 64-bit store that skips its fill takes ALLOC and throws
   --     the copy away - defensively: the line it leaves is dirty, so its
   --     eviction's write-back would make the copy stale anyway;
   --   * any store to the staged line reaching the write FIFO after the
   --     read-ahead was asked for - a write-back or an uncached store - makes
   --     the copy stale, and a miss on it then fills the ordinary way;
   --   * the line after is asked for across the load's 4 KB page
   --     only when the load was unmapped (KSEG0, so the
   --     virtual address in tag_addr_1 is the physical one), of low or main
   --     RAM, and the line after is in the same 512 KB (ra_xpage, written
   --     with ram_reqAddr in every IDLE cycle; a fill's and a copy's asks
   --     read it before the cache is next in IDLE, and the tail's ask, made
   --     after TAIL_ANS has returned to IDLE, reads tail_ra_ok, taken from
   --     it at tail_go). Every RAM range of the board
   --     begins and ends on a 512 KB boundary, so that line is in the load's
   --     own RAM, never in I/O, an undecoded gap, the boot ROM or main RAM's
   --     alias: a read-ahead never steps out of the memory the load was in.
   --     Any other load's read-ahead stays inside its 4 KB page - for a load
   --     through the TLB, the physical page after its own belongs to another
   --     virtual page, or to none;
   --   * a read-ahead asked for by a copy that had to wait for its line - the
   --     CPU reading faster than lines come - is marked as a stream's
   --     (ra_reqStream), for the memory to keep its row open for the next;
   --   * that read-ahead need not wait for the copy's ask. While
   --     a load waits in FILLRA_WAIT for its own line's read-ahead, the copy's
   --     ask conditions holding, the cache arms (ra_chain_ok) with the line
   --     after in a register of its own (chain_line), and cpu.vhd may launch
   --     that line as the awaited one lands (ra_chain_taken). The cache then
   --     stages it as in flight when it leaves FILLRA_WAIT - to the copy, or
   --     to a fill if the awaited line was dropped - and asks for nothing. A
   --     store to it from the edge it may leave on until it is staged poisons
   --     it there (chain_poison); from then on ra_poison_now does. A launch
   --     not taken leaves the copy to ask.
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
   -- the same test perf_stride_hit counts. A stream arms on its second miss and stays
   -- armed (a miss served from the copy is still a next-line miss); scattered
   -- misses never arm it.
   --
   -- EARLY RESTART. A line arrives a qword at a time, and a
   -- load needs only one of them. So a load miss on a whole line is answered
   -- as soon as its own qword is in the data RAM (TAIL_ANS), and the rest of
   -- the line - the TAIL - lands while the CPU runs on. While it lands:
   --
   --   * an access to a qword of the tail line that is in is served as any
   --     hit; one to a qword not yet in waits for it (TAIL_WAIT), then a load
   --     is answered (TAIL_ANS) or a store written (TAIL_STORE);
   --   * a miss in the tail line's set never takes the tail line's way;
   --   * a write-back of the tail line waits for it to land;
   --   * a miss's fill request leaves at once when cpu.vhd can queue it
   --     behind the tail's line on the direct port (tail_q_ok), which serves
   --     the two in order; otherwise it is held until the tail has landed;
   --   * the tail line's completion (ram_done) is the one that arrives while
   --     the tail is landing, and is not the next fill's (fill_done_mine).
   --
   -- When the tail has landed, the read-ahead the load would have asked for
   -- at its completion is asked for then, unless the line after has missed
   -- meanwhile and is being filled already.
   --
   -- The data RAMs are dual-clock M10K, written by the fill on clk1x through
   -- port a and used by the CPU on clk2x through port b, and a port b access
   -- to a word within the clk1x cycle of its port a write is undefined and
   -- not timed. So a qword counts as in from tail_arr_d - one clk2x cycle
   -- after the clk1x edge that wrote it - for a state that reads or writes it
   -- on the next edge (TAIL_ANS, TAIL_STORE), and from tail_arr_dd, a cycle
   -- later, for an access in IDLE, whose read was this cycle's edge. A
   -- grant's toggle is taken with the arrivals (tail_gnt_d), so a new fill is
   -- never judged on the last one's qwords.
   --
   -- FILLING FIRST. A framebuffer miss with a dirty victim is filled before
   -- the victim is written back. Once the victim's four words are staged
   -- the cache goes to its fill without waiting for the line to cross, and
   -- wb_hold keeps cpu.vhd from issuing the staged line until the cache is
   -- back in IDLE: the bridge reads the new line, then writes the old - the
   -- R4600's order. The hold goes up as the last word is staged, never
   -- earlier: a miss taken in the IDLE cycle that ends the last one's hold
   -- lets that line go before its own write-back needs the queue. An SDRAM
   -- miss keeps the write-back first; its direct fill needs the staging
   -- queue empty.
   --
   -- The fill is asked for in the cycle the miss is taken, and the victim is
   -- staged while it comes: the R4600 moves the dirty line to its write
   -- buffer before it reads. Only when nothing holds the write FIFO then
   -- (fifo_block), so the staging queue is empty: the staging starts in the
   -- next cycle without waiting for the request to issue, and its four reads
   -- are taken in the four cycles after - before the fill's first beat,
   -- which crosses to clk1x and back, can reach the data RAMs. The
   -- staging-read assertion below holds it. Otherwise the fill is asked for
   -- once the victim is staged. A fill done before FILL is found done there
   -- (fam_done_r).

   signal ce_fetch         : std_logic;

   -- The fill's first qword, taken as IDLE takes the rest of the miss; its
   -- clk1x copy from the grant; and the qword each beat writes. A
   -- framebuffer line is filled from the qword its access wants: the
   -- request carries that qword in ram_reqAddr bits 4..3, and the bridge
   -- returns the line in sub-block order, beat k being that qword XOR k, as
   -- the R4600 returns a block. The access's own qword is then the first in
   -- (see EARLY RESTART). Every other line starts at qword 0.
   signal fill_start       : unsigned(1 downto 0) := "00";
   signal fill_start_1x    : unsigned(1 downto 0) := "00";
   signal fill_q_1x        : unsigned(1 downto 0);
   -- This miss fills first (ff_miss_r; see FILLING FIRST), and wb_hold's
   -- register.
   signal ff_miss_r        : std_logic := '0';
   signal wb_hold_r        : std_logic := '0';
   -- This miss's fill was asked for at the miss (fam_req_r), and
   -- it completed before the cache reached FILL (fam_done_r).
   signal fam_req_r        : std_logic := '0';
   signal fam_done_r       : std_logic := '0';

   type t_tag  is array(0 to 1) of std_logic_vector(57 downto 0);
   type t_data is array(0 to 1) of std_logic_vector(63 downto 0);

   -- tags: bytes(31..0) & absent(3..0) & dirty & valid & address(31..12),
   -- one RAM per way. Absent bit i is the qword at offset 8i.
   -- bytes(8i+7..8i) are the bytes of an ABSENT qword i a partial
   -- framebuffer store has written; meaningless for a present one.
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
   -- A partial framebuffer store: it may allocate without a fill
   -- or hit an absent qword. store_ok is either kind; store_bytes the store's
   -- bytes placed in the line.
   signal store_part       : std_logic;
   signal store_ok         : std_logic;
   signal store_bytes      : std_logic_vector(31 downto 0);
   -- The hit line's written bytes, and its bytes and absent qwords as this
   -- store will leave them.
   signal hit_bytes        : std_logic_vector(31 downto 0);
-- synthesis translate_off
   signal alloc_part_1     : std_logic := '0';
-- synthesis translate_on
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

   -- data
   signal fill_line_saved  : unsigned(SET_BITS - 1 downto 0) := (others => '0');
   signal fill_line_1x     : unsigned(7 downto 0) := (others => '0');
   signal fill_way_1x      : std_logic := '0';
   signal fill_way_now     : std_logic;
   signal fill_beat_1x     : unsigned(1 downto 0) := (others => '0');
   signal fill_active_1x   : std_logic := '0';
   signal fill_grant       : std_logic;
   -- The qwords a fill writes: all four, or a line's absent ones. Latched in
   -- IDLE like fill_line_saved, and like it read from clk1x.
   signal fill_mask        : std_logic_vector(3 downto 0) := (others => '1');
   signal fill_mask_1x     : std_logic_vector(3 downto 0) := (others => '1');
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
   signal fill_bytes_1x    : std_logic_vector(31 downto 0) := (others => '0');
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
      -- Unused; keeps the later states' debug_state numbers.
      UNUSED_4,
      WRITEBACK1ADDR,
      WRITEBACK1READ,
      WRITEBACK1WRITE,
      WRITEBACK2WRITE,
      WRITEBACK3WRITE,
      WRITEBACK4WRITE,
      WRITEBACKDONE,
      COMMANDPROCESS,
      COMMANDDONE,
      -- After the older states, so each keeps its debug_state number.
      WAYFIX,
      -- A skipped fill: tag the line and take the store.
      ALLOC,
      -- A miss on the read-ahead's line: wait for the copy, copy it in, finish.
      FILLRA_WAIT,
      FILLRA_COPY,
      FILLRA_DONE,
      -- The RAMs read the load's own doubleword, for the
      -- READWAIT or WAYFIX (reread_wf) that follows.
      REREAD,
      -- An access to a qword of the landing line that is not
      -- in yet waits for it; then a load is answered, or a store written.
      -- A fill's load answered before the line is in is answered in TAIL_ANS
      -- too.
      TAIL_WAIT,
      TAIL_ANS,
      TAIL_STORE
   );
   signal state : tstate := IDLE;

   signal writeMode        : std_logic := '0';
   signal fillNext         : std_logic := '0';
   -- After the victim's write-back, ALLOC instead of FILL.
   signal allocNext        : std_logic := '0';
   -- The data RAMs' output is not the doubleword of the access now in IDLE
   -- (tag_addr_1's): last cycle a store addressed them, or the cache was
   -- busy and they read tag_read_addr. A load then re-reads through
   -- READWAIT.
   signal ram_stale        : std_logic := '0';
   -- The load's own RW_addr(2 downto 0), for read_data once
   -- the cache has left IDLE; and REREAD's successor, WAYFIX if set.
   signal rd_low           : unsigned(2 downto 0) := (others => '0');
   signal rd_sel           : unsigned(2 downto 0);
   signal reread_wf        : std_logic := '0';
   -- The store buffer: the parked store, and this cycle's decisions about it.
   signal sb_valid         : std_logic := '0';
   signal sb_addr          : unsigned(IDX_HI downto 3) := (others => '0');
   signal sb_way           : std_logic := '0';
   signal sb_data          : std_logic_vector(63 downto 0) := (others => '0');
   signal sb_be            : std_logic_vector(7 downto 0) := (others => '0');
   signal sb_ok            : std_logic;   -- a store may park: not write-through
   signal sb_same          : std_logic;   -- the access in IDLE is to the buffered doubleword
   signal sb_park          : std_logic;   -- a store takes the (freed) entry
   signal sb_merge         : std_logic;   -- a store merges into it
   signal sb_drain_idle    : std_logic;
   signal sb_drain         : std_logic;   -- it is written to the RAMs at this edge
   signal sb_fwd           : std_logic;   -- a load is answered from the buffer
   signal sb_fwd_sel       : std_logic;   -- the RAMs' read takes the buffer's bytes
   signal sb_fwd_d         : std_logic := '0';
   signal sb_fwd_q         : std_logic_vector(63 downto 0);
   -- The doubleword port b read last cycle: the load's own is good whatever
   -- ram_stale says.
   signal sb_rd_addr_r     : std_logic_vector(IDX_HI - 3 downto 0) := (others => '0');
   signal sb_rd_ok         : std_logic;
   signal st_direct_a      : std_logic;   -- a store in IDLE may write the RAMs itself
   -- synthesis translate_off
   signal ram_rd_1         : std_logic_vector(IDX_HI - 3 downto 0) := (others => '0');
   -- synthesis translate_on

   signal clearAddr        : std_logic_vector(7 downto 0) := (others => '0');

   signal isCommand        : std_logic := '0';

   signal tag_wren_cmd     : std_logic := '0';
   signal tag_addr_cmd     : std_logic_vector(SET_BITS - 1 downto 0) := (others => '0');
   signal tag_data_cmd     : std_logic_vector(57 downto 0) := (others => '0');
   -- Which ways a command, fill or clear tag write goes to.
   signal tag_way_cmd      : std_logic_vector(1 downto 0) := "00";


   -- See EARLY RESTART. req_r is this cache's fill request,
   -- registered; ram_request is it, or a held one, once it may leave.
   -- tail_gnt_1x toggles at every fill grant and tail_arr_1x marks the qwords
   -- of the current fill written so far, on clk1x; tail_gnt_d and tail_arr_d
   -- are their clk2x copies, a cycle late, and tail_arr_dd a cycle later.
   signal req_r          : std_logic := '0';
   signal fill_done_mine : std_logic;
   signal tail_gnt_1x    : std_logic := '0';
   signal tail_arr_1x    : std_logic_vector(3 downto 0) := (others => '0');
   signal tail_gnt_d     : std_logic := '0';
   signal tail_arr_d     : std_logic_vector(3 downto 0) := (others => '0');
   signal tail_arr_dd    : std_logic_vector(3 downto 0) := (others => '0');
   signal tail_gnt_at    : std_logic := '0';
   -- tail: a line is landing behind an early answer - its set, way and line;
   -- tail_done: its completion has come; tail_held: a fill request raised
   -- meanwhile that has not left.
   signal tail           : std_logic := '0';
   signal tail_idx       : unsigned(SET_BITS - 1 downto 0) := (others => '0');
   signal tail_way       : std_logic := '0';
   signal tail_line      : unsigned(26 downto 0) := (others => '0');
   signal tail_done      : std_logic := '0';
   signal tail_held      : std_logic := '0';
   -- The read-ahead the answered load would have asked for at its
   -- completion, and whether the line after has missed meanwhile.
   signal tail_ra_ok     : std_logic := '0';
   signal tail_next_miss : std_logic := '0';
   signal tail_hit       : std_logic;
   signal tail_blk       : std_logic;
   signal tail_go        : std_logic;
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
-- synthesis translate_off
   signal ra_vdrop       : std_logic := '0';
-- synthesis translate_on
   signal ra_poison_now  : std_logic;
   -- This FILLRA_WAIT has lasted more than its one cycle.
   signal fillra_waited  : std_logic := '0';
   -- The chained read-ahead: the arm's conditions now (chain_arm) and its
   -- register; the line after (chain_line); the launch seen and not yet staged
   -- (chain_fired), either (chain_live); and a store to that line on an edge
   -- it may have left on or since (chain_poison, this cycle's
   -- chain_poison_now).
   signal chain_arm        : std_logic;
   signal chain_ok_r       : std_logic := '0';
   signal chain_ok_d       : std_logic := '0';
   signal chain_line       : unsigned(26 downto 0) := (others => '0');
   signal chain_fired      : std_logic := '0';
   signal chain_live       : std_logic;
   signal chain_poison     : std_logic := '0';
   signal chain_poison_now : std_logic;
   -- The line after this miss's may be asked for across its
   -- 4 KB page. Latched in IDLE with ram_reqAddr; see READING AHEAD.
   signal ra_xpage       : std_logic := '0';
   -- The staged line, as address(31..5).
   signal ra_line        : unsigned(26 downto 0) := (others => '0');
   -- This access's line is the staged one.
   signal ra_match       : std_logic;
   -- The miss behind a write-back fills from the staged line.
   signal fillRA         : std_logic := '0';
   signal ra_qword       : std_logic_vector(63 downto 0);
   signal ra_qword_ld    : std_logic_vector(63 downto 0);
   signal ra_ans         : std_logic;
   signal rd_q           : std_logic_vector(63 downto 0);

begin

   debug_state <= std_logic_vector(to_unsigned(tState'pos(state), 5));
   clear_busy  <= '1' when (state = CLEARCACHE) else '0';
   fill_last_q <= '1' when (tag_read_addr(4 downto 3) = (fill_start xor "11")) else '0';
   -- Not for a miss served from the read-ahead copy: its line asks nothing
   -- of the bridge.
   wb_hold     <= wb_hold_r and (not fillRA);
   fill_grant <= ram_grant and ram_active;

   perf_stride_hit <= stride_hit_i;
   perf_delta_hit  <= delta_hit_i;
   perf_fill_wait <= '1' when (state = FILL and fill_beat_seen = '0') else '0';
   perf_fill_data <= '1' when (state = FILL and fill_beat_seen = '1' and
                               fill_active_1x = '1') else '0';
   perf_fill_hold <= '1' when (state = FILL and fill_beat_seen = '1' and
                               fill_active_1x = '0') else '0';

   perf_miss <= perf_miss_i;
   -- Below 0x0008_0000: the board's SRAM. perf_miss_i is combinational on
   -- state = IDLE with read_ena/write_ena, so RW_addr holds this access's
   -- address in the same cycle.
   perf_miss_low <= perf_miss_i when (RW_addr(31 downto 19) = 0) else '0';
   -- Exactly the IDLE branch that starts a fill, so one cycle per miss: the
   -- state machine has no clock enable and leaves IDLE the next cycle. The
   -- write-through miss above it is excluded because it allocates nothing.
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
   perf_fill_store  <= '1' when (state = FILL and fill_done_mine = '1' and writeMode = '1') else '0';
   perf_fill_skip   <= '1' when (state = ALLOC) else '0';
   -- A miss in the IDLE branch that fills a resident line.
   perf_fill_absent <= perf_miss_i and line_hit;

   writeback_mask <= wb_mask;
   writeback_bytes <= wb_bytes;

   ra_match <= '1' when (ra_state /= RA_NONE and
                         RW_addr(31 downto 5) = ra_line) else '0';
   -- A store to the staged line in this very cycle: physical line bits, so a
   -- KSEG1 store and a KSEG0 write-back of the same memory both count.
   ra_poison_now <= '1' when (ra_store = '1' and ra_state /= RA_NONE and
                              ra_store_addr(28 downto 5) = ra_line(23 downto 0)) else '0';
   ra_qword <= ra_data( 63 downto   0) when (tag_read_addr(4 downto 3) = "00") else
               ra_data(127 downto  64) when (tag_read_addr(4 downto 3) = "01") else
               ra_data(191 downto 128) when (tag_read_addr(4 downto 3) = "10") else
               ra_data(255 downto 192);
   -- The load's own qword of the staged line, and the cycle it
   -- is answered from it - FILLRA_COPY's last, whose write ends the copy.
   ra_qword_ld <= ra_data( 63 downto   0) when (tag_addr_low(4 downto 3) = "00") else
                  ra_data(127 downto  64) when (tag_addr_low(4 downto 3) = "01") else
                  ra_data(191 downto 128) when (tag_addr_low(4 downto 3) = "10") else
                  ra_data(255 downto 192);
   ra_ans <= '1' when (state = FILLRA_COPY and writeMode = '0' and
                       tag_read_addr(4 downto 3) = "11") else '0';
   rd_q   <= ra_qword_ld when (ra_ans = '1') else sb_fwd_q;

   -- Forwarding: see "THE STORE BUFFER".
   sb_rd_ok   <= '1' when (ram_stale = '0' or
                           sb_rd_addr_r = std_logic_vector(tag_addr_1(IDX_HI downto 3))) else '0';
   sb_fwd     <= '1' when (state = IDLE and read_ena = '1' and
                           read_hit = '1' and fast_hit = '1' and sb_same = '1' and
                           sb_rd_ok = '1' and tail_blk = '0') else '0';
   sb_fwd_sel <= '1' when (state = IDLE and sb_same = '1' and
                           pred_way = sb_way) else '0';
   sb_fwd_bytes : for b in 0 to 7 generate
      sb_fwd_q(b * 8 + 7 downto b * 8) <=
         sb_data(b * 8 + 7 downto b * 8) when (sb_fwd_sel = '1' and sb_be(b) = '1') else
         cache_q_b(b * 8 + 7 downto b * 8);
   end generate;

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         sb_rd_addr_r <= cache_address_b;
      end if;
   end process;
   perf_ra_used <= '1' when (state = FILLRA_WAIT and ra_state = RA_VALID and
                             ra_poison_now = '0' and
                             ra_line = ram_reqAddr(31 downto 5)) else '0';

   -- The chain's arm: up while the load waits for its own line's read-ahead, in
   -- flight and unpoisoned, under the conditions the copy asks on; until that
   -- line's completion, and not once the line after has left.
   chain_live <= ra_chain_taken or chain_fired;
   chain_arm  <= '1' when (state = FILLRA_WAIT and
                           ra_state = RA_FLIGHT and ra_done = '0' and
                           ra_poison = '0' and ra_poison_now = '0' and
                           ra_line = ram_reqAddr(31 downto 5) and
                           writeMode = '0' and write_through_in = '0' and ra_arm = '1' and
                           (ram_reqAddr(11 downto 5) /= "1111111" or
                            ra_xpage = '1') and
                           ra_chain_sdram = '1' and chain_live = '0') else '0';
   chain_poison_now <= '1' when (ra_store = '1' and
                                 ra_store_addr(28 downto 5) = chain_line(23 downto 0)) else '0';
   ra_chain_ok   <= chain_ok_r;
   ra_chain_addr <= chain_line & "00000";

   ce_fetch <= '1' when (stall = 0) else '0';

   -- EARLY RESTART. The landing line's own completion is not this fill's; a
   -- request raised during the tail leaves when it may (tail_q_ok) or once
   -- the tail has landed. tail_blk: an access in IDLE to a qword of the
   -- landing line that is not in yet. tail_go: the fill's load can be
   -- answered now - a whole-line load fill, its grant seen, its qword in.
   fill_done_mine <= ram_done and not tail;
   ram_request    <= (req_r or tail_held) and ((not tail) or tail_q_ok);
   tail_hit <= '1' when (tail = '1' and
                         tag_addr_1(IDX_HI downto 5) = tail_idx and
                         ((tail_way = '1' and line_hit_w(1) = '1') or
                          (tail_way = '0' and line_hit_w(0) = '1'))) else '0';
   tail_blk <= '1' when (tail_hit = '1' and state = IDLE and
                         (read_ena = '1' or write_ena = '1') and
                         tail_arr_dd(to_integer(tag_addr_1(4 downto 3))) = '0') else '0';
   tail_go  <= '1' when (state = FILL and tail = '0' and
                         req_r = '0' and writeMode = '0' and
                         fill_mask = "1111" and write_through_in = '0' and
                         tail_gnt_d /= tail_gnt_at and
                         tail_arr_d(to_integer(tag_read_addr(4 downto 3))) = '1') else '0';

   -- synthesis translate_off
   -- The dual-clock data RAMs' rule, asserted: no port b access is used
   -- within a clk1x period of a port a write to the same word of the same
   -- way - not a load's read that is answered from, not a store's write.
   -- A read is answered (read_done) from the read on the edge that began
   -- the cycle, at the address presented the cycle before; an answer from
   -- the read-ahead's staging register (ra_ans) reads no RAM. And a write-back
   -- stages its line as it was: no read of its four words (WRITEBACK1WRITE ..
   -- WRITEBACK4WRITE take them) comes at or after a write of the word by a
   -- fill granted since the write-back began - its own miss's fill, asked
   -- for at the miss. Checked while the two clocks' edges are aligned, as they
   -- are on hardware: the design counts a qword in by clk2x edges after
   -- clk1x's, which holds the rule only for that relation.
   process (clk1x, clk2x)
      type t_wtime is array (0 to 2 ** (SET_BITS + 2) - 1) of time;
      variable wtime    : t_wtime := (others => -1 sec);
      variable wtime1   : t_wtime := (others => -1 sec);
      variable addr_q   : integer := 0;
      variable p1x      : time := 20 ns;
      variable last1x   : time := 0 ns;
      variable p2x      : time := 10 ns;
      variable last2x   : time := 0 ns;
      variable used_way : std_logic;
      variable a        : integer;
      variable wt       : time;
      variable aligned  : boolean := false;
      variable st_prev  : tState := IDLE;
      variable wb_from  : time := 0 ns;
      variable wb_gnt   : time := time'high;
   begin
      if rising_edge(clk1x) then
         if (last1x > 0 ns) then p1x := now - last1x; end if;
         last1x := now;
         aligned := (now - last2x = 0 ns) or (now - last2x = p2x);
         a := to_integer(unsigned(cache_ram_addr_a));
         if (cache_wr_a_w(0) = '1') then wtime(a)  := now; end if;
         if (cache_wr_a_w(1) = '1') then wtime1(a) := now; end if;
         if (fill_grant = '1' and wb_gnt = time'high and now > wb_from) then
            wb_gnt := now;
         end if;
      end if;
      if rising_edge(clk2x) then
         if (last2x > 0 ns) then p2x := now - last2x; end if;
         last2x := now;
         if (state = WRITEBACK1ADDR and st_prev /= WRITEBACK1ADDR) then
            wb_from := now - p2x;
            wb_gnt  := time'high;
         end if;
         st_prev := state;
      end if;
      if rising_edge(clk2x) and reset_2x = '0' and aligned then
         if (read_done = '1' and ra_ans = '0') then
            if (state = IDLE) then used_way := pred_way; else used_way := data_way; end if;
            if (used_way = '0') then wt := wtime(addr_q); else wt := wtime1(addr_q); end if;
            assert (now - p2x) - wt >= p1x or wt > now - p2x
               report "cpu_datacache: a load answered from a word within a clk1x period of its fill write (word " &
                      integer'image(addr_q) & ", way " & std_logic'image(used_way) & ", read " &
                      time'image((now - p2x) - wt) & " after the write, in " & tState'image(state) & ")"
               severity failure;
         end if;
         a := to_integer(unsigned(cache_address_b));
         if (cache_we_w(0) = '1') then
            assert now - wtime(a) >= p1x
               report "cpu_datacache: a store written within a clk1x period of its word's fill write (word " &
                      integer'image(a) & ", " & time'image(now - wtime(a)) & " after it, in " &
                      tState'image(state) & ")"
               severity failure;
         end if;
         if (cache_we_w(1) = '1') then
            assert now - wtime1(a) >= p1x
               report "cpu_datacache: a store written within a clk1x period of its word's fill write (word " &
                      integer'image(a) & ", " & time'image(now - wtime1(a)) & " after it, in " &
                      tState'image(state) & ")"
               severity failure;
         end if;
         if (state = WRITEBACK1WRITE or state = WRITEBACK2WRITE or
             state = WRITEBACK3WRITE or state = WRITEBACK4WRITE) then
            if (data_way = '0') then wt := wtime(addr_q); else wt := wtime1(addr_q); end if;
            assert not (wt >= wb_gnt and wt <= now - p2x)
               report "cpu_datacache: a write-back staged a word its miss's fill had already written (word " &
                      integer'image(addr_q) & ", way " & std_logic'image(data_way) & ", in " &
                      tState'image(state) & ")"
               severity failure;
         end if;
         addr_q := to_integer(unsigned(cache_address_b));
      end if;
   end process;
   -- synthesis translate_on

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
                                 write_ena = '1' and hit_w(w) = '1' and tail_blk = '0') else
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
         clock_a     => clk2x,
         address_a   => tag_address_a,
         data_a      => tag_wdata(w),
         wren_a      => tag_wren_w(w),

         clock_b     => clk2x,
         clken_b     => ce_fetch,
         address_b   => tag_address_b,
         data_b      => 58x"0",
         wren_b      => '0',
         q_b         => tag_q_b(w)
      );

      tag_w(w)      <= tag_newData(w) when (tag_newEna(w) = '1') else tag_q_b(w);
      line_hit_w(w) <= '1' when (unsigned(tag_w(w)(19 downto TAG_LO)) = RW_addr(31 downto IDX_HI + 1) and
                                 tag_w(w)(20) = '1') else '0';
      qabs_w(w)     <= tag_w(w)(22 + to_integer(RW_addr(4 downto 3)));
      hit_w(w)      <= line_hit_w(w) and ((not qabs_w(w)) or store_ok);
   end generate;

   line_hit   <= line_hit_w(0) or line_hit_w(1);
   read_hit   <= hit_w(0) or hit_w(1);
   -- The way holding the line, whether or not it can serve this access.
   hit_way    <= line_hit_w(1);
   -- A hit in the predicted way is an ordinary one-cycle hit.
   fast_hit   <= hit_w(1) when (pred_way = '1') else hit_w(0);
   hit_dirty  <= (line_hit_w(0) and tag_w(0)(21)) or (line_hit_w(1) and tag_w(1)(21));
   hit_absent <= tag_w(1)(25 downto 22)   when (line_hit_w(1) = '1') else
                 tag_w(0)(25 downto 22);
   hit_bytes  <= tag_w(1)(57 downto 26)   when (line_hit_w(1) = '1') else
                 tag_w(0)(57 downto 26);

   -- Every byte of the qword: only a 64-bit store's enables are all set, and
   -- rotating a 32-bit store's halves cannot make them so.
   store_full  <= '1' when (write_ena = '1' and write_be = x"FF") else '0';
   store_clear <= "0000" when (store_full = '0') else
                  "0001" when (RW_addr(4 downto 3) = "00") else
                  "0010" when (RW_addr(4 downto 3) = "01") else
                  "0100" when (RW_addr(4 downto 3) = "10") else
                  "1000";
   -- PARTIAL FRAMEBUFFER STORES. KI2 draws its background with
   -- unaligned sdl/sdr, so most of the doubleword stores into its framebuffer
   -- are partial, and most of its framebuffer line allocations would fill
   -- lines the routine then overwrites end to end. So a partial store to a
   -- framebuffer line is treated as a full one is: a miss allocates without
   -- a fill, and a hit on an absent qword is a hit. What makes that safe is the byte field
   -- beside the tag: a load of an absent qword fills it around the bytes
   -- stored (fill_keep), a write-back sends only them (writeback_bytes into
   -- the framebuffer RAM's byte enables), and a qword whose eight bytes are
   -- all stored becomes present. Only framebuffer lines, because their
   -- write-back can mask bytes: SDRAM here ignores DQM, which is why every
   -- other skipped fill stays qword-granular.
   store_part  <= '1' when (write_ena = '1' and RW_fb = '1' and
                            write_through_in = '0' and write_be /= x"FF") else '0';
   store_ok    <= store_full or store_part;
   gstb : for q in 0 to 3 generate
      store_bytes(q * 8 + 7 downto q * 8) <= write_be_rot when (store_part = '1' and
                                                                to_integer(RW_addr(4 downto 3)) = q)
                                             else x"00";
   end generate;
   -- A write-through store allocates nothing, so it skips nothing.
   skip_ok     <= '1' when (store_ok = '1' and write_through_in = '0') else '0';
   -- Replace an invalid way first, else the least recently used one.
   -- Never the line landing behind an early answer.
   victim_way <= (not tail_way) when (tail = '1' and
                                      tag_addr_1(IDX_HI downto 5) = tail_idx) else
                 '0' when (tag_w(0)(20) = '0') else
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
   -- simulation, unspecified on the board - and cpu.vhd's merge_bypass does
   -- exactly that read on every pair it bypasses: the ldr straight behind
   -- its ldl, the same line. Old data predicts that line's
   -- way whenever it was already the most recent in its set, the usual case.
   gmru : block
      type t_mru is array (0 to 2**SET_BITS - 1) of std_logic_vector(0 downto 0);
      signal mru_mem : t_mru := (others => "0");
      attribute ramstyle : string;
      attribute ramstyle of mru_mem : signal is "M10K";
   begin
      process (clk2x)
      begin
         if rising_edge(clk2x) then
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
            fill_active_1x <= '0';
            fill_line_1x   <= (others => '0');
            fill_way_1x    <= '0';
            fill_beat_1x   <= (others => '0');
            fill_mask_1x   <= (others => '1');
            fill_bytes_1x  <= (others => '0');
         elsif (fill_grant = '1') then
            fill_active_1x <= '1';
            fill_line_1x   <= fill_line_saved;
            fill_way_1x    <= data_way;
            fill_mask_1x   <= fill_mask;
            fill_bytes_1x  <= fill_bytes;
            fill_start_1x  <= fill_start;
            fill_beat_1x   <= (others => '0');
            if (ddr3_DOUT_READY = '1') then
               fill_beat_1x <= "01";
            end if;
         elsif (ram_active = '0') then
            -- The transaction this window belongs to is over. ddr3_DOUT_READY
            -- also carries other transactions' returns (see FILL), so a
            -- window left open would take them.
            fill_active_1x <= '0';
         elsif (fill_active_1x = '1' and ddr3_DOUT_READY = '1') then
            if (fill_beat_1x = "11") then
               fill_active_1x <= '0';
            else
               fill_beat_1x <= fill_beat_1x + 1;
            end if;
         end if;
      end if;
   end process;

   -- EARLY RESTART: the grants and the current fill's qwords written, as
   -- port a writes them.
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (reset_1x = '1') then
            tail_arr_1x <= (others => '0');
         elsif (fill_grant = '1') then
            tail_gnt_1x <= not tail_gnt_1x;
            tail_arr_1x <= "0000";
            if (ddr3_DOUT_READY = '1') then
               tail_arr_1x(to_integer(fill_start)) <= '1';
            end if;
         elsif (fill_active_1x = '1' and ddr3_DOUT_READY = '1' and ram_active = '1') then
            tail_arr_1x(to_integer(fill_q_1x)) <= '1';
         end if;
      end if;
   end process;

   -- Beat k writes qword k XOR the fill's first (fill_start).
   fill_q_1x        <= fill_beat_1x xor fill_start_1x;
   cache_ram_addr_a <= std_logic_vector(fill_line_saved & fill_start) when (fill_grant = '1') else
                       std_logic_vector(fill_line_1x & fill_q_1x);

   -- A fill of a resident line's absent qwords must not overwrite the qwords
   -- the CPU stored: each beat writes only if its qword is in the fill's mask.
   fill_beat_now    <= fill_start when (fill_grant = '1') else fill_q_1x;
   fill_mask_now    <= fill_mask when (fill_grant = '1') else fill_mask_1x;
   cache_wr_a       <= (fill_active_1x or fill_grant) and ddr3_DOUT_READY and ram_active and
                       fill_mask_now(to_integer(fill_beat_now));
   -- And within a qword it writes, not the bytes a partial store left there.
   fill_bytes_now   <= fill_bytes when (fill_grant = '1') else fill_bytes_1x;
   gkeep : for i in 0 to 7 generate
      fill_keep(i) <= fill_bytes_now(to_integer(fill_beat_now) * 8 + i);
   end generate;

   -- A fill writes the victim's way: data_way until the grant latches it.
   fill_way_now     <= data_way when (fill_grant = '1') else fill_way_1x;
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

            clock_b     => clk2x,
            address_b   => cache_address_b,
            data_b      => cache_data_b(((i * 8) + 7) downto (i*8)),
            wren_b      => cache_we_w(w) and cache_be_b(i),
            q_b         => cache_q_w(w)(((i * 8) + 7) downto (i*8))
         );
      end generate;
   end generate;

   -- The store buffer. sb_same is registers against registers; st_direct_a
   -- is the address side of "this store may write the RAMs itself", deliberately
   -- without the tag compare (sb_park/sb_merge have it, for the enables).
   sb_ok       <= '1' when (write_through_in = '0') else '0';
   sb_same     <= '1' when (sb_valid = '1' and
                            sb_addr = tag_addr_1(IDX_HI downto 3)) else '0';
   st_direct_a <= '1' when (sb_ok = '0' or sb_same = '1') else '0';
   sb_park     <= '1' when (state = IDLE and write_ena = '1' and read_hit = '1' and sb_ok = '1' and
                            tail_blk = '0' and (sb_valid = '0' or sb_same = '0')) else '0';
   sb_merge    <= '1' when (state = IDLE and write_ena = '1' and read_hit = '1' and sb_ok = '1' and
                            tail_blk = '0' and sb_same = '1' and hit_way = sb_way) else '0';
   sb_drain_idle <= '1' when (state = IDLE and sb_valid = '1' and
                              ((read_ena = '0' and write_ena = '0' and CacheCommandEna = '0' and
                                ce_fetch = '1' and next_load = '0') or
                               (write_ena = '1' and sb_ok = '1' and sb_same = '0') or
                               (read_ena = '1' and sb_same = '1' and sb_fwd = '0') or
                               CacheCommandEna = '1')) else '0';
   sb_drain    <= '1' when (sb_drain_idle = '1' or
                            (sb_valid = '1' and
                             ((state = FILL and req_r = '1') or
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
                                 sb_park = '0' and sb_merge = '0' and tail_blk = '0') or
                                (state = TAIL_STORE and data_way = '0') or
                                (sb_drain = '1' and sb_way = '0') or
                                (writeMode = '1' and state = FILL and fill_done_mine = '1' and
                                 data_way = '0') or
                                (state = ALLOC and data_way = '0') or
                                (state = FILLRA_COPY and data_way = '0') or
                                (writeMode = '1' and state = FILLRA_DONE and
                                 data_way = '0')) else '0';
   cache_we_w(1)   <= '1' when ((state = IDLE and hit_w(1) = '1' and write_ena = '1' and
                                 sb_park = '0' and sb_merge = '0' and tail_blk = '0') or
                                (state = TAIL_STORE and data_way = '1') or
                                (sb_drain = '1' and sb_way = '1') or
                                (writeMode = '1' and state = FILL and fill_done_mine = '1' and
                                 data_way = '1') or
                                (state = ALLOC and data_way = '1') or
                                (state = FILLRA_COPY and data_way = '1') or
                                (writeMode = '1' and state = FILLRA_DONE and
                                 data_way = '1')) else '0';

   write_done      <= '1'     when (write_through_in = '1' and
                                    state = IDLE and write_ena = '1' and
                                    fifo_block = '0') else
                       '1'     when (state = TAIL_STORE) else
                       '1'     when ((state = IDLE and read_hit = '1' and write_ena = '1' and tail_blk = '0') or
                                     (writeMode = '1' and state = FILL and fill_done_mine = '1')) else
                       '1'     when (state = ALLOC) else
                       '1'     when (writeMode = '1' and state = FILLRA_DONE) else
                       '0';

   read_busy       <= '1' when (state = READWAIT or state = FILL or
                                state = WAYFIX or state = FILLRA_WAIT or state = REREAD or
                                state = FILLRA_COPY or state = FILLRA_DONE or
                                state = TAIL_WAIT or state = TAIL_ANS or state = TAIL_STORE) else '0';

   read_done       <= '1' when (sb_fwd = '1') else
                      '1' when (state = IDLE and ram_stale = '0' and fast_hit = '1' and read_ena = '1' and
                                sb_same = '0' and tail_blk = '0') else
                      '1' when (state = TAIL_ANS) else
                      '1' when (state = READWAIT) else
                      '1' when (state = WAYFIX) else
                      '1' when (writeMode = '0' and state = FILL and fill_done_mine = '1') else
                      '1' when (ra_ans = '1') else
                      '0';

   -- A load answered outside IDLE may have the next instruction's RW_addr by
   -- then; rd_low is its own.
   rd_sel          <= RW_addr(2 downto 0) when (state = IDLE) else rd_low;

   read_data       <= rd_q                        when (rd_sel = "000") else
                      8x"0"  & rd_q(63 downto  8) when (rd_sel = "001") else
                      16x"0" & rd_q(63 downto 16) when (rd_sel = "010") else
                      24x"0" & rd_q(63 downto 24) when (rd_sel = "011") else
                      32x"0" & rd_q(63 downto 32) when (rd_sel = "100") else
                      40x"0" & rd_q(63 downto 40) when (rd_sel = "101") else
                      48x"0" & rd_q(63 downto 48) when (rd_sel = "110") else
                      56x"0" & rd_q(63 downto 56); -- when (rd_sel = "111")

   CachecommandStall <= '1' when (CacheCommandEna = '1' and CacheCommand = 5x"01") else
                        '1' when (CacheCommandEna = '1' and CacheCommand = 5x"05") else
                        '1' when (CacheCommandEna = '1' and CacheCommand = 5x"09") else
                        '1' when (CacheCommandEna = '1' and CacheCommand = 5x"0D") else
                        '1' when (CacheCommandEna = '1' and CacheCommand = 5x"11") else
                        '1' when (CacheCommandEna = '1' and CacheCommand = 5x"15") else
                        '1' when (CacheCommandEna = '1' and CacheCommand = 5x"19") else
                        '0';

   process (clk2x)
   begin
      if rising_edge(clk2x) then

         req_r       <= '0';
         writeback_ena     <= '0';
         ra_request        <= '0';
         perf_ra_issue     <= '0';
-- synthesis translate_off
         ra_vdrop          <= '0';
-- synthesis translate_on
         stride_hit_i      <= '0';
         delta_hit_i       <= '0';
         -- perf_miss is one cycle per allocating miss; sample the line address
         -- on it and compare against the previous one, and the delta against
         -- the previous delta.
         --
         -- LOAD misses only. A read-ahead can only save a load, and KI's heavy
         -- frames are 64-bit store streams whose consecutive store misses
         -- already skip their fill: counting those would make perf_stride_hit read high for
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
         writeTagEna       <= '0';

         -- synthesis translate_off
         -- READWAIT and WAYFIX deliver the data RAMs' NEXT read, so that read
         -- must be of the load's own doubleword. It is when ce_fetch is low in
         -- the load's IDLE cycle - a load the next instruction uses sets stall3
         -- as it enters stage 3 - but nothing in this file guarantees it.
         -- A load whose IDLE cycle has ce_fetch high goes through REREAD
         -- instead, which the next check covers.
         if (state = IDLE and reset_2x = '0' and read_ena = '1' and read_hit = '1' and
             (ram_stale = '1' or fast_hit = '0') and
             ce_fetch = '0' and
             cache_address_b /= std_logic_vector(tag_addr_1(IDX_HI downto 3))) then
            report "cpu_datacache: a load left IDLE for READWAIT/WAYFIX but the data RAMs are re-reading another address"
               severity failure;
         end if;
         -- Every load answered from the data RAMs gets the doubleword they
         -- read on the previous edge: its own. In IDLE that is tag_addr_1's,
         -- elsewhere tag_read_addr's.
         ram_rd_1 <= cache_address_b;
         if (reset_2x = '0' and read_done = '1' and state = IDLE and
             ram_rd_1 /= std_logic_vector(tag_addr_1(IDX_HI downto 3))) then
            report "cpu_datacache: a load hit in IDLE on a data RAM read of another doubleword"
               severity failure;
         end if;
         if (reset_2x = '0' and read_done = '1' and
             (state = READWAIT or state = WAYFIX) and
             ram_rd_1 /= std_logic_vector(tag_read_addr(IDX_HI downto 3))) then
            report "cpu_datacache: a load answered from a data RAM read of another doubleword"
               severity failure;
         end if;
         -- A load asks for the next read-ahead as its copy begins, so the
         -- staged copy (ra_data) must not change under the four COPY cycles
         -- that read it: no read-ahead lands during FILLRA_COPY, nor any qword
         -- of one that comes a qword at a time (ra_wr).
         if (reset_2x = '0' and state = FILLRA_COPY and
             (ra_done = '1' or ra_wr = '1')) then
            report "cpu_datacache: a read-ahead landed while the previous one was being copied in"
               severity failure;
         end if;
         -- A chained line leaves only from the arm, while the load
         -- still waits in FILLRA_WAIT, and is staged as it leaves the state.
         chain_ok_d <= chain_ok_r;
         if (reset_2x = '0' and ra_chain_taken = '1' and
             (chain_ok_d = '0' or chain_fired = '1' or state /= FILLRA_WAIT)) then
            report "cpu_datacache: a chained read-ahead launched without the arm, or outside FILLRA_WAIT"
               severity failure;
         end if;
         if (reset_2x = '0' and chain_fired = '1' and state /= FILLRA_WAIT) then
            report "cpu_datacache: a chained read-ahead left FILLRA_WAIT unstaged"
               severity failure;
         end if;
         -- The store buffer: a load never answers in IDLE from RAMs that lack
         -- the buffered store; nothing reads, copies over or fills a line while a
         -- store to it waits; a drain never shares the port with a store's
         -- own write.
         if (reset_2x = '0' and state = IDLE and read_done = '1' and sb_same = '1' and sb_fwd = '0') then
            report "cpu_datacache: a load hit in IDLE on the buffered doubleword" severity failure;
         end if;
         -- A forwarded load reads its own doubleword, in the way
         -- that hit, and never answers without the store buffer's rule; and
         -- it is answered once, so the cache stays in IDLE after it.
         if (reset_2x = '0' and sb_fwd = '1' and
             (sb_rd_ok = '0' or hit_way /= pred_way or sb_valid = '0')) then
            report "cpu_datacache: a load forwarded from the store buffer without its conditions" severity failure;
         end if;
         sb_fwd_d <= sb_fwd;
         if (reset_2x = '0' and sb_fwd_d = '1' and state /= IDLE) then
            report "cpu_datacache: a load forwarded from the store buffer left IDLE, to be answered again" severity failure;
         end if;
         if (reset_2x = '0' and sb_valid = '1' and
             (state = WRITEBACK1READ or state = FILLRA_COPY or
              (state = FILL and fill_done_mine = '1') or (state = FILLRA_DONE and writeMode = '1'))) then
            report "cpu_datacache: a line read or written while a store waits in the buffer" severity failure;
         end if;
         if (reset_2x = '0' and state = ALLOC and sb_valid = '1' and sb_way = data_way and
             sb_addr(IDX_HI downto 5) = tag_read_addr(IDX_HI downto 5)) then
            report "cpu_datacache: ALLOC over the line the buffered store belongs to" severity failure;
         end if;
         if (reset_2x = '0' and sb_drain = '1' and state = IDLE and write_ena = '1' and
             read_hit = '1' and sb_park = '0' and sb_merge = '0') then
            report "cpu_datacache: a drain and a store's own write in one cycle" severity failure;
         end if;
         -- ALLOC's tag and store land in the same cycle; see the state.
         if (state = ALLOC and tag_wren_cmd /= '1') then
            report "cpu_datacache: ALLOC without its tag write" severity failure;
         end if;
         -- Only a 64-bit store or a partial framebuffer store may skip its
         -- fill, and only a line with an
         -- absent qword may be filled around its present ones.
         if (state = ALLOC and (writeMode /= '1' or (write_be_1 /= x"FF" and alloc_part_1 = '0'))) then
            report "cpu_datacache: ALLOC for an access that is neither a 64-bit store nor a partial framebuffer store" severity failure;
         end if;
         if (state = FILL and req_r = '1' and fill_mask = "0000") then
            report "cpu_datacache: a fill with no qword to write" severity failure;
         end if;
         -- The copy is a whole line into a victim: never around present qwords.
         if (state = FILLRA_COPY and fill_mask /= "1111") then
            report "cpu_datacache: a read-ahead copy into a line with present qwords" severity failure;
         end if;
         -- A read-ahead of a 4 KB page's first line crossed into it: never
         -- into a 512 KB block's first line, and only in low or main RAM.
         if (reset_2x = '0' and (ra_request = '1' or perf_ra_issue = '1') and ra_line(6 downto 0) = 0 and
             (ra_line(13 downto 0) = 0 or
              not (ra_line(26 downto 14) = 0 or ra_line(26 downto 18) = "000010000"))) then
            report "cpu_datacache: a read-ahead asked for across a 4 KB page into a 512 KB block's first line, or outside low or main RAM" severity failure;
         end if;
         -- Only one read-ahead is ever outstanding. perf_ra_issue also marks
         -- a chained line staged without an ask; outside a reset only, for a
         -- tail's ask on a reset's first edge pulses it with nothing in
         -- flight after.
         if ((ra_request = '1' or (reset_2x = '0' and perf_ra_issue = '1')) and
             ra_state /= RA_FLIGHT) then
            report "cpu_datacache: a read-ahead asked for without being in flight" severity failure;
         end if;
         -- A read-ahead completion is only ever the one in flight, and so is
         -- every qword of one that comes a qword at a time (ra_wr): none
         -- lands in a staged copy.
         if ((ra_done = '1' or ra_wr = '1') and ra_state /= RA_FLIGHT) then
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

         -- The store buffer: written at this edge, freed; a store that hits
         -- takes it or merges into it. Applies in every state (drains happen outside IDLE).
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
         if (reset_2x = '1') then
            sb_valid <= '0';
         end if;

         -- A busy cycle's RAM read was tag_read_addr; the access that enters
         -- when it ends must re-read. See ram_stale.
         if (state /= IDLE) then
            ram_stale <= '1';
         end if;

         if (state /= FILLRA_WAIT) then
            fillra_waited <= '0';
         end if;

         -- Read-ahead bookkeeping. A store to the staged line makes the copy
         -- stale: in flight it is poisoned and dropped when it lands, landed
         -- it is dropped now.
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

         -- The chain's arm and the line after, held from the launch until
         -- the line is staged; a store to it on the edge it may leave on, and
         -- every one after.
         chain_ok_r <= chain_arm;
         if (chain_live = '0') then
            chain_line   <= ram_reqAddr(31 downto 5) + 1;
            chain_poison <= chain_poison_now;
         else
            chain_poison <= chain_poison or chain_poison_now;
         end if;
         if (ra_chain_taken = '1') then
            chain_fired <= '1';
         end if;

         -- EARLY RESTART: the arrivals a cycle and two late, the tail's
         -- completion, a request held through it, and its end. The line
         -- after the tail's missing during it, this cycle's miss included,
         -- makes the tail's read-ahead pointless: that line is being filled.
         tail_gnt_d  <= tail_gnt_1x;
         tail_arr_d  <= tail_arr_1x;
         tail_arr_dd <= tail_arr_d;
         if (tail = '1' and perf_miss_i = '1' and
             RW_addr(31 downto 5) = tail_line + 1) then
            tail_next_miss <= '1';
         end if;
         if (tail = '1' and ram_done = '1') then
            tail_done <= '1';
         end if;
         if (tail = '1' and req_r = '1' and tail_q_ok = '0') then
            tail_held <= '1';
         elsif (tail = '0' or tail_q_ok = '1') then
            tail_held <= '0';
         end if;
         if (tail = '1' and (tail_done = '1' or ram_done = '1') and
             tail_arr_d = "1111") then
            tail      <= '0';
            tail_done <= '0';
            if (tail_ra_ok = '1' and tail_next_miss = '0' and ra_state /= RA_FLIGHT and
                chain_live = '0' and
                not (perf_miss_i = '1' and RW_addr(31 downto 5) = tail_line + 1)) then
               ra_state      <= RA_FLIGHT;
               ra_poison     <= '0';
               ra_line       <= tail_line + 1;
               ra_reqAddr    <= (tail_line + 1) & "00000";
               ra_reqStream  <= '0';
               ra_request    <= '1';
               perf_ra_issue <= '1';
            end if;
         end if;
         -- synthesis translate_off
         if (reset_2x = '0' and tail = '1' and fill_grant = '1') then
            report "cpu_datacache: a fill granted while the tail before it was still landing" severity failure;
         end if;
         if (reset_2x = '0' and tail = '1') then
            for w in 0 to 1 loop
               if (cache_we_w(w) = '1' and (w = 1) = (tail_way = '1') and
                   cache_address_b(IDX_HI - 3 downto 2) = std_logic_vector(tail_idx) and
                   tail_arr_1x(to_integer(unsigned(cache_address_b(1 downto 0)))) = '0') then
                  report "cpu_datacache: a store wrote a qword of the landing line before it came" severity failure;
               end if;
            end loop;
            if (state = IDLE and read_done = '1' and tail_hit = '1' and
                tail_arr_dd(to_integer(tag_addr_1(4 downto 3))) = '0') then
               report "cpu_datacache: a load answered from a qword of the landing line before it came" severity failure;
            end if;
         end if;
         -- synthesis translate_on

         if (reset_2x = '1') then
            state          <= CLEARCACHE;
            clearAddr      <= (others => '0');
            tail           <= '0';
            tail_done      <= '0';
            tail_held      <= '0';
            -- A read-ahead in flight when the reset came finishes during it,
            -- and cpu.vhd passes no completion on then, so none is in flight
            -- after it.
            ra_state       <= RA_NONE;
            ra_request     <= '0';
            chain_ok_r     <= '0';
            chain_fired    <= '0';
         else

            -- A fill asked for at the miss: its beats and completion while
            -- the victim is staged; FILL finds it done.
            if (fam_req_r = '1' and state /= FILL) then
               if (fill_done_mine = '1') then
                  fam_done_r <= '1';
               end if;
               if (ddr3_DOUT_READY = '1' and fill_active_1x = '1') then
                  fill_beat_seen <= '1';
               end if;
            end if;

            case(state) is

               when IDLE =>
                  writeMode      <= write_ena;
                  ff_miss_r      <= '0';
                  wb_hold_r      <= '0';
                  fam_req_r      <= '0';
                  fam_done_r     <= '0';
                  write_be_1     <= write_be_rot;
                  write_data_1   <= write_data_rot;
                  fillNext       <= '0';
                  -- The port did not read the next access's doubleword: a
                  -- store wrote through it, or the buffer drained. A store
                  -- that parks leaves it reading on.
                  ram_stale      <= sb_drain_idle or (write_ena and st_direct_a);
                  rd_low         <= RW_addr(2 downto 0);
                  fill_line_saved <= tag_addr_1(IDX_HI downto 5);
                  tag_addr_low   <= tag_addr_1(4 downto 0);
                  tag_read_addr  <= tag_addr_1(13 downto 0);
                  isCommand      <= '0';
                  allocNext      <= '0';
                  fillRA         <= '0';
                  ram_reqAddr    <= RW_addr(31 downto 0);
                  -- Across a 4 KB page: tag_addr_1 is this access's
                  -- virtual address, RW_addr its physical one.
                  ra_xpage       <= '0';
                  if (tag_addr_1(31 downto 29) = "100" and
                      RW_addr(18 downto 12) /= "1111111" and
                      (RW_addr(31 downto 19) = 0 or RW_addr(31 downto 23) = "000010000")) then
                     ra_xpage    <= '1';
                  end if;
                  -- Bits 4..3 name the fill's first qword: the access's
                  -- own, for a framebuffer line.
                  if (RW_fb = '1') then
                     fill_start  <= RW_addr(4 downto 3);
                  else
                     ram_reqAddr(4 downto 0) <= "00000";
                     fill_start  <= "00";
                  end if;
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
-- synthesis translate_off
                  alloc_part_1   <= store_part;
-- synthesis translate_on
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

                  elsif (tail_blk = '1') then
                     -- A qword of the landing line that is not in yet.
                     state <= TAIL_WAIT;

                  elsif ((read_ena = '1' or write_ena = '1') and read_hit = '0' and
                         line_hit = '1') then
                     -- The line is here but this qword is not: a load of it,
                     -- or a store that does not cover it. Fill the absent
                     -- qwords only - nothing is evicted, so nothing is written
                     -- back - and the line keeps its dirty bit.
                     state          <= FILL;
                     req_r    <= '1';
                     fill_beat_seen <= '0';
                     fill_mask      <= hit_absent;
                     fill_bytes     <= hit_bytes;
                     tag_data_cmd(21) <= hit_dirty or (write_ena and (not write_through_in));

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
                        if (RW_fb = '1' and skip_ok = '0') then
                           ff_miss_r   <= '1';
                           -- Ask for it now - a fill, not a read-ahead copy.
                           if (ra_match = '0' and
                               fifo_block = '0') then
                              req_r          <= '1';
                              fam_req_r      <= '1';
                              fill_beat_seen <= '0';
                           end if;
                        end if;
                        allocNext      <= skip_ok;
                        fillRA         <= ra_match and (not skip_ok);
                        -- Drop a read-ahead copy of the VICTIM now. A store to a
                        -- staged line normally drops it when the store reaches
                        -- the write FIFO (ra_store), and for a write-back that
                        -- is when cpu.vhd issues the staged line - which
                        -- can be after this cache has left for an
                        -- ALLOC and taken another miss. A load missing on the
                        -- victim then would be served, through FILLRA, the line
                        -- as it was before the bytes being written back. The
                        -- ordinary FILL is safe - it is held behind the
                        -- write-back.
                        if (ra_state /= RA_NONE and
                            ra_line = unsigned(tag_compare(19 downto TAG_LO)) & RW_addr(IDX_HI downto 5)) then
                           ra_poison <= '1';
-- synthesis translate_off
                           ra_vdrop  <= '1';
-- synthesis translate_on
                           if (ra_state /= RA_FLIGHT or ra_done = '1') then
                              ra_state <= RA_NONE;
                           end if;
                        end if;
                     elsif (skip_ok = '1') then
                        state          <= ALLOC;
                        tag_wren_cmd   <= '1';
                     elsif (ra_match = '1') then
                        -- The staged line: copy it in rather than ask the bridge.
                        state          <= FILLRA_WAIT;
                     else
                        state          <= FILL;
                        req_r    <= '1';
                        fill_beat_seen <= '0';
                     end if;

                  elsif (read_ena = '1' and read_hit = '1' and sb_same = '1') then
                     -- The buffered doubleword: answered here from the buffer
                     -- (sb_fwd) - and taken by no branch below, though
                     -- ram_stale may be set - or the buffer drains at this
                     -- edge and the load reads it back.
                     if (sb_fwd = '0') then
                        state     <= REREAD;
                        reread_wf <= '0';
                     end if;

                  elsif (ram_stale = '1' and read_ena = '1' and read_hit = '1') then
                     state <= READWAIT;
                     if (ce_fetch = '1') then
                        state     <= REREAD;
                        reread_wf <= '0';
                     end if;

                  elsif (read_ena = '1' and read_hit = '1' and fast_hit = '0') then
                     -- A hit, but in the way the prediction did not pick.
                     state <= WAYFIX;
                     if (ce_fetch = '1') then
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
                           if (line_hit = '1' and hit_dirty = '1') then
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
                  if (req_r = '1') then
                     tag_wren_cmd   <= '1';
                     tail_gnt_at    <= tail_gnt_d;
                  end if;
                  -- ddr3_DOUT_READY is SHARED with the instruction cache
                  -- (outside a direct fill, cpu.vhd feeds both from one
                  -- signal), so an unqualified
                  -- test sets this on the other cache's beats.
                  -- fill_active_1x is set by THIS cache's fill_grant, so it
                  -- qualifies the beat as ours.
                  if (ddr3_DOUT_READY = '1' and fill_active_1x = '1') then
                     fill_beat_seen <= '1';
                  end if;
                  if (fill_done_mine = '1' or fam_done_r = '1') then
                     state          <= IDLE;
                     -- A load's whole line is in: read the next one ahead.
                     if (writeMode = '0' and fill_mask = "1111" and
                         write_through_in = '0' and
                         ra_state /= RA_FLIGHT and ra_arm = '1' and
                         (ram_reqAddr(11 downto 5) /= "1111111" or
                          ra_xpage = '1')) then
                        ra_state      <= RA_FLIGHT;
                        ra_poison     <= '0';
                        ra_line       <= ram_reqAddr(31 downto 5) + 1;
                        ra_reqAddr    <= (ram_reqAddr(31 downto 5) + 1) & "00000";
                        ra_reqStream  <= '0';
                        ra_request    <= '1';
                        perf_ra_issue <= '1';
                     end if;
                  elsif (tail_go = '1') then
                     -- Answer now; the rest of the line lands behind.
                     state          <= TAIL_ANS;
                     tail           <= '1';
                     tail_done      <= '0';
                     tail_next_miss <= '0';
                     tail_idx       <= fill_line_saved;
                     tail_way       <= data_way;
                     tail_line      <= ram_reqAddr(31 downto 5);
                     tail_ra_ok     <= '0';
                     if (ra_arm = '1' and
                         (ram_reqAddr(11 downto 5) /= "1111111" or
                          ra_xpage = '1')) then
                        tail_ra_ok <= '1';
                     end if;
                  end if;

               -- The data RAMs read tag_read_addr, the access's own qword, as
               -- in every state but IDLE.
               when TAIL_ANS =>
                  state <= IDLE;

               when TAIL_WAIT =>
                  if (tail = '0' or
                      tail_arr_d(to_integer(tag_read_addr(4 downto 3))) = '1') then
                     if (writeMode = '1') then
                        state        <= TAIL_STORE;
                        tag_wren_cmd <= '1';
                     else
                        state        <= TAIL_ANS;
                     end if;
                  end if;

               -- One cycle, entered with tag_wren_cmd set: the store's tag
               -- rewrite and its data, as a store hit in IDLE writes them.
               when TAIL_STORE =>
                  state <= IDLE;

               when READWAIT =>
                  state <= IDLE;

               when UNUSED_4 =>
                  state <= IDLE;
                  
               when WRITEBACK1ADDR =>
                  -- A fill asked for at the miss was asked for as this state
                  -- was entered; its grant is judged from here, as from FILL's
                  -- first cycle. And the victim is staged at once: the queue
                  -- was empty at the miss and only this cache stages into it,
                  -- while the write FIFO now holds the fill's own request.
                  if (req_r = '1') then
                     tail_gnt_at <= tail_gnt_d;
                  end if;
                  -- The landing line is written back once it has landed.
                  if ((fifo_block = '0' or fam_req_r = '1') and
                      not (tail = '1' and
                           writeback_addr(31 downto 5) = tail_line)) then
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
                  -- The last word is staged this cycle: hold the line behind
                  -- the fill from now (see FILLING FIRST).
                  wb_hold_r      <= ff_miss_r;
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
                  -- waits, unless wb_hold keeps the staged line behind it
                  -- (FILLING FIRST); a later miss's write-back waits for the
                  -- queue in WRITEBACK1ADDR. A fill asked for at the miss
                  -- (fam_req_r) is not asked for again: only its tag is
                  -- written, as FILL writes it when it asks.
                  if (fifo_block = '0' or
                      (fillNext = '1' and allocNext = '1') or
                      (fillNext = '1' and ff_miss_r = '1')) then
                     fillNext <= '0';
                     if (fillNext = '1' and allocNext = '1') then
                        -- The victim is out; take the line without its fill.
                        state        <= ALLOC;
                        tag_wren_cmd <= '1';
                     elsif (fillNext = '1' and fillRA = '1') then
                        state        <= FILLRA_WAIT;
                     elsif (fillNext = '1' and fam_req_r = '1') then
                        state        <= FILL;
                        tag_wren_cmd <= '1';
                     elsif (fillNext = '1') then
                        state       <= FILL;
                        req_r <= '1';
                        -- The IDLE -> FILL path clears this, and so must
                        -- this one: left set from the previous fill, the
                        -- wait for the first beat of a fill that follows a
                        -- writeback is counted as perf_fill_hold and
                        -- perf_fill_wait reads 0.
                        -- Perf-only: nothing else reads fill_beat_seen.
                        fill_beat_seen <= '0';
                     else
                        state             <= IDLE;
                        CachecommandDone  <= isCommand;
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
                     -- starts, not when it ends: a stream
                     -- is held to the bridge's one line a round trip, and
                     -- asking at the end would spend these cycles outside
                     -- it. The staged copy the four COPY cycles read changes
                     -- only when the new read-ahead's data comes - its
                     -- completion, or the first qword of one that comes a
                     -- qword at a time - a round trip away (asserted).
                     -- Unless the line after has left already, as this line
                     -- landed; then it is staged as in flight, and nothing is
                     -- asked for.
                     if (chain_live = '1') then
                        ra_state      <= RA_FLIGHT;
                        ra_poison     <= chain_poison or chain_poison_now;
                        ra_line       <= chain_line;
                        ra_reqAddr    <= chain_line & "00000";
                        ra_reqStream  <= '1';
                        ra_request    <= '0';
                        perf_ra_issue <= '1';
                        chain_fired   <= '0';
                     elsif (writeMode = '0' and write_through_in = '0' and ra_arm = '1' and
                         (ram_reqAddr(11 downto 5) /= "1111111" or
                          ra_xpage = '1')) then
                        ra_state      <= RA_FLIGHT;
                        ra_poison     <= '0';
                        ra_line       <= ram_reqAddr(31 downto 5) + 1;
                        ra_reqAddr    <= (ram_reqAddr(31 downto 5) + 1) & "00000";
                        ra_reqStream  <= fillra_waited;
                        ra_request    <= '1';
                        perf_ra_issue <= '1';
                     end if;
                  elsif (ra_state = RA_NONE or ra_line /= ram_reqAddr(31 downto 5)) then
                     state          <= FILL;
                     req_r    <= '1';
                     fill_beat_seen <= '0';
                     -- This line was dropped as it landed, but the line
                     -- after had left: stage that one as in flight.
                     if (chain_live = '1') then
                        ra_state      <= RA_FLIGHT;
                        ra_poison     <= chain_poison or chain_poison_now;
                        ra_line       <= chain_line;
                        ra_reqAddr    <= chain_line & "00000";
                        ra_reqStream  <= '1';
                        ra_request    <= '0';
                        perf_ra_issue <= '1';
                        chain_fired   <= '0';
                     end if;
                  else
                     fillra_waited  <= '1';
                  end if;

               -- A qword a cycle into the victim's way, qword 0 first. The
               -- tag goes in with the first, as a fill's does. A load is
               -- answered in the last (ra_ans), and the cache is done.
               when FILLRA_COPY =>
                  if (tag_read_addr(4 downto 3) = "11") then
                     state                     <= FILLRA_DONE;
                     if (writeMode = '0') then
                        state                  <= IDLE;
                     end if;
                     tag_read_addr(4 downto 0) <= tag_addr_low;
                  else
                     tag_read_addr(4 downto 3) <= tag_read_addr(4 downto 3) + 1;
                  end if;

               -- A store lands its own data now; only a store comes here.
               when FILLRA_DONE =>
                  state <= IDLE;

            end case;

         end if;

      end if;
   end process;

end architecture;
