library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;   

library mem;
use work.pFunctions.all;
use work.pexport.all;

entity cpu is
   generic
   (
      LITTLE_ENDIAN         : boolean := false;
      -- The data cache reads the line after a load's line ahead, into a
      -- staging register a miss on it fills from. See cpu_datacache.vhd,
      -- "READING AHEAD". The request travels as a line fetch (bit 117) with
      -- bit 107 set, and clk1x captures its four qwords into line_fill_1x.
      DCACHE_READ_AHEAD     : boolean := false;
      -- And across a 4 KB page, for an unmapped load of low or main RAM; see
      -- cpu_datacache.vhd, "READING AHEAD". A line that is not SDRAM RAM - a
      -- framebuffer line - goes through the scheduler as any read-ahead of
      -- one does (fast_ra_line_ok).
      DCACHE_RA_CROSS_PAGE  : boolean := false;
      -- A 64-bit store that misses the data cache takes its line without
      -- reading it from SDRAM; the cache tracks which qwords it holds and
      -- fills the rest only if they are wanted. The heavy frames' store-miss
      -- fills are almost never read. See cpu_datacache.vhd, "SKIPPING THE
      -- STORE-MISS FILL".
      DCACHE_SKIP_FILL      : boolean := false;
      -- And a PARTIAL store to a framebuffer line, its written bytes tracked
      -- beside the tag. See cpu_datacache.vhd, "PARTIAL FRAMEBUFFER STORES".
      DCACHE_FB_PARTIAL     : boolean := false;
      -- A write-back followed by an ALLOC does not wait for the line to cross;
      -- see cpu_datacache.vhd's WB_EARLY.
      DCACHE_WB_EARLY       : boolean := false;
      -- The load-delay bubble only when the instruction behind the load reads
      -- the loaded register, as on the R4600; otherwise every load bubbles.
      -- See load_use.
      LOAD_INTERLOCK        : boolean := false;
      -- A store that hits parks in a one-entry buffer and is written to the
      -- data RAMs when the port is free; see cpu_datacache.vhd's STORE_BUFFER.
      DCACHE_STORE_BUFFER   : boolean := false;
      -- A load of the buffered doubleword is answered with the buffer's bytes
      -- merged in, rather than draining the buffer and re-reading; see
      -- cpu_datacache.vhd's SB_FORWARD. Needs DCACHE_STORE_BUFFER.
      DCACHE_SB_FORWARD     : boolean := false;
      -- A load miss is answered as soon as its own qword is in, the rest of
      -- the line landing while the CPU runs on, and a demand fill raised
      -- meanwhile may queue behind it on the direct fill path; see
      -- cpu_datacache.vhd's EARLY_RESTART and fast_go_q.
      DCACHE_EARLY_RESTART  : boolean := false;
      -- A load missing on the staged read-ahead line is answered in the
      -- copy's last cycle, from the staging register; see cpu_datacache.vhd's
      -- RA_ANSWER.
      DCACHE_RA_ANSWER      : boolean := false;
      -- A framebuffer line is filled from its access's qword, in sub-block
      -- order; see cpu_datacache.vhd's CWF_FB.
      DCACHE_CWF_FB         : boolean := false;
      -- A framebuffer miss with a dirty victim is filled before the victim is
      -- written back; see cpu_datacache.vhd's FILL_FIRST and wb_hold.
      DCACHE_FILL_FIRST     : boolean := false;
      -- With DCACHE_FILL_FIRST, that fill is asked for at the miss and the
      -- victim staged while it comes; see cpu_datacache.vhd's FILL_AT_MISS.
      DCACHE_FILL_AT_MISS   : boolean := false;
      -- An uncached load on the direct port completes on the edge its done
      -- is seen, the qword straight into mem_finished_dataRot: it is always
      -- qword-aligned, so the rotation's two stages have nothing to do.
      UNC_FAST_DONE         : boolean := false;
      -- In the cycle an uncached load in stage 4 completes, an uncached
      -- 64-bit load of SDRAM RAM waiting in stage 3 goes to the direct port
      -- on that edge, and is presented in stage 4 on the next. See
      -- fast_s3_go.
      UNC_LAUNCH_S3         : boolean := false;
      -- An uncached 64-bit load through the bridge completes on the edge its
      -- response is taken, the qword straight into mem_finished_dataRot: it
      -- is qword-aligned, so the rotation's two stages have nothing to do.
      UNC_BRIDGE_FAST_DONE  : boolean := false;
      -- The crossing to the bridge as a SYNCHRONOUS 2:1 handshake: clk1x reads
      -- the mailbox's request, and clk93 its acknowledge, the write-back line
      -- release and the response FIFO's write pointer, straight from the
      -- other domain's register instead of through two synchroniser flops. The
      -- handshakes themselves do not change. Sound only when clk1x and clk93
      -- are phase-aligned outputs of one PLL at an integer ratio AND the SDC
      -- times the paths between them - see KillerInstinct.sdc and "THE
      -- CROSSING" below.
      SYNC_CROSSING         : boolean := false;
      -- An LWL, LWR, LDL or LDR straight behind a load of its rt register
      -- takes no load-delay bubble, as on the R4600, and merges into that
      -- load's result in stage 4. Needs LOAD_INTERLOCK. See merge_bypass.
      LOAD_MERGE_BYPASS     : boolean := false;
      -- The instruction behind a load takes the load-delay bubble for its rt
      -- field only when it reads rt as a general register: the R4600
      -- interlocks only on a use of the loaded register. One that writes rt,
      -- or uses the field as a function or an FPU register, follows a load
      -- into that register back to back. Needs LOAD_INTERLOCK. See
      -- dec_reads_rt.
      LOAD_RT_EXACT         : boolean := false;
      -- An FPU ADD or SUB with no cancellation rounds a cycle sooner; see
      -- cpu_FPU's ADD_FAST_NORM.
      FPU_ADD_FAST          : boolean := false;
      -- An instruction waiting on an FPU result takes it in the FPU's done
      -- cycle and issues the next, as on the R4600; see FPU_fwd_valid.
      FPU_FORWARD           : boolean := false;
      -- A clean data-cache demand miss, the cache's read-ahead line fetch and
      -- an uncached 64-bit load of SDRAM RAM ask ki_sdram_burst's second port
      -- straight from clk93 when nothing of the CPU's is in the bridge's
      -- path; see fast_go.
      -- Needs SYNC_CROSSING: the test reads clk1x's state across its timed
      -- 2:1 crossing.
      DIRECT_FILL           : boolean := false;
      -- With DIRECT_FILL, the read-ahead's line fetch may take the direct
      -- port on the edge after the data cache asks for it, from the ask
      -- itself, not a cycle later from datacache_ra_pending; see fast_ra_go.
      RA_LAUNCH_EARLY       : boolean := false;
      -- With DIRECT_FILL, a direct read-ahead's line comes back a qword at a
      -- time on fast_ra_valid, on the controller's clock, as an uncached
      -- qword does on fast_unc_valid: its request carries bit 1 of the line
      -- address set (ki_fast_fill), each qword goes into datacache_ra_data as
      -- it comes, and the fourth completes it. See fast_ra_ret.
      RA_CTL_RETURN         : boolean := false;
      -- With DIRECT_FILL, the read-ahead of the line after the one the data
      -- cache waits for in FILLRA_WAIT leaves on the direct port as that one
      -- completes, not from the cache's ask as the copy starts: 1, on the
      -- edge after its completion registers; 2, on that edge. See
      -- fast_chain_term.
      RA_CHAIN              : integer := 0;
      -- Narrow the COP0 exception-address capture to the 32-bit KI contract.
      ADDR32_ONLY           : boolean := false;
      -- Drop trap instructions from the exception logic while retaining the
      -- comparator used by SLT/SLTU.
      NO_TRAP_INSTR         : boolean := false;
      -- KI instruction fetches use the unmapped KSEG0/KSEG1 path. The data TLB
      -- remains enabled for mapped data accesses.
      INSTR_KSEG_ONLY       : boolean := false;
      -- cvt.s.l and cvt.d.l of a value outside +-2^55 take an Unimplemented
      -- Operation trap instead of converting; see cpu_FPU's CVT_L_NARROW.
      FPU_CVT_L_NARROW      : boolean := false
   );
   port 
   (
      clk1x                 : in  std_logic;
      clk93                 : in  std_logic;
      ce_1x                 : in  std_logic;
      ce_93                 : in  std_logic;
      reset_1x              : in  std_logic;
      reset_93              : in  std_logic;
      preNMI                : in  std_logic;
      
      INSTRCACHEON          : in  std_logic;
      DATACACHEON           : in  std_logic;
      DATACACHESLOW         : in  std_logic_vector(3 downto 0); 
      DATACACHEFORCEWEB     : in  std_logic;
      DATACACHEWRITETHROUGH : in  std_logic := '0';
      DATACACHETLBON        : in  std_logic;
      RANDOMMISS            : in  unsigned(3 downto 0);
      DISABLE_BOOTCOUNT     : in  std_logic;
      DISABLE_DTLBMINI      : in  std_logic;
      ALECK64               : in  std_logic;

      irqRequest            : in  std_logic_vector(1 downto 0);
      cpuPaused             : in  std_logic;
      
      error_instr           : out std_logic := '0';
      error_stall           : out std_logic := '0';
      error_FPU             : out std_logic := '0';
      error_exception       : out std_logic := '0';
      error_fifo            : out std_logic := '0';
      error_TLB             : out std_logic := '0';
      debug_fetch_pc        : out std_logic_vector(31 downto 0) := (others => '0');
      debug_retired         : out std_logic_vector(31 downto 0) := (others => '0');
      -- The PC and opcode of the instruction retiring this cycle, in
      -- simulation only; in hardware they stay zero.
      debug_retire_pc       : out std_logic_vector(31 downto 0) := (others => '0');
      debug_retire_opcode   : out std_logic_vector(31 downto 0) := (others => '0');
      -- Live COP0 Status/Cause, packed as cpu_cop0 packs it, and EPC: readable
      -- the cycle after an exception is taken.
      debug_cop0_cause_live   : out std_logic_vector(31 downto 0) := (others => '0');
      debug_cop0_epc_live     : out std_logic_vector(31 downto 0) := (others => '0');
      -- Raw per-cycle causes of lost cycles, for measuring the CPU. Nothing in
      -- the design reads this bus, so synthesis prunes all of it, the
      -- perf-only registers included.
      --
      -- THE LOST-CYCLE CENSUS. An instruction retires in a cycle where
      -- stall4Masked = 0 and writebackNew = 1. Every other cycle is lost, and
      -- bits 0, 2 and 6-9 give each lost cycle exactly one cause, so
      -- CY - RT = S4 + MD + S3 + S1 + LB + FL, less paused cycles. FL has no
      -- bit here (see perf_lost_fl), so a sum of the bits holds to within FL:
      --
      --   0 a D-cache miss (a COUNT, not a cycle)                MC
      --   1 stall4, uncached STORE (part of S4)                 UW
      --   2 stall4: stage 4 waiting on memory                   S4
      --   3 stall4, uncached FB load (part of S4)               UF
      --   4 stall4, other uncached load (part of S4)            UO
      --   5 stall4, CACHED access (part of S4)                  DC
      --   6 stall3 frozen on a multiply or divide               MD
      --   7 stall3 frozen on anything else (FPU, TLB)           S3
      --   8 stall1 or stall2: fetch waiting (instruction cache) S1
      --   9 a load: stall3 held for it, or the empty slot it left LB
      --  10 a D-cache miss below 0x0008_0000 (a COUNT)           LM
      --  11 a load whose bubble could be recovered              DI
      --
      -- (This table is the only description of the
      -- bus in one place, so keep it true.)
      --
      -- S4 = DC + UW + UF + UO: UO is I/O (the disk's data port
      -- among it), boot ROM and RAM through KSEG1.
      --
      -- Stages 1-3 advance only when the whole stall vector is zero, so a
      -- fetch stall or a multiply freezes the pipeline and costs exactly its
      -- own cycles: those classes are read straight off the stall bits, in
      -- priority S4, stall3, stall1. Stage 4 advances on stall4Masked, which
      -- ignores the stall3 a load raises, so stage 3 can hand it an EMPTY
      -- slot - and an empty slot retires nothing when it reaches the end. A
      -- load's slot is tagged where it is made (perf_ex_ld, perf_wb_ld) and
      -- the tag travels with it, so LB charges the load rather than the stage
      -- where the loss shows. Every other empty slot is FL. ("Stage 1 had
      -- nothing ready" occurs only in the empty pipeline out of reset.)
      --
      -- DI is not a lost cycle but a COUNT, of the lost cycles that removing
      -- the load-delay bubble could give back: a cached load that hit in the
      -- predicted way - so its bubble is the only cost it paid - and whose
      -- next instruction does not use the value, so it need not have waited.
      -- The comparison is the one the forwarding decision already makes
      -- (resultTarget against decodeSource1/2, the instruction behind the load
      -- while the load is in stage 4). A load that misses is excluded: the
      -- pipeline is stalled on the miss anyway.
      -- With LOAD_INTERLOCK, only a load that TOOK its bubble counts, so DI
      -- reads what the dependency test failed to give back.
      --
      -- The data cache's perf_* taps are computed for simulation too;
      -- synthesis drops them with nothing reading them.
      --
      -- The classes partition the cycles: each running cycle retires or is
      -- lost to exactly one class, so together they sum to the total. Keep it
      -- that way.
      debug_perf_events       : out std_logic_vector(11 downto 0);

      mem_request           : out std_logic := '0';
      mem_rnw               : out std_logic := '0'; 
      mem_address           : buffer unsigned(31 downto 0) := (others => '0'); 
      mem_req64             : out std_logic := '0'; 
      mem_size              : out unsigned(2 downto 0) := (others => '0');
      mem_writeMask         : out std_logic_vector(7 downto 0) := (others => '0'); 
      mem_dataWrite         : out std_logic_vector(63 downto 0) := (others => '0');
      -- A dirty cache line as ONE transaction: its four 64-bit words, valid
      -- with mem_request while mem_line_write is high, for the bridge to send
      -- as a single 16-word burst.
      --
      -- As four separate transactions the line would cross the write CDC four
      -- times, with the fill's own request queued behind all four.
      -- mem_writeMask(3 downto 0) is which qwords to write, bit
      -- i for the qword at offset 8i: a line whose store-miss fill was skipped
      -- holds nothing for the qwords it never stored.
      mem_line_write        : out std_logic := '0';
      -- The read is the data cache's read-ahead line fetch (a line fetch the
      -- cache staged, not one a miss asked for), valid with mem_request. The
      -- bridge reads a framebuffer line for it at a word per two cycles.
      mem_line_ra           : out std_logic := '0';
      mem_line_data         : out std_logic_vector(255 downto 0) := (others => '0');
      -- Which BYTES of mem_line_data to write, bit 8i+j for byte j of qword
      -- i, valid with it. Every byte of a qword mem_writeMask names, except
      -- in a framebuffer line with partially stored qwords (DCACHE_FB_PARTIAL).
      mem_line_bytes        : out std_logic_vector(31 downto 0) := (others => '1');
      mem_dataRead          : in  std_logic_vector(63 downto 0); 
      mem_done              : in  std_logic;
      rdram_granted2x       : in  std_logic;
      rdram_done            : in  std_logic;
      ddr3_DOUT             : in  std_logic_vector(63 downto 0);
      ddr3_DOUT_READY       : in  std_logic;
      -- The direct fill path (DIRECT_FILL); see fast_go and ki_fast_fill.sv.
      -- fast_ok is the bridge's: nothing of the CPU's that touches SDRAM in
      -- flight or held there. A request is a toggle with the line's physical
      -- address beside it; the line comes back as four beats on clk1x and a
      -- done toggle. An uncached qword comes back either as one beat and a
      -- done toggle, or on fast_unc_valid (ki_fast_fill's UNC_CTL_RETURN):
      -- fast_unc_qword for one cycle of the controller's clock, which has
      -- this one's frequency on the same PLL, so this clock takes it once.
      -- With RA_CTL_RETURN a read-ahead's line comes back the same way, its
      -- four qwords on fast_unc_qword while fast_ra_valid is high.
      fast_ok               : in  std_logic := '0';
      fast_req_tog          : out std_logic := '0';
      fast_req_line         : out std_logic_vector(31 downto 0) := (others => '0');
      -- The line read is the data cache's read-ahead of a stream (its
      -- ra_reqStream); ki_sdram_burst's RA_ROW_HOLD. Changes with the toggle.
      fast_req_stream       : out std_logic := '0';
      fast_window           : in  std_logic := '0';
      fast_beat             : in  std_logic := '0';
      fast_first            : in  std_logic := '0';
      fast_qword            : in  std_logic_vector(63 downto 0) := (others => '0');
      fast_done_tog         : in  std_logic := '0';
      fast_unc_valid        : in  std_logic := '0';
      fast_unc_qword        : in  std_logic_vector(63 downto 0) := (others => '0');
      fast_ra_valid         : in  std_logic := '0';
      
      ram_done              : in  std_logic;
      ram_rnw               : in  std_logic;
      ram_dataRead          : in  std_logic_vector(31 downto 0); 
      
-- synthesis translate_off
      cpu_done              : out std_logic := '0'; 
      cpu_export            : out cpu_export_type := export_init;
-- synthesis translate_on
      
      SS_reset              : in  std_logic;
      loading_savestate     : in  std_logic;
      SS_DataWrite          : in  std_logic_vector(63 downto 0);
      SS_Adr                : in  unsigned(11 downto 0);
      SS_wren_CPU           : in  std_logic;
      SS_rden_CPU           : in  std_logic;
      SS_DataRead_CPU       : out std_logic_vector(63 downto 0);
      SS_idle               : out std_logic
   );
end entity;

architecture arch of cpu is

   constant FB0_LOW  : unsigned(31 downto 0) := x"00030000";
   constant FB0_HIGH : unsigned(31 downto 0) := x"00055800";
   constant FB1_LOW  : unsigned(31 downto 0) := x"00058000";
   constant FB1_HIGH : unsigned(31 downto 0) := x"0007D800";
   -- SDRAM RAM as ki_board_pkg places it: low RAM outside the framebuffer
   -- windows above, and main RAM with its alias.
   constant LOW_RAM_LAST    : unsigned(31 downto 0) := x"0007FFFF";
   constant MAIN_RAM_BASE   : unsigned(31 downto 0) := x"08000000";
   constant MAIN_ALIAS_LAST : unsigned(31 downto 0) := x"088FFFFF";
   constant FAST_ON         : boolean := DIRECT_FILL and SYNC_CROSSING;

   -- A line of SDRAM RAM: one the direct fill path may fetch.
   function is_sdram_line(line : unsigned(31 downto 0)) return std_logic is
   begin
      if (line < FB0_LOW or
          (line >= FB0_HIGH and line < FB1_LOW) or
          (line >= FB1_HIGH and line <= LOW_RAM_LAST) or
          (line >= MAIN_RAM_BASE and line <= MAIN_ALIAS_LAST)) then
         return '1';
      end if;
      return '0';
   end function;

   function is_fb_line(line : unsigned(31 downto 0)) return std_logic is
   begin
      if ((line >= FB0_LOW and line < FB0_HIGH) or
          (line >= FB1_LOW and line < FB1_HIGH)) then
         return '1';
      end if;
      return '0';
   end function;

   function bus_to_cpu16(inval : std_logic_vector(15 downto 0)) return unsigned is
   begin
      if LITTLE_ENDIAN then return unsigned(inval); end if;
      return byteswap16(unsigned(inval));
   end function;

   function bus_to_cpu32(inval : std_logic_vector(31 downto 0)) return unsigned is
   begin
      if LITTLE_ENDIAN then return unsigned(inval); end if;
      return byteswap32(unsigned(inval));
   end function;

   function bus_to_cpu64(inval : std_logic_vector(63 downto 0)) return unsigned is
      variable result : unsigned(63 downto 0);
   begin
      if LITTLE_ENDIAN then return unsigned(inval); end if;
      result(63 downto 32) := unsigned(byteswap32(inval(31 downto 0)));
      result(31 downto 0)  := unsigned(byteswap32(inval(63 downto 32)));
      return result;
   end function;

   function cpu_to_bus16(inval : unsigned(15 downto 0)) return unsigned is
   begin
      if LITTLE_ENDIAN then return inval; end if;
      return byteswap16(inval);
   end function;

   function cpu_to_bus32(inval : unsigned(31 downto 0)) return unsigned is
   begin
      if LITTLE_ENDIAN then return inval; end if;
      return byteswap32(inval);
   end function;

   function cpu_to_bus64(inval : unsigned(63 downto 0)) return unsigned is
      variable result : unsigned(63 downto 0);
   begin
      if LITTLE_ENDIAN then return inval; end if;
      result(63 downto 32) := byteswap32(inval(63 downto 32));
      result(31 downto 0)  := byteswap32(inval(31 downto 0));
      return result;
   end function;

   function merge_left32(data : unsigned(31 downto 0); olddata : unsigned(31 downto 0);
                         offset : unsigned(1 downto 0)) return unsigned is
      variable result : unsigned(31 downto 0) := olddata;
      variable index  : integer := to_integer(offset);
   begin
      if LITTLE_ENDIAN then index := 3 - index; end if;
      case index is
         when 3 => result(31 downto 24) := data(7 downto 0);
         when 2 => result(31 downto 16) := data(15 downto 0);
         when 1 => result(31 downto 8)  := data(23 downto 0);
         when 0 => result := data;
         when others => null;
      end case;
      return result;
   end function;

   function merge_right32(data : unsigned(31 downto 0); olddata : unsigned(31 downto 0);
                          offset : unsigned(1 downto 0)) return unsigned is
      variable result : unsigned(31 downto 0) := olddata;
      variable index  : integer := to_integer(offset);
   begin
      if LITTLE_ENDIAN then index := 3 - index; end if;
      case index is
         when 3 => result := data;
         when 2 => result(23 downto 0) := data(31 downto 8);
         when 1 => result(15 downto 0) := data(31 downto 16);
         when 0 => result(7 downto 0)  := data(31 downto 24);
         when others => null;
      end case;
      return result;
   end function;

   function merge_left64(data : unsigned(63 downto 0); olddata : unsigned(63 downto 0);
                         offset : unsigned(2 downto 0)) return unsigned is
      variable result : unsigned(63 downto 0) := olddata;
      variable index  : integer := to_integer(offset);
   begin
      if LITTLE_ENDIAN then index := 7 - index; end if;
      case index is
         when 7 => result(63 downto 56) := data(7 downto 0);
         when 6 => result(63 downto 48) := data(15 downto 0);
         when 5 => result(63 downto 40) := data(23 downto 0);
         when 4 => result(63 downto 32) := data(31 downto 0);
         when 3 => result(63 downto 24) := data(39 downto 0);
         when 2 => result(63 downto 16) := data(47 downto 0);
         when 1 => result(63 downto 8)  := data(55 downto 0);
         when 0 => result := data;
         when others => null;
      end case;
      return result;
   end function;

   function merge_right64(data : unsigned(63 downto 0); olddata : unsigned(63 downto 0);
                          offset : unsigned(2 downto 0)) return unsigned is
      variable result : unsigned(63 downto 0) := olddata;
      variable index  : integer := to_integer(offset);
   begin
      if LITTLE_ENDIAN then index := 7 - index; end if;
      case index is
         when 7 => result := data;
         when 6 => result(55 downto 0) := data(63 downto 8);
         when 5 => result(47 downto 0) := data(63 downto 16);
         when 4 => result(39 downto 0) := data(63 downto 24);
         when 3 => result(31 downto 0) := data(63 downto 32);
         when 2 => result(23 downto 0) := data(63 downto 40);
         when 1 => result(15 downto 0) := data(63 downto 48);
         when 0 => result(7 downto 0)  := data(63 downto 56);
         when others => null;
      end case;
      return result;
   end function;
     
   -- register file
   signal regs_address_a               : std_logic_vector(4 downto 0);
   signal regs_data_a                  : std_logic_vector(63 downto 0);
   signal regs_wren_a                  : std_logic;
   signal regs1_address_b              : std_logic_vector(4 downto 0);
   signal regs1_q_b                    : std_logic_vector(63 downto 0);
   signal regs2_address_b              : std_logic_vector(4 downto 0);
   signal regs2_q_b                    : std_logic_vector(63 downto 0);  

   -- FPU register file
   signal FPUregs_address_a            : std_logic_vector(4 downto 0);
   signal FPUregs_data_a               : std_logic_vector(63 downto 0);
   signal FPUregs_wren_a               : std_logic_vector(1 downto 0);
   signal FPUregs1_address_b           : std_logic_vector(4 downto 0);
   signal FPUregs1_q_b                 : std_logic_vector(63 downto 0);
   signal FPUregs2_address_b           : std_logic_vector(4 downto 0);
   signal FPUregs2_q_b                 : std_logic_vector(63 downto 0);  

   signal FPUWriteTarget               : unsigned(4 downto 0) := (others => '0');
   signal FPUWriteData                 : unsigned(63 downto 0) := (others => '0');
   signal FPUWriteEnable               : std_logic := '0';   
   signal FPUWriteMask                 : std_logic_vector(1 downto 0) := (others => '0');
   
   -- other register
   signal PC                           : unsigned(63 downto 0) := (others => '0');
   signal debug_fetch_pc_register      : std_logic_vector(31 downto 0) := (others => '0');
   signal debug_retired_count          : unsigned(31 downto 0) := (others => '0');
   signal debug_retire_pc_register     : std_logic_vector(31 downto 0) := (others => '0');
   signal debug_retire_opcode_register : std_logic_vector(31 downto 0) := (others => '0');
   signal cop0_debug_cause             : unsigned(31 downto 0);
   signal cop0_debug_epc               : unsigned(31 downto 0);

   -- decodeNewPulse is high for exactly the cycle in which pcOld1/opcode1
   -- hold a newly decoded pair. decodeNew is only WRITTEN when stall = 0, so
   -- it stays asserted for the whole of a stall, and logic gated on it would
   -- see one decode many times.
   signal decodeNewPulse               : std_logic := '0';
   -- A genuine delay slot SEQUENTIALLY FOLLOWS its branch. A branch target
   -- does not. That one test separates them, and it needs no opcode decoding.
   --
   -- When a branch sits in another branch's delay slot the hardware marks the
   -- first branch's TARGET as a delay slot too, and cop0 records
   -- EPC = target - 4: the interrupt is recognised with PCold1 = the target
   -- and executeBranchdelaySlot = 1. eret then resumes at target - 4 and
   -- falls THROUGH the target instead of entering it via the branch. That is
   -- the KI FMV restart.
   --
   -- ds_prev_pc advances on decodeNewPulse, one pulse per genuinely new
   -- decode, so it is aligned with PCold1 - which is exactly what cop0 pairs
   -- with isDelaySlot when it computes nextEPC.
   signal ds_prev_pc                   : unsigned(31 downto 0) := (others => '0');
   signal ds_prev_isbranch             : std_logic := '0';

   -- Does this opcode have a delay slot?
   function opcodeIsBranch(op : unsigned(31 downto 0)) return std_logic is
      variable o : unsigned(5 downto 0);
      variable f : unsigned(5 downto 0);
   begin
      o := op(31 downto 26);
      f := op(5 downto 0);
      if (o = 6x"01") then return '1'; end if;                  -- REGIMM
      if (o = 6x"02" or o = 6x"03") then return '1'; end if;    -- j, jal
      if (o >= 6x"04" and o <= 6x"07") then return '1'; end if; -- beq..bgtz
      if (o >= 6x"14" and o <= 6x"17") then return '1'; end if; -- the l variants
      if (o = 6x"00" and (f = 6x"08" or f = 6x"09")) then return '1'; end if; -- jr, jalr
      if ((o = 6x"10" or o = 6x"11" or o = 6x"12") and op(25 downto 21) = 5x"08") then
         return '1';                                            -- BC0/1/2
      end if;
      return '0';
   end function;
   signal chainedDelaySlot             : std_logic := '0';
   signal hi                           : unsigned(63 downto 0) := (others => '0');
   signal lo                           : unsigned(63 downto 0) := (others => '0');
          
   -- memory interface
   signal memoryMuxStage4              : std_logic := '0';
   signal mem1_request_latched         : std_logic := '0';
   signal mem1_cache_latched           : std_logic := '0';
   signal mem1_address_latched         : unsigned(31 downto 0) := (others => '0');
   signal datacache_request_latched    : std_logic := '0';
   signal datacache_address_latched    : unsigned(31 downto 0) := (others => '0');
   
   signal mem_finished_instr           : std_logic := '0';
   signal mem_finished_read            : std_logic := '0';
   signal mem_finished_dataRead        : std_logic_vector(63 downto 0);
          
   signal writefifo_Din                : std_logic_vector(117 downto 0) := (others => '0');
   signal writefifo_wr                 : std_logic := '0';
   signal writefifo_Dout               : std_logic_vector(117 downto 0);
   signal writefifo_Rd                 : std_logic := '0';
   signal writefifo_Empty              : std_logic;
   signal writefifo_Full               : std_logic;
   signal writefifo_wr_accept          : std_logic;
   signal writefifo_bypass             : std_logic;
   signal writefifo_fifo_wr            : std_logic;
   signal writefifo_rd_accept          : std_logic;
   signal writefifo_schedule_ready     : std_logic;
   signal writefifo_block              : std_logic;
   signal writefifo_mem4_ready         : std_logic;
   signal writefifo_cnt                : integer range 0 to 7;
   type t_datacache_wb_fifo is array (0 to 3) of std_logic_vector(95 downto 0);
   signal datacache_wb_fifo            : t_datacache_wb_fifo :=
                                           (others => (others => '0'));
   signal datacache_wb_fifo_wrptr      : unsigned(1 downto 0) := (others => '0');
   signal datacache_wb_fifo_count      : integer range 0 to 4 := 0;
   signal writefifo_issue_pending      : std_logic := '0';
   signal writefifo_issue_wb           : std_logic := '0';
   -- A whole-line write-back leaves its four words in the staging queue for
   -- the clk1x side to read, so the queue may only be released once that side
   -- has handed them to the bridge. Toggle in clk1x, read in clk93 through two
   -- flops or, under SYNC_CROSSING, directly - the same bundled-data
   -- discipline as the write mailbox below.
   signal wb_line_done_1x              : std_logic := '0';
   signal wb_line_done_meta_93         : std_logic := '0';
   signal wb_line_done_sync_93         : std_logic := '0';
   signal wb_line_done_seen_93         : std_logic := '0';
   signal wb_line_release              : std_logic;
   -- The line's one transaction has been accepted by the write FIFO but its
   -- words are still held for clk1x. The fill's request must be free to follow
   -- it immediately - queueing behind the release is the serialization the
   -- one-transaction line exists to remove - so this marks "issued, do not
   -- re-issue" without blocking the scheduler.
   signal wb_line_issued               : std_logic := '0';
   signal datacache_wb_busy            : std_logic;
   -- The part of datacache_wb_busy during which the write-back still OWNS the
   -- scheduler: words being staged, the whole line staged but not yet issued,
   -- or its issue pending. See the request-preserving blocks.
   signal datacache_wb_sched           : std_logic;
   signal datacache_debug_state        : std_logic_vector(4 downto 0);
          
   -- The transaction FIFO belongs entirely to clk93.  Transfer its wide
   -- payload to clk1x through a bundled-data request/acknowledge mailbox so
   -- address, data and control bits can never be sampled from different FIFO
   -- entries, whatever the two clocks' phase.
   signal write_cdc_data_93            : std_logic_vector(117 downto 0) := (others => '0');
   signal write_cdc_req_93             : std_logic := '0';
   signal write_cdc_busy_93            : std_logic := '0';
   signal write_cdc_ack_1x             : std_logic := '0';
   signal write_cdc_ack_meta_93        : std_logic := '0';
   signal write_cdc_ack_sync_93        : std_logic := '0';
   signal write_cdc_req_meta_1x        : std_logic := '0';
   signal write_cdc_req_sync_1x        : std_logic := '0';
   signal write_cdc_req_seen_1x        : std_logic := '0';
   -- THE CROSSING. What each side acts on: the other side's register itself
   -- under SYNC_CROSSING, its synchroniser's output otherwise.
   --
   -- Everything these expose is bundled data, and the rule that makes that
   -- safe is the same in both modes: the data a flag exposes is written no
   -- later than the flag, and holds until the flag's answer comes back. The
   -- synchronisers only ever ADDED margin to it. Under SYNC_CROSSING the
   -- margin is one clock edge, and timing analysis, not a flop count, is what
   -- guarantees the data has arrived:
   --   - write_cdc_data_93 is loaded on the edge that toggles
   --     write_cdc_req_93, and holds until the acknowledge returns;
   --   - the write-back line's words sit in datacache_wb_fifo from before its
   --     request is issued until wb_line_done_1x releases them, and clk1x
   --     copies them into mem_line_data on the edge that toggles it;
   --   - a response's payload is written into the FIFO on the edge that
   --     advances its write pointer;
   --   - line_fill_1x's last beat is captured no later than mem_done, the
   --     edge the completion enters the FIFO, and clk93 copies it on the
   --     edge it takes that completion - which is also the edge clk1x's next
   --     line fetch waits for (resp_fifo_wempty);
   --   - a fill's last beat is written no later than mem_done, and clk93
   --     reads it no sooner than the next clk1x edge: the instruction cache
   --     a cycle after the completion's take, the data cache through
   --     datacache_fill_due when its access is to that qword.
   signal write_cdc_req_in_1x          : std_logic;
   signal write_cdc_ack_in_93          : std_logic;
   signal wb_line_done_in_93           : std_logic;

   -- Read responses from the memory clock domain to the CPU clock domain,
   -- through a DUAL-CLOCK FIFO (cpu_cdc_fifo.vhd).
   --
   -- Unlike a one-transaction mailbox, it does not make the bridge wait for
   -- an acknowledge to cross back before it starts the NEXT transaction,
   -- although nothing is waiting on that acknowledge - the CPU has already
   -- taken the data. That matters only when there IS a next transaction:
   -- not on a clean miss, where the CPU is stalled on the fill and has
   -- nothing else to ask for, but on a dirty one, where the victim's
   -- write-back follows the previous fill straight down the same path.
   --
   -- Two entries is enough: the consumer below takes a response in a handful
   -- of clk93 cycles and a bridge transaction is tens of them, so the bridge
   -- never sees the FIFO full.
   --
   -- Bit 105 marks the completion of a LINE fetch - the data cache's
   -- read-ahead - whose data is in line_fill_1x rather than this payload.
   -- Bit 106 marks the completion of a DATA CACHE fill, whose data went into
   -- the cache as beats. It completes to the cache alone (datacache_fill_done),
   -- never to stage 4: a fill need not be the only data transaction
   -- outstanding once the cache can read ahead in the background, and an
   -- uncached load waiting in stage 4 must not take a fill's completion as its
   -- own.
   signal resp_fifo_din                : std_logic_vector(106 downto 0);
   signal resp_fifo_wr                 : std_logic;
   signal resp_fifo_full               : std_logic;
   -- '1' when clk93 has consumed every response written. The one thing the
   -- deeper crossing has to be told: line_fill_1x is a SINGLE buffer in
   -- clk1x that a line fetch overwrites, and its completion does not
   -- acknowledge before the next transaction may start. So clk1x refuses to
   -- take another LINE fetch until this reads '1'. It never actually delays
   -- one - clk93 cannot even build the next line request until it has
   -- consumed the previous completion - but it makes that a local rule of
   -- this crossing rather than an argument about the whole design.
   signal resp_fifo_wempty             : std_logic;
   signal resp_fifo_dout               : std_logic_vector(106 downto 0);
   signal resp_fifo_rd                 : std_logic;
   signal resp_fifo_empty              : std_logic;
   -- The one cycle in which clk93 takes the head of that FIFO. Used as the
   -- FIFO's read strobe AND as the scoreboard's pop, so the two can never
   -- disagree about which cycle a response was consumed in.
   signal resp_take                    : std_logic;
   signal response_cdc_pending_93      : std_logic := '0';
   signal response_cdc_deliver_93      : std_logic := '0';
   -- The data cache's own completion; see bit 106 above. Its ram_done.
   signal datacache_fill_done          : std_logic := '0';
   signal datacache_fill_due           : std_logic := '0';
   signal datacache_fill_last          : std_logic;
   -- The staged write-back waits behind its miss's fill (DCACHE_FILL_FIRST).
   signal datacache_wb_hold            : std_logic;

   -- Independent clk93-domain ownership scoreboard. The main transaction
   -- FIFO carries a sequence tag to clk1x and back; this queue records what
   -- was accepted before that CDC path, so a lost, duplicated, reordered or
   -- misclassified response cannot validate itself with its own metadata.
   type t_read_meta_tag is array (0 to 15) of std_logic_vector(7 downto 0);
   type t_read_meta_class is array (0 to 15) of std_logic;
   type t_read_meta_address is array (0 to 15) of std_logic_vector(31 downto 0);
   signal read_meta_tag               : t_read_meta_tag := (others => (others => '0'));
   signal read_meta_class             : t_read_meta_class := (others => '0');
   signal read_meta_address           : t_read_meta_address := (others => (others => '0'));
   signal read_meta_wrptr             : unsigned(3 downto 0) := (others => '0');
   signal read_meta_rdptr             : unsigned(3 downto 0) := (others => '0');
   signal read_meta_count             : integer range 0 to 16 := 0;
   signal read_sequence_93            : unsigned(7 downto 0) := (others => '0');
   signal read_meta_push              : std_logic;
   signal read_meta_pop               : std_logic;
   signal read_meta_tag_mismatch      : std_logic;
   signal read_meta_class_mismatch    : std_logic;
   signal read_meta_address_mismatch  : std_logic;
   signal debug_response_status_reg   : std_logic_vector(31 downto 0) := (others => '0');

   -- Active clk1x transaction metadata is registered with the bus command,
   -- then held until mem_done builds the response mailbox payload.
   signal memory_read_tag_1x          : std_logic_vector(7 downto 0) := (others => '0');
   signal memory_read_address_1x      : std_logic_vector(31 downto 0) := (others => '0');

   constant DCRA_ON : boolean := DCACHE_READ_AHEAD;
   -- NS: one pulse per uncached store to SDRAM that does not write every
   -- byte of the words it covers - an sh, an sb, or a partial sdl/sdr. The
   -- board ignores DQM, so ki_memory_bridge reads, merges and writes those
   -- back rather than masking.
   signal perf_uc_narrow              : std_logic;
   -- clk1x side of a line fetch - the data cache's read-ahead. Written only
   -- while its own transaction is outstanding, and read in clk93 only when
   -- that transaction's completion has crossed the response mailbox: bundled
   -- data, like the mailbox itself.
   signal line_active_1x              : std_logic := '0';
   signal line_beat_1x                : unsigned(1 downto 0) := (others => '0');
   signal line_fill_1x                : std_logic_vector(255 downto 0) := (others => '0');
   signal executeMemFB                : std_logic;
          
   -- common   
   type t_memstate is
   (
      MEMSTATE_IDLE,
      MEMSTATE_BUSY
   );
   signal memstate : t_memstate := MEMSTATE_IDLE;                 
   
   signal stallNew4                    : std_logic := '0';
               
   signal stall1                       : std_logic := '0';
   signal stall2                       : std_logic := '0';
   signal stall3                       : std_logic := '0';
   signal stall4                       : std_logic := '0';
   signal stall                        : unsigned(4 downto 0) := (others => '0');
   signal stall4Masked                 : unsigned(4 downto 0) := (others => '0');
                     
   signal exception                    : std_logic;
   signal exceptionStage1              : std_logic;
   signal exceptionNew3                : std_logic := '0';
   signal exceptionNewPC               : std_logic;
   signal exceptionFPU                 : std_logic;
   signal exception_COP                : unsigned(1 downto 0);
   
   signal exception_SR                 : unsigned(31 downto 0) := (others => '0');
   signal exception_CAUSE              : unsigned(31 downto 0) := (others => '0');
   signal exception_EPC                : unsigned(31 downto 0) := (others => '0');
   signal exception_JMP                : unsigned(31 downto 0) := (others => '0');
   
   signal exceptionCode                : unsigned(3 downto 0);
   signal exceptionCode_3              : unsigned(3 downto 0);   
   signal exceptionInstr               : unsigned(1 downto 0);
   signal exception_PC                 : unsigned(31 downto 0);
   signal exception_branch             : std_logic;
   signal exception_brslot             : std_logic;
   signal exception_JMPnext            : unsigned(31 downto 0);     
               
   signal opcode0                      : unsigned(31 downto 0) := (others => '0');
   signal opcode1                      : unsigned(31 downto 0) := (others => '0');
-- synthesis translate_off
   signal opcode2                      : unsigned(31 downto 0) := (others => '0');
   signal opcode3                      : unsigned(31 downto 0) := (others => '0');
   signal opcode4                      : unsigned(31 downto 0) := (others => '0');
   -- LOAD_MERGE_BYPASS's check: stage 4 held a load, leaving, on the edge the
   -- instruction now in stage 4 entered it.
   signal executeMergeBehind           : std_logic := '0';
-- synthesis translate_on  
  
   signal PCold0                       : unsigned(63 downto 0) := (others => '0');
   signal PCold1                       : unsigned(63 downto 0) := (others => '0');
   
-- synthesis translate_off
   signal PCold2                       : unsigned(63 downto 0) := (others => '0');
   signal PCold3                       : unsigned(63 downto 0) := (others => '0');
   signal PCold4                       : unsigned(63 downto 0) := (others => '0');
   
   signal hi_1                         : unsigned(63 downto 0) := (others => '0');
   signal lo_1                         : unsigned(63 downto 0) := (others => '0');
   signal hi_2                         : unsigned(63 downto 0) := (others => '0');
   signal lo_2                         : unsigned(63 downto 0) := (others => '0');
-- synthesis translate_on
   
   signal value1                       : unsigned(63 downto 0) := (others => '0');
   signal value2                       : unsigned(63 downto 0) := (others => '0');
   signal executeForwardValue1         : std_logic := '0';
   signal executeForwardValue2         : std_logic := '0';
   signal writebackForwardValue1       : std_logic := '0';
   signal writebackForwardValue2       : std_logic := '0';
               
   -- stage 1          
   -- cache
   signal FetchAddr                    : unsigned(63 downto 0) := (others => '0'); 
   signal FetchAddr1                   : unsigned(63 downto 0) := (others => '0'); 
   signal FetchAddr2                   : unsigned(63 downto 0) := (others => '0'); 
   -- FetchAddr1(13 downto 2) and FetchAddr2(13 downto 2), produced by ONE
   -- flattened mux instead of the two the fetch address goes through.
   --
   -- The I-cache tag RAM is an asynchronous-read MLAB, so its index is
   -- combinational from the fetch address in the same cycle the address is
   -- chosen. The binding path in the CPU domain at 100 MHz is
   --   resultWriteEnable -> value1 (3-way forward mux) -> FetchAddr1 (5-way
   --   fetch mux) -> itagram1 -> rd_mux -> read_hit -> stall1
   -- and most of it is interconnect. Two of those hops exist only because the
   -- forwarding mux and the fetch mux are separate signals that have to be
   -- routed between: from value1 to FetchAddr1, then on to the RAM.
   --
   -- Only bits 13 downto 2 reach the RAMs - 9 for the tag index, 12 for the
   -- data address - so a private flattened copy of just those costs 12 bits of
   -- mux and removes an entire level plus one long hop. The tag COMPARE still
   -- uses FetchAddrTLBMuxed1, so a wrong index cannot be mistaken for a hit;
   -- it would miss and fill, not return the wrong line.
   signal FetchIndex1                  : unsigned(13 downto 2) := (others => '0');
   signal FetchIndex2                  : unsigned(13 downto 2) := (others => '0');
   signal FetchAddrTLBMuxed1           : unsigned(31 downto 0) := (others => '0'); 
   signal FetchAddrTLBMuxed2           : unsigned(31 downto 0) := (others => '0'); 
   signal FetchAddrSelect              : std_logic;
   signal fetchCache1                  : std_logic;
   signal fetchCache2                  : std_logic;
   signal fetchCache                   : std_logic;
   signal useCached_data               : std_logic := '0';
   
   signal fill_addrTag                 : unsigned(31 downto 0) := (others => '0'); 
   signal instrcache_request           : std_logic;
   signal instrcache_active            : std_logic := '0';
   signal instrcache_hit               : std_logic;
   signal instrcache_data              : std_logic_vector(31 downto 0);
   signal instrcache_fill              : std_logic := '0';
   signal instrcache_fill_done         : std_logic;
   signal cache_commandEnableI         : std_logic;
   signal cache_commandEnableD         : std_logic;
   
   signal cacheHitLast                 : std_logic := '0';
   
   -- regs           
   signal fetchReady                   : std_logic := '0';
   -- Out of reset, stage 1 holds the reset vector until the data cache has
   -- cleared its tags; see BOOT_HOLD in the stage 1 process.
   signal boot_hold                    : std_logic := '1';
   signal datacache_clear_busy         : std_logic;
   
   -- wires   
   signal mem1_request                 : std_logic := '0';
   signal mem1_cacherequest            : std_logic := '0';
   signal mem1_address                 : unsigned(31 downto 0) := (others => '0'); 
            
   -- stage 2           
   --regs      
   signal decodeNew                    : std_logic := '0';
   signal decodeResultWriteEnable      : std_logic := '0';
   signal decode_irq                   : std_logic := '0';
   signal blockIRQ                     : std_logic := '0';
   signal decodeImmData                : unsigned(15 downto 0) := (others => '0');
   signal decodeSource1                : unsigned(4 downto 0) := (others => '0');
   signal decodeSource2                : unsigned(4 downto 0) := (others => '0');
   signal decodeValue1                 : unsigned(63 downto 0) := (others => '0');
   signal decodeValue2                 : unsigned(63 downto 0) := (others => '0');
   signal decodeShamt                  : unsigned(5 downto 0) := (others => '0');
   signal decodeRD                     : unsigned(4 downto 0) := (others => '0');
   signal decodeTarget                 : unsigned(4 downto 0) := (others => '0');
   signal decodeJumpTarget             : unsigned(25 downto 0) := (others => '0');
   signal decodeUseImmidateValue2      : std_logic := '0';
   signal decodeShiftSigned            : std_logic := '0';
   signal decodeShift32                : std_logic := '0';
   signal decodeShiftAmountType        : std_logic_vector(1 downto 0) := "00";
   signal decodeFPUSource1             : unsigned(4 downto 0) := (others => '0');
   signal decodeFPUSource2             : unsigned(4 downto 0) := (others => '0');
   signal decodeFPUValue1              : unsigned(63 downto 0) := (others => '0');
   signal decodeFPUValue2              : unsigned(63 downto 0) := (others => '0');
   signal decodeFPUForwardUse          : std_logic := '0';
   signal decodeFPUTarget              : unsigned(4 downto 0) := (others => '0');
   signal decodeFPUCommandEnable       : std_logic := '0';
   signal decodeFPUTransferEnable      : std_logic := '0';
   signal decodeFPUMULS                : std_logic := '0';
   signal decodeFPUMULD                : std_logic := '0';
   signal decodeExcCode                : unsigned(3 downto 0); 
   signal decodeExcCOP                 : unsigned(1 downto 0); 
   signal decodecalcMULT               : std_logic := '0';
   signal decodecalcMULTU              : std_logic := '0';
   signal decodecalcDMULT              : std_logic := '0';
   signal decodecalcDMULTU             : std_logic := '0';
   signal decodecalcDIV                : std_logic := '0';
   signal decodecalcDIVU               : std_logic := '0';
   signal decodecalcDDIV               : std_logic := '0';
   signal decodecalcDDIVU              : std_logic := '0';
   signal decodehiUpdate               : std_logic := '0';
   signal decodeloUpdate               : std_logic := '0';
   signal decodeMemWriteEnable         : std_logic := '0';
   signal decodeMemWriteLL             : std_logic := '0';
   signal decodeMemReadEnable          : std_logic := '0';
   signal decodeMem64Bit               : std_logic := '0';
   signal decodeCacheEnable            : std_logic := '0';
   signal decodeCacheTLBTranslate      : std_logic := '0';
   signal decodeSetLL                  : std_logic := '0';
   signal decodeResetLL                : std_logic := '0';
   signal decodeERET                   : std_logic := '0';
   signal decodeCOP0ReadEnable         : std_logic := '0';
   signal decodeCOP0WriteEnable        : std_logic := '0';
   signal decodeCOP0Register           : unsigned(4 downto 0);
   signal decodeCOP1ReadEnable         : std_logic := '0';
   signal decodeCOP2ReadEnable         : std_logic := '0';
   signal decodeCOP2WriteEnable        : std_logic := '0';
   signal decodeCOP64                  : std_logic := '0';
   signal decodeTLBR                   : std_logic := '0';
   signal decodeTLBWI                  : std_logic := '0';
   signal decodeTLBWR                  : std_logic := '0';
   signal decodeTLBP                   : std_logic := '0';
   
   type t_decodeBitFuncType is
   (
      BITFUNC_SIGNED,
      BITFUNC_UNSIGNED,
      BITFUNC_IMM_SIGNED,
      BITFUNC_IMM_UNSIGNED,
      BITFUNC_SC
   );
   signal decodeBitFuncType : t_decodeBitFuncType;    

   type t_decodeBranchType is
   (
      BRANCH_OFF,
      BRANCH_ALWAYS_REG,
      BRANCH_JUMPIMM,
      BRANCH_BRANCH_BLTZ,
      BRANCH_BRANCH_BGEZ, 
      BRANCH_BRANCH_BEQ,
      BRANCH_BRANCH_BNE,
      BRANCH_BRANCH_BLEZ,
      BRANCH_BRANCH_BGTZ,
      BRANCH_BC1,
      BRANCH_ERET
   );
   signal decodeBranchType    : t_decodeBranchType;   
   signal decodeBranchLikely  : std_logic;

   type t_decodeResultMux is
   (
      RESULTMUX_SHIFTLEFT, 
      RESULTMUX_SHIFTRIGHT,
      RESULTMUX_ADD,       
      RESULTMUX_PC,        
      RESULTMUX_HI,        
      RESULTMUX_LO,        
      RESULTMUX_SUB,       
      RESULTMUX_AND,       
      RESULTMUX_OR,        
      RESULTMUX_XOR,       
      RESULTMUX_NOR,       
      RESULTMUX_BIT,
      RESULTMUX_FPU,      
      RESULTMUX_LUI
   );
   signal decodeResultMux : t_decodeResultMux;   
   signal decodeResult32               : std_logic := '0';
   
   type t_decodeExcType is
   (
      EXCTYPE_NONE,
      EXCTYPE_DECODE, 
      EXCTYPE_PC,
      EXCTYPE_ADDRH,
      EXCTYPE_ADDRW,
      EXCTYPE_ADDRD,
      EXCTYPE_ADD,
      EXCTYPE_DADD,
      EXCTYPE_ADDI,
      EXCTYPE_DADDI,
      EXCTYPE_SUB,
      EXCTYPE_DSUB,
      EXCTYPE_TRAPU0, 
      EXCTYPE_TRAPU1, 
      EXCTYPE_TRAPS0, 
      EXCTYPE_TRAPS1, 
      EXCTYPE_TRAPE0, 
      EXCTYPE_TRAPE1, 
      EXCTYPE_TRAPIU0,
      EXCTYPE_TRAPIU1,
      EXCTYPE_TRAPIS0,
      EXCTYPE_TRAPIS1,
      EXCTYPE_TRAPIE0,
      EXCTYPE_TRAPIE1
   );
   signal decodeExcType : t_decodeExcType := EXCTYPE_NONE;    
   
   type t_decodeMemWriteType is
   (
      MEMWRITETYPE_BYTE,
      MEMWRITETYPE_HALF,
      MEMWRITETYPE_WORD,
      MEMWRITETYPE_SWL,
      MEMWRITETYPE_SWR,
      MEMWRITETYPE_DWORD,
      MEMWRITETYPE_SDL,
      MEMWRITETYPE_SDR,
      MEMWRITETYPE_COP1L,
      MEMWRITETYPE_COP1H,
      MEMWRITETYPE_COP1D
   );
   signal decodeMemWriteType : t_decodeMemWriteType := MEMWRITETYPE_BYTE;    
   
   type CPU_LOADTYPE is
   (
      LOADTYPE_SBYTE,
      LOADTYPE_SWORD,
      LOADTYPE_LEFT,
      LOADTYPE_DWORD,
      LOADTYPE_DWORDU,
      LOADTYPE_BYTE,
      LOADTYPE_WORD,
      LOADTYPE_RIGHT,
      LOADTYPE_QWORD,
      LOADTYPE_LEFT64,
      LOADTYPE_RIGHT64
   );
   signal decodeLoadType               : CPU_LOADTYPE;
   
   -- wires
   signal opcodeCacheMuxed             : unsigned(31 downto 0) := (others => '0');
   
   signal decImmData                   : unsigned(15 downto 0);
   signal decSource1                   : unsigned(4 downto 0);
   signal decSource2                   : unsigned(4 downto 0);
   signal decOP                        : unsigned(5 downto 0);
   signal decFunct                     : unsigned(5 downto 0);
   signal decShamt                     : unsigned(4 downto 0);
   signal decRD                        : unsigned(4 downto 0);
   signal decTarget                    : unsigned(4 downto 0);
   signal decJumpTarget                : unsigned(25 downto 0);
   signal decFPUSource1                : unsigned(4 downto 0);
   signal decFPUSource2                : unsigned(4 downto 0);
   signal decRequiresFPUreg1           : std_logic; 
   signal decRequiresFPUreg2           : std_logic;
   signal decFPUForwardUse             : std_logic;
            
   -- stage 3   
   signal value2_muxedSigned           : unsigned(63 downto 0);
   signal value2_muxedLogical          : unsigned(63 downto 0);
   signal calcResult_add               : unsigned(63 downto 0);
   signal calcResult_sub               : unsigned(63 downto 0);
   signal calcResult_and               : unsigned(63 downto 0);
   signal calcResult_or                : unsigned(63 downto 0);
   signal calcResult_xor               : unsigned(63 downto 0);
   signal calcResult_nor               : unsigned(63 downto 0);
   signal calcMemAddr                  : unsigned(63 downto 0);
   
   signal calcResult_lesserSigned      : std_logic;
   signal calcResult_lesserUnSigned    : std_logic;
   signal calcResult_lesserIMMSigned   : std_logic;
   signal calcResult_lesserIMMUnsigned : std_logic;
   signal calcResult_equal             : std_logic;
   signal calcResult_bit               : unsigned(63 downto 0);
   
   signal executeShamt                 : unsigned(5 downto 0);
   signal shiftValue                   : signed(64 downto 0);
   signal calcResult_shiftL            : unsigned(63 downto 0);
   signal calcResult_shiftR            : unsigned(63 downto 0);
   
   signal cmpEqual                     : std_logic;
   signal cmpNegative                  : std_logic;
   signal cmpZero                      : std_logic;
   signal PCnext                       : unsigned(63 downto 0) := (others => '0');
   signal PCnextBranch                 : unsigned(63 downto 0) := (others => '0');
   
   signal resultDataMuxed              : unsigned(63 downto 0);
   signal resultDataMuxed64            : unsigned(63 downto 0);
   
   --regs         
   signal executeNew                   : std_logic := '0';
   signal executeIgnoreNext            : std_logic := '0';
   signal executeStallFromMEM          : std_logic := '0';
   signal resultWriteEnable            : std_logic := '0';
   signal executeBranchdelaySlot       : std_logic := '0';
   signal resultTarget                 : unsigned(4 downto 0) := (others => '0');
   signal resultData                   : unsigned(63 downto 0) := (others => '0');
   signal executeMem64Bit              : std_logic := '0';
   signal executeMemWriteEnable        : std_logic := '0';
   signal executeMemUseCache           : std_logic := '0';
   signal executeMemWriteData          : unsigned(63 downto 0) := (others => '0');
   signal executeMemWriteMask          : std_logic_vector(7 downto 0) := (others => '0');
   signal executeMemAddress            : unsigned(31 downto 0) := (others => '0');
   signal executeMemReadEnable         : std_logic := '0';
   signal executeMemReadLastData       : unsigned(63 downto 0) := (others => '0');
   signal executeCOP0WriteEnable       : std_logic := '0';
   signal executeCOP0ReadEnable        : std_logic := '0';
   signal executeCOP0Register          : unsigned(4 downto 0) := (others => '0');
   signal executeCOP0WriteValue        : unsigned(63 downto 0) := (others => '0');
   signal executeCOP2WriteEnable       : std_logic := '0';
   signal executeCOP2ReadEnable        : std_logic := '0';
   signal executeCOP64                 : std_logic := '0';
   signal executeSetLL                 : std_logic := '0';
   signal executeLLfromTLB             : std_logic := '0';
   signal executeLoadType              : CPU_LOADTYPE;
   signal executeICacheEnable          : std_logic := '0';
   signal executeDCacheEnable          : std_logic := '0';
   signal executeCacheCommand          : unsigned(4 downto 0) := (others => '0');
   signal executeCOP1Target            : unsigned(4 downto 0) := (others => '0');
   signal executeCOP1ReadEnable        : std_logic := '0';
   signal execute_unstallFPUForward    : std_logic := '0';
   signal execute_ERET                 : std_logic := '0';
   signal execute_TLBR                 : std_logic := '0';
   signal execute_TLBWI                : std_logic := '0';
   signal execute_TLBWR                : std_logic := '0';
   signal execute_TLBP                 : std_logic := '0';
   signal exceptionAllowDelay          : std_logic := '0';

   signal hiloWait                     : integer range 0 to 69;
   
   signal llBit                        : std_logic := '0';

   --wires
   signal EXEIgnoreNext                : std_logic := '0';
   signal EXEBranchdelaySlot           : std_logic := '0';
   signal EXECOPBranchDelaySlot        : std_logic := '0';
   signal EXEBranchTaken               : std_logic := '0';
   signal EXEMemWriteData              : unsigned(63 downto 0) := (others => '0');
   signal EXEMemWriteMask              : std_logic_vector(7 downto 0) := (others => '0');
   signal EXECOP0WriteValue            : unsigned(63 downto 0) := (others => '0');
   signal EXECacheAddr                 : unsigned(31 downto 0);
   signal EXEExceptionMem              : std_logic;
   signal EXETLBMapped                 : std_logic;
   signal EXETLBDataAccess             : std_logic;
   
   --MULT/DIV
   type CPU_HILOCALC is
   (
      HILOCALC_MULT, 
      HILOCALC_MULTU,
      HILOCALC_DMULT,
      HILOCALC_DMULTU,
      HILOCALC_DIV,  
      HILOCALC_DIVU,
      HILOCALC_DDIV,  
      HILOCALC_DDIVU
   );
   signal hilocalc                     : CPU_HILOCALC;
   
   signal mulsign                      : std_logic;
   signal mul1                         : std_logic_vector(63 downto 0);
   signal mul2                         : std_logic_vector(63 downto 0);
   signal mulResult                    : std_logic_vector(127 downto 0);
   
   signal DIVstart                     : std_logic;
   signal DIVis32                      : std_logic;
   signal DIVdividend                  : signed(64 downto 0);
   signal DIVdivisor                   : signed(64 downto 0);
   signal DIVquotient                  : signed(64 downto 0);
   signal DIVremainder                 : signed(64 downto 0);     
         
   -- COP0
   signal eretPC                       : unsigned(63 downto 0) := (others => '0');
   signal exceptionPC                  : unsigned(63 downto 0) := (others => '0');
   signal COP0ReadValue                : unsigned(63 downto 0) := (others => '0');
   
   signal COP0_enable                  : std_logic;
   signal COP1_enable                  : std_logic;
   signal COP2_enable                  : std_logic;
   signal fpuRegMode                   : std_logic;
   signal privilegeMode                : unsigned(1 downto 0);
   signal kusegUnmapped                : std_logic;
   signal bit64region                  : std_logic;
   -- Region decode width. bit64region is Status.KX/SX/UX via cpu_cop0; with
   -- ADDR32_ONLY it is forced to '0' at elaboration so the 64-bit branch is
   -- never built.
   --
   -- That branch is a cascade of roughly 26 chained 64-bit magnitude compares
   -- on value1 - the forwarded register at the head of the critical path - and
   -- it feeds BOTH dominant path clusters: the region decode below
   -- (executeMemAddress) and TLB_instrMapped above (stall1). The 32-bit branch
   -- it is replaced by is three compares on calcMemAddr(31 downto 29).
   --
   -- The KI wrapper enables ADDR32_ONLY because both supported games execute
   -- with 32-bit virtual addresses and keep Status.KX/SX/UX clear.
   signal region64                     : std_logic;
   signal irqTrigger                   : std_logic;
   signal TLBDone                      : std_logic;
   
   signal region_TLBmapped             : std_logic;
   signal region_cached                : std_logic;
   signal region_full32                : std_logic;
   signal region_unused                : std_logic;
   
   signal TLB_ss_load                  : std_logic;
   signal TLB_instrMapped              : std_logic;
   signal TLB_instrMapped1             : std_logic;
   signal TLB_instrMapped2             : std_logic;
   signal TLB_instrReq                 : std_logic;
   signal TLB_instrUseCache            : std_logic;
   signal TLB_instrStall               : std_logic;
   signal TLB_instrUnStall             : std_logic;
   signal TLB_instrAddrOutFound        : unsigned(31 downto 0);   
   signal TLB_instrAddrOutLookup       : unsigned(31 downto 0);   
   signal TLB_dataUseCacheFound        : std_logic;
   signal TLB_dataUseCacheLookup       : std_logic;
   signal TLB_dataStall                : std_logic;
   signal TLB_dataUnStall              : std_logic;
   signal TLB_dataAddrOutFound         : unsigned(31 downto 0);
   signal TLB_dataAddrOutLookup        : unsigned(31 downto 0);
   
   signal TagLo_Valid                  : std_logic;
   signal TagLo_Dirty                  : std_logic;
   signal TagLo_Addr                   : unsigned(19 downto 0);
   
   signal writeDatacacheTagEna         : std_logic;
   signal writeDatacacheTagValue       : unsigned(21 downto 0);

   -- COP1
   signal cop1_stage4_writeEnable      : std_logic := '0';
   signal cop1_stage4_writeMask        : std_logic_vector(1 downto 0) := (others => '0');
   signal cop1_stage4_data             : unsigned(63 downto 0) := (others => '0');
   signal cop1_stage4_target           : unsigned(4 downto 0) := (others => '0');

   signal FPU_CF                       : std_logic;
   signal FPU_command_ena              : std_logic := '0';
   signal FPU_command_done             : std_logic := '0';
   signal FPU_fwd_data                 : unsigned(63 downto 0);
   signal FPU_fwd_valid                : std_logic;
   signal FPU_fwd_match1               : std_logic := '0';
   signal FPU_fwd_match2               : std_logic := '0';
   signal FPU_TransferEna              : std_logic := '0';
   signal FPU_TransferData             : unsigned(63 downto 0);

   -- COP2
   signal COP2Latch                    : unsigned(63 downto 0) := (others => '0');

   -- stage 4 
   -- reg      
   signal writebackNew                 : std_logic := '0';
   signal writebackStallFromMEM        : std_logic := '0';
   signal load_use                     : std_logic;
   signal dec_reads_rt                 : std_logic;
   -- LOAD_MERGE_BYPASS: the instruction in stage 2 is a merge load of the rt
   -- the load in stage 3 writes, and takes no bubble (merge_bypass); it
   -- carries that into stage 3 (decodeMergeFwd) and stage 4
   -- (executeMergeFwd), where it merges into writebackData.
   signal merge_bypass                 : std_logic;
   signal decodeMergeFwd               : std_logic := '0';
   signal executeMergeFwd              : std_logic := '0';
   signal datacache_next_load          : std_logic;
   signal writebackTarget              : unsigned(4 downto 0) := (others => '0');
   signal writebackData                : unsigned(63 downto 0) := (others => '0');
   signal writebackWriteEnable         : std_logic := '0';
   signal writeback_UseCache           : std_logic := '0';
   signal writebackMemWrite             : std_logic := '0';
   signal writebackLoadType            : CPU_LOADTYPE;
   signal writebackReadAddress         : unsigned(31 downto 0) := (others => '0');
   signal writebackReadLastData        : unsigned(63 downto 0) := (others => '0');
   signal writeback_COP1_ReadEnable    : std_logic := '0'; 
   signal writeback_fifoStall          : std_logic := '0'; 
   signal read_fifoStall               : std_logic := '0';
   -- Perf-only: what the access holding stage 4 is, for the uncached split in
   -- debug_perf_events.
   signal perf_st4_read                : std_logic := '0';
   -- Perf-only: an empty pipeline slot a load left, carried from stage 3 into
   -- stage 4 with the slot (see debug_perf_events).
   signal perf_ex_ld                   : std_logic := '0';
   signal perf_wb_ld                   : std_logic := '0';
   signal perf_lost_md                 : std_logic;
   signal perf_lost_s3                 : std_logic;
   signal perf_lost_s1                 : std_logic;
   signal perf_lost_lb                 : std_logic;
   signal perf_lost_fl                 : std_logic;
   signal perf_ld_indep                : std_logic;
   signal perf_st4_region              : std_logic_vector(1 downto 0) := "00";
   signal perf_exec_region             : std_logic_vector(1 downto 0);
   signal perf_uc                      : std_logic;
   signal perf_uc_load                 : std_logic;
   signal perf_uc_write                : std_logic;
   signal perf_uc_fb                   : std_logic;
   signal perf_uc_io                   : std_logic;
   signal perf_uc_rom                  : std_logic;
   signal perf_uc_ram                  : std_logic;
   -- The replayed request has to carry the address, data and mask of the
   -- instruction that was BLOCKED, not whatever stage 3 has moved on to.
   -- Stage 3 keeps advancing while stage 4 is stalled, so executeMemAddress
   -- and friends belong to a later instruction by the time the FIFO frees up.
   -- The other FIFO sources already latch for exactly this reason - see
   -- datacache_address_latched and mem1_address_latched above.
   signal fifoStall_address            : unsigned(31 downto 0) := (others => '0');
   signal fifoStall_dataWrite          : std_logic_vector(63 downto 0) := (others => '0');
   signal fifoStall_writeMask          : std_logic_vector(7 downto 0) := (others => '0');
   signal fifoStall_req64              : std_logic := '0';
   signal fifoStall_useCache           : std_logic := '0';
   signal read_fifoStall_address       : unsigned(31 downto 0) := (others => '0');
   signal read_fifoStall_req64         : std_logic := '0';
         
   -- wire     
   signal mem4_request                 : std_logic := '0';
   signal mem4_address                 : unsigned(31 downto 0) := (others => '0');
   signal mem4_req64                   : std_logic := '0';
   signal mem4_rnw                     : std_logic := '0';
   signal mem4_dataWrite               : std_logic_vector(63 downto 0) := (others => '0');    
   signal mem4_writeMask               : std_logic_vector(7 downto 0) := (others => '0');    
   
   signal read4_dataReadData           : unsigned(63 downto 0);
   signal read4_uncachedRot            : unsigned(1 downto 0);
   signal read4_uncachedData           : unsigned(63 downto 0);
   signal mem_finished_dataRot         : std_logic_vector(63 downto 0);
   signal read4_dataReadRot64          : unsigned(63 downto 0);
   signal read4_dataReadRot32          : unsigned(31 downto 0);
   signal read4_Addr                   : unsigned(31 downto 0);
   signal read4_oldData                : unsigned(63 downto 0);
   signal read4_cop1_readEna           : std_logic;
   signal read4_cop1_target            : unsigned(4 downto 0);
   signal read4_useLoadType            : CPU_LOADTYPE;
   signal read4_useTarget              : unsigned(4 downto 0);
   
   -- Cache
   signal DATACACHEON_intern           : std_logic := '0';
   signal DATACACHETLBON_intern        : std_logic := '0';
   signal datacache_request            : std_logic;
   signal datacache_request_raw        : std_logic;
   -- The direct fill path; see fast_go. fast_busy: a direct read is
   -- outstanding (fast_out).
   -- fast_go_q: a demand fill queued behind the landing line of the one
   -- outstanding (DCACHE_EARLY_RESTART); fast_tail_q_ok says to the data
   -- cache that its request may leave so. fast_first_seen: the newest
   -- request's first beat has come, so the controller has taken it.
   -- fast_path_quiet: nothing of the CPU's in the bridge's path.
   -- fast_ra_go: the read-ahead's line fetch takes it, and fast_is_ra_r
   -- marks the one outstanding as the read-ahead's.
   signal fast_go                      : std_logic;
   signal fast_ra_go                   : std_logic;
   signal fast_path_clear              : std_logic;
   signal fast_busy                    : std_logic;
   signal fast_line_ok                 : std_logic;
   signal fast_ra_line_ok              : std_logic;
   signal fast_line                    : unsigned(31 downto 0);
   signal fast_ra_line                 : unsigned(31 downto 0);
   signal fast_tog_r                   : std_logic := '0';
   signal fast_is_ra_r                 : std_logic := '0';
   -- The read-ahead outstanding is a stream's (datacache_ra_stream).
   signal fast_stream_r                : std_logic := '0';
   signal fast_window_dc               : std_logic;
   -- An uncached 64-bit load takes it (fast_unc_go), fast_is_unc_r marks the
   -- one outstanding as such, and fast_unc_q_1x is its qword, taken at its
   -- one beat.
   signal fast_unc_go                  : std_logic;
   signal fast_unc_ok                  : std_logic;
   signal fast_is_unc_r                : std_logic := '0';
   signal fast_unc_q_1x                : std_logic_vector(63 downto 0) := (others => '0');
   signal fast_line_r                  : unsigned(31 downto 0) := (others => '0');
   signal fast_done_seen               : std_logic := '0';
   -- fast_unc_ret: the outstanding uncached qword is back on fast_unc_valid.
   -- fast_ret: a direct read is back, either way.
   signal fast_unc_ret                 : std_logic;
   signal fast_ret                     : std_logic;
   -- RA_CTL_RETURN: a qword of the direct read-ahead outstanding is on
   -- fast_ra_valid (fast_ra_take), fast_ra_q of its four have come, and this
   -- is the fourth (fast_ra_ret).
   signal fast_ra_take                 : std_logic;
   signal fast_ra_q                    : unsigned(1 downto 0) := (others => '0');
   signal fast_ra_ret                  : std_logic;
   -- RA_CHAIN: the direct read-ahead outstanding completes on this edge
   -- (fast_ra_land); the line after the one the data cache waits for may
   -- leave (fast_chain_term), and does (fast_chain_go).
   signal fast_ra_land                 : std_logic;
   signal fast_chain_term              : std_logic;
   signal fast_chain_go                : std_logic;
   -- fast_s3_go: UNC_LAUNCH_S3's request, from stage 3; fast_s3_launched:
   -- it was asked for on the last edge, and stage 4 presents it now.
   signal fast_s3_go                   : std_logic;
   signal fast_s3_launched             : std_logic := '0';
   signal fast_out                     : integer range 0 to 2 := 0;
   signal fast_first_seen              : std_logic := '0';
   signal fast_path_quiet              : std_logic;
   signal fast_q_clear                 : std_logic;
   signal fast_tail_q_ok               : std_logic;
   signal fast_go_q                    : std_logic;
   -- clk1x's transaction writes a line back into the framebuffer, which the
   -- direct path may run beside (fast_path_clear).
   signal mem_line_fb                  : std_logic := '0';
   signal dc_active                    : std_logic;
   signal dc_grant                     : std_logic;
   signal dc_ready                     : std_logic;
   signal dc_dout                      : std_logic_vector(63 downto 0);
   signal datacache_active             : std_logic := '0';
   signal datacache_reqAddr            : unsigned(31 downto 0);
   signal datacache_readena            : std_logic;
   signal datacache_readbusy           : std_logic;
   signal datacache_readdone           : std_logic;
   signal datacache_addr               : unsigned(31 downto 0);   
   signal datacache_data_out           : std_logic_vector(63 downto 0);   
   signal datacache_writeena           : std_logic;
   signal datacache_writedone          : std_logic;
   signal datacache_CmdStall           : std_logic;
   signal datacache_perf_miss          : std_logic;
   signal datacache_perf_miss_low      : std_logic;
   signal datacache_perf_fill_wait     : std_logic;
   signal datacache_perf_stride_hit    : std_logic;
   signal datacache_perf_wb_line       : std_logic;
   signal datacache_perf_fill_store    : std_logic;
   signal datacache_perf_fill_skip     : std_logic;
   signal datacache_perf_fill_absent   : std_logic;
   -- The data cache's read-ahead: its request (a pulse), held until the
   -- scheduler issues it; its completion; the staged line; and which memory
   -- transaction in flight is one.
   signal datacache_ra_request         : std_logic;
   signal datacache_ra_addr            : unsigned(31 downto 0);
   signal datacache_ra_stream          : std_logic;
   signal datacache_ra_pending         : std_logic := '0';
   signal datacache_ra_done            : std_logic := '0';
   signal datacache_ra_data            : std_logic_vector(255 downto 0) := (others => '0');
   signal datacache_ra_store           : std_logic;
   -- datacache_ra_data changed on the last edge, a qword of a line on
   -- fast_ra_valid (RA_CTL_RETURN).
   signal datacache_ra_wr              : std_logic := '0';
   -- RA_CHAIN: the cache's arm and the line after, whether that line is SDRAM
   -- RAM, and its launch on the last edge.
   signal datacache_ra_chain_ok        : std_logic;
   signal datacache_ra_chain_addr      : unsigned(31 downto 0);
   signal datacache_ra_chain_sdram     : std_logic;
   signal datacache_ra_chain_taken     : std_logic := '0';
   signal datacache_CmdDone            : std_logic;
   
   signal datacache_wb_ena             : std_logic;
   signal datacache_wb_addr            : unsigned(31 downto 0);
   signal datacache_wb_data            : std_logic_vector(63 downto 0);
   signal datacache_wb_mask            : std_logic_vector(3 downto 0);
   signal datacache_wb_bytes           : std_logic_vector(31 downto 0);
   -- The issued line's bytes, held with its words in the staging queue.
   signal wb_line_bytes_93             : std_logic_vector(31 downto 0) := (others => '1');
   signal wb_line_mask_93              : std_logic_vector(3 downto 0) := (others => '1');
   
   -- savestates
   type t_ssarray is array(0 to 31) of std_logic_vector(63 downto 0);
   signal ss_in  : t_ssarray := (others => (others => '0'));  
   signal ss_out : t_ssarray := (others => (others => '0'));  

   signal regsSS_address_b             : std_logic_vector(4 downto 0) := (others => '0');
   signal regsSS_q_b                   : std_logic_vector(63 downto 0);
   signal regsSS_rden                  : std_logic := '0';
   
   signal ss_regs_loading              : std_logic := '0';
   signal ss_regs_load                 : std_logic := '0';
   signal ss_regs_addr                 : unsigned(4 downto 0);
   signal ss_regs_data                 : std_logic_vector(63 downto 0);   
   
   signal ss_FPUregs_load              : std_logic := '0';
   signal ss_FPUregs_addr              : unsigned(4 downto 0);
   signal ss_FPUregs_data              : std_logic_vector(63 downto 0);   
   
   -- debug
   --signal debugCnt                     : unsigned(31 downto 0);
   --signal debugSum                     : unsigned(31 downto 0);
   --signal debugTmr                     : unsigned(31 downto 0);
   --signal debugwrite                   : std_logic := '0';
   
-- synthesis translate_off
   signal stallcountNo                 : integer;
   signal stallcount1                  : integer;
   signal stallcount3                  : integer;
   signal stallcount4                  : integer;
   signal stallcountDMA                : integer;
-- synthesis translate_on
   
   signal debugStallcounter            : unsigned(12 downto 0);
   
   -- export
-- synthesis translate_off
   type tRegs is array(0 to 31) of unsigned(63 downto 0);
   signal regs                         : tRegs := (others => (others => '0'));
   signal FPUregs                      : tRegs := (others => (others => '0'));
   
   signal cop0_export                  : tExportRegs := (others => (others => '0'));
   signal cop0_export_1                : tExportRegs := (others => (others => '0'));
   signal csr_export                   : unsigned(24 downto 0) := (others => '0');
   signal csr_export_1                 : unsigned(24 downto 0) := (others => '0');
   signal csr_export_2                 : unsigned(24 downto 0) := (others => '0');
-- synthesis translate_on
   
begin

   debug_fetch_pc <= debug_fetch_pc_register;
   debug_retired  <= std_logic_vector(debug_retired_count);
   debug_retire_pc <= debug_retire_pc_register;
   debug_retire_opcode <= debug_retire_opcode_register;

   ds_chain_proc : process (clk93)
   begin
      if rising_edge(clk93) then
         if (reset_93 = '1') then
            ds_prev_pc       <= (others => '0');
            ds_prev_isbranch <= '0';
         elsif (ce_93 = '1' and decodeNewPulse = '1') then
            ds_prev_pc       <= PCold1(31 downto 0);
            ds_prev_isbranch <= opcodeIsBranch(opcode1);
         end if;
      end if;
   end process;

   -- A chained delay slot requires BOTH: the previous decode was a branch, AND
   -- this decode is not sequentially after it.
   --
   -- On a re-decode the previous decode is the slot itself, which is not a
   -- branch, so the EPC back-up remains enabled. In the chained case the
   -- previous decode is the second branch and suppression applies.
   chainedDelaySlot <= ds_prev_isbranch when (PCold1(31 downto 0) /= (ds_prev_pc + 4)) else '0';

   debug_cop0_cause_live <= std_logic_vector(cop0_debug_cause);
   debug_cop0_epc_live   <= std_logic_vector(cop0_debug_epc);

   process (clk93)
   begin
      if (rising_edge(clk93)) then
         if (reset_93 = '1') then
            debug_fetch_pc_register <= (others => '0');
         elsif (ce_93 = '1' and stall = 0 and decodeNew = '1') then
            debug_fetch_pc_register <= std_logic_vector(PCold1(31 downto 0));
         end if;
      end if;
   end process;

   -- common
   stall        <= '0' & stall4 & stall3 & stall2 & stall1;

   -- Whether the stage 3 access is inside a framebuffer page. The data cache
   -- takes it as RW_fb for the partial framebuffer stores; the stall census
   -- latches the region into stage 4 alongside writebackMemWrite.
   -- executeMemAddress is physical for the KSEG0/1 accesses KI makes.
   executeMemFB <= '1' when
      (((executeMemAddress >= FB0_LOW) and (executeMemAddress < FB0_HIGH)) or
       ((executeMemAddress >= FB1_LOW) and (executeMemAddress < FB1_HIGH))) else '0';

   perf_exec_region <=
      "01" when (executeMemFB = '1') else
      "10" when (executeMemAddress(28 downto 24) = "10000") else   -- 0x10xxxxxx, I/O
      "11" when (executeMemAddress(28 downto 22) = "1111111") else -- 0x1FCxxxxx, boot ROM
      "00";                                                        -- RAM, anything else

   perf_uc       <= stall4 and (not writeback_UseCache);
   perf_uc_write <= perf_uc and writebackMemWrite;
   perf_uc_load  <= perf_uc and (not writebackMemWrite) and perf_st4_read;
   perf_uc_fb    <= perf_uc_load when (perf_st4_region = "01") else '0';
   perf_uc_io    <= perf_uc_load when (perf_st4_region = "10") else '0';
   perf_uc_rom   <= perf_uc_load when (perf_st4_region = "11") else '0';
   perf_uc_ram   <= perf_uc_load when (perf_st4_region = "00") else '0';

   -- The lost-cycle census; see debug_perf_events in the port list. Each
   -- class excludes the ones before it, and none can hold in a cycle that
   -- retires, so together with retirement they cover every running cycle
   -- exactly once. Simulation checks that, cycle by cycle.
   perf_lost_md <= '1' when (ce_93 = '1' and stall4 = '0' and stall4Masked(2) = '1' and
                             hiloWait > 0) else '0';
   perf_lost_lb <= '1' when (ce_93 = '1' and stall4 = '0' and stall4Masked(2) = '1' and
                             hiloWait = 0 and writebackStallFromMEM = '1') or
                            (ce_93 = '1' and stall4Masked = 0 and writebackNew = '0' and
                             perf_wb_ld = '1') else '0';
   perf_lost_s3 <= '1' when (ce_93 = '1' and stall4 = '0' and stall4Masked(2) = '1' and
                             hiloWait = 0 and writebackStallFromMEM = '0') else '0';
   perf_lost_s1 <= '1' when (ce_93 = '1' and stall4Masked(3 downto 2) = "00" and
                             stall4Masked(1 downto 0) /= "00") else '0';
   perf_lost_fl <= '1' when (ce_93 = '1' and stall4Masked = 0 and writebackNew = '0' and
                             perf_wb_ld = '0') else '0';

   -- A load whose stage-3 bubble a dependency test would remove: presented to
   -- the data cache this cycle and answered in it (a hit in the predicted way,
   -- so no WAYFIX replay to pay instead), with a real instruction behind it
   -- that does not read the loaded register.
   -- With LOAD_INTERLOCK only loads that TOOK the bubble count: what is left
   -- is the test's conservatism (an FPU load, a false match on an empty
   -- stage 2).
   perf_ld_indep <= '1' when (ce_93 = '1' and datacache_readena = '1' and
                              datacache_readdone = '1' and executeCOP1ReadEnable = '0' and
                              executeStallFromMEM = '1' and
                              decodeNew = '1' and
                              not (decodeSource1 > 0 and resultTarget = decodeSource1) and
                              not (decodeSource2 > 0 and resultTarget = decodeSource2)) else '0';

   -- LM (bit 10) is the SRAM-region share of MC; see cpu_datacache's
   -- perf_miss_low.
   debug_perf_events <= perf_ld_indep &                   -- 11 DI
                        datacache_perf_miss_low &         -- 10 LM
                        perf_lost_lb &                    -- 9 LB
                        perf_lost_s1 &                    -- 8 S1
                        perf_lost_s3 &                    -- 7 S3
                        perf_lost_md &                    -- 6 MD
                        (stall4 and writeback_UseCache) & -- 5 DC
                        (perf_uc_ram or perf_uc_io or perf_uc_rom) & -- 4 UO
                        perf_uc_fb &                      -- 3 UF
                        stall4 &                          -- 2 S4
                        perf_uc_write &                   -- 1 UW
                        datacache_perf_miss;              -- 0 MC
   read_meta_push <= writefifo_wr_accept and writefifo_Din(105);
   -- Every store entering the write FIFO, write-backs included: the data
   -- cache's read-ahead drops a staged line one lands in.
   datacache_ra_store <= writefifo_wr_accept and (not writefifo_Din(105));
   resp_take <= '1' when
      (response_cdc_pending_93 = '0' and
       response_cdc_deliver_93 = '0' and
       resp_fifo_empty = '0') else '0';
   resp_fifo_rd  <= resp_take;
   read_meta_pop <= resp_take;
   read_meta_tag_mismatch <= '1' when
      resp_fifo_dout(72 downto 65) /=
        read_meta_tag(to_integer(read_meta_rdptr)) else '0';
   read_meta_class_mismatch <= '1' when
      resp_fifo_dout(64) /=
        read_meta_class(to_integer(read_meta_rdptr)) else '0';
   read_meta_address_mismatch <= '1' when
      resp_fifo_dout(104 downto 73) /=
        read_meta_address(to_integer(read_meta_rdptr)) else '0';
   
   process (clk93)
   begin
      if (rising_edge(clk93)) then
      
         writefifo_Rd          <= '0';
         write_cdc_ack_meta_93 <= write_cdc_ack_1x;
         write_cdc_ack_sync_93 <= write_cdc_ack_meta_93;
         mem_finished_instr       <= '0';
         mem_finished_read        <= '0';
         datacache_fill_done      <= datacache_fill_due;
         datacache_fill_due       <= '0';
         datacache_ra_done        <= '0';
         datacache_ra_wr          <= '0';
         datacache_ra_chain_taken <= '0';
         -- Followed in reset too, so a direct fill that ends during one
         -- leaves nothing outstanding after it; and so is a read-ahead line's
         -- qword count (RA_CTL_RETURN).
         fast_done_seen           <= fast_done_tog;
         fast_s3_launched         <= fast_s3_go;
         if (fast_ra_take = '1') then
            fast_ra_q <= fast_ra_q + 1;
         end if;

         if (reset_93 = '1') then

            -- Neither ki_fast_fill nor the SDRAM controller takes the CPU's
            -- reset, so a direct read in flight when it comes still
            -- finishes. Its completion goes nowhere, but it is counted: a
            -- read left counted keeps fast_busy up, and every later miss
            -- off the direct port. No request leaves during a reset, and
            -- every source of one outlasts a direct read, so the count is
            -- zero by its end (asserted).
            if (fast_ret = '1') then
               fast_out <= fast_out - 1;
            end if;
            -- The data cache forgets its read-ahead in the reset too.
            datacache_ra_pending      <= '0';
            mem1_request_latched      <= '0';
            datacache_request_latched <= '0';
            writefifo_cnt             <= 0;
            datacache_wb_fifo_wrptr   <= (others => '0');
            datacache_wb_fifo_count   <= 0;
            writefifo_issue_pending <= '0';
            writefifo_issue_wb      <= '0';
            wb_line_issued          <= '0';
            wb_line_done_meta_93    <= '0';
            wb_line_done_sync_93    <= '0';
            wb_line_done_seen_93    <= '0';
            write_cdc_data_93         <= (others => '0');
            write_cdc_req_93          <= '0';
            write_cdc_busy_93         <= '0';
            write_cdc_ack_meta_93     <= '0';
            write_cdc_ack_sync_93     <= '0';
            response_cdc_pending_93   <= '0';
            response_cdc_deliver_93   <= '0';
             mem_finished_dataRead     <= (others => '0');
             mem_finished_dataRot      <= (others => '0');
             read_meta_wrptr           <= (others => '0');
             read_meta_rdptr           <= (others => '0');
             read_meta_count           <= 0;
             read_sequence_93          <= (others => '0');
             debug_response_status_reg   <= (others => '0');

          else

             -- Record every accepted read independently of the request CDC.
             -- A depth of 16 covers the seven-entry transaction FIFO plus the
             -- request mailbox, the two-entry response FIFO and the active
             -- memory transaction - eleven.
             if (read_meta_push = '1') then
                if (read_meta_count < 16 or read_meta_pop = '1') then
                   read_meta_tag(to_integer(read_meta_wrptr)) <=
                      writefifo_Din(115 downto 108);
                   read_meta_class(to_integer(read_meta_wrptr)) <=
                      writefifo_Din(104);
                   read_meta_address(to_integer(read_meta_wrptr)) <=
                      writefifo_Din(95 downto 64);
                   read_meta_wrptr <= read_meta_wrptr + 1;
                elsif (debug_response_status_reg(31) = '0') then
                   debug_response_status_reg <=
                      '1' & '0' & '1' & "000" &
                      '0' & '0' & x"00" & writefifo_Din(115 downto 108) &
                      "10000" & "000";
                end if;
                read_sequence_93 <= read_sequence_93 + 1;
             end if;

             if (read_meta_pop = '1') then
                if (read_meta_count > 0) then
                   read_meta_rdptr <= read_meta_rdptr + 1;
                   if (debug_response_status_reg(31) = '0' and
                       (read_meta_tag_mismatch = '1' or
                        read_meta_class_mismatch = '1' or
                        read_meta_address_mismatch = '1')) then
                      debug_response_status_reg <=
                         '1' & '0' & '0' &
                         read_meta_address_mismatch &
                         read_meta_class_mismatch &
                         read_meta_tag_mismatch &
                         read_meta_class(to_integer(read_meta_rdptr)) &
                         resp_fifo_dout(64) &
                         read_meta_tag(to_integer(read_meta_rdptr)) &
                         resp_fifo_dout(72 downto 65) &
                         std_logic_vector(to_unsigned(read_meta_count, 5)) &
                         "000";
                   end if;
                elsif (debug_response_status_reg(31) = '0') then
                   debug_response_status_reg <=
                      '1' & '1' & '0' & "000" &
                      '0' & resp_fifo_dout(64) &
                      x"00" & resp_fifo_dout(72 downto 65) &
                      "00000" & "000";
                end if;
             end if;

             if (read_meta_push = '1' and read_meta_pop = '0' and
                 read_meta_count < 16) then
                read_meta_count <= read_meta_count + 1;
             elsif (read_meta_push = '0' and read_meta_pop = '1' and
                    read_meta_count > 0) then
                read_meta_count <= read_meta_count - 1;
             end if;
         
            if (write_cdc_busy_93 = '1') then
               if (write_cdc_ack_in_93 = write_cdc_req_93) then
                  write_cdc_busy_93 <= '0';
               end if;
            elsif (writefifo_Empty = '0') then
               write_cdc_data_93 <= writefifo_Dout;
               write_cdc_req_93  <= not write_cdc_req_93;
               write_cdc_busy_93 <= '1';
               writefifo_Rd <= '1';
            elsif (writefifo_bypass = '1') then
               write_cdc_data_93 <= writefifo_Din;
               write_cdc_req_93  <= not write_cdc_req_93;
               write_cdc_busy_93 <= '1';
            end if;
         
            -- The FIFO's own occupancy: a bypassed request never enters it.
            if (writefifo_wr_accept = '1' and writefifo_bypass = '0' and
                writefifo_rd_accept = '0') then
               writefifo_cnt <= writefifo_cnt + 1;
            end if;
            if (writefifo_rd_accept = '1' and writefifo_wr_accept = '0') then
               writefifo_cnt <= writefifo_cnt - 1;
            end if;

            -- The data cache emits a dirty line as four consecutive beats
            -- without a ready input. Capture the complete burst here before
            -- allowing downstream FIFO pressure to affect the cache. This
            -- queue is empty before a writeback starts and is exactly large
            -- enough for one complete cache line.
            if (datacache_wb_ena = '1' and datacache_wb_fifo_count < 4) then
               datacache_wb_fifo(to_integer(datacache_wb_fifo_wrptr)) <=
                  std_logic_vector(datacache_wb_addr) & datacache_wb_data;
               datacache_wb_fifo_wrptr <= datacache_wb_fifo_wrptr + 1;
            end if;
            -- The line's mask and bytes, taken with its FIRST word, while the
            -- cache is certainly still in the write-back states that set
            -- them. They ride with the words - the mask into the mailbox at
            -- issue, the bytes beside mem_line_data - and are stable, like
            -- the words, until the queue is released. Reading the cache's own
            -- at issue instead would leave it waiting in WRITEBACKDONE.
            if (datacache_wb_ena = '1' and datacache_wb_fifo_count = 0) then
               wb_line_mask_93  <= datacache_wb_mask;
               wb_line_bytes_93 <= datacache_wb_bytes;
            end if;

            -- Released as a whole line, not beat by beat: the words must sit
            -- still until the clk1x side has read them.
            if (wb_line_release = '1') then
               datacache_wb_fifo_wrptr <= (others => '0');
               datacache_wb_fifo_count <= 0;
            elsif (datacache_wb_ena = '1' and datacache_wb_fifo_count < 4) then
               datacache_wb_fifo_count <= datacache_wb_fifo_count + 1;
            end if;

            wb_line_done_meta_93 <= wb_line_done_1x;
            wb_line_done_sync_93 <= wb_line_done_meta_93;
            if (wb_line_release = '1') then
               wb_line_done_seen_93 <= wb_line_done_in_93;
               wb_line_issued       <= '0';
            elsif (writefifo_wr_accept = '1' and writefifo_issue_pending = '1' and
                   writefifo_issue_wb = '1') then
               wb_line_issued       <= '1';
            end if;
            
            -- Cache refill requests are one-cycle pulses. Preserve them when
            -- a higher-priority stage-4 transaction owns this FIFO cycle -
            -- and ONLY then: a request this cycle's chain below issues
            -- directly must not also be latched, or it goes out twice. The
            -- write-back owns the cycle while datacache_wb_sched, not for all
            -- of datacache_wb_busy: once its line is issued the chain lets a
            -- fill through behind it, and a request arriving in that window
            -- would be both issued and latched. The instruction cache would
            -- then take the duplicate's beats as its NEXT line's fill and mark
            -- that line valid with nothing written to it. Reachable only when
            -- a request arrives between a write-back's issue and its release,
            -- which DCACHE_WB_EARLY (the cache leaving WRITEBACKDONE before
            -- the release) allows.
            if (datacache_request = '1' and
                (datacache_wb_sched = '1' or
                 datacache_request_latched = '1' or
                 mem1_request_latched = '1' or
                 mem4_request = '1' or
                 writefifo_schedule_ready = '0')) then
               datacache_request_latched <= '1';
               -- Bits 4..3 are the fill's first qword (DCACHE_CWF_FB), zero
               -- for every other fill.
               datacache_address_latched <=
                  datacache_reqAddr(31 downto 3) & "000";
            end if;

            if (datacache_wb_sched = '1' or
                datacache_request_latched = '1' or
                mem1_request_latched = '1' or
                mem4_request = '1' or
                datacache_request = '1' or
                writefifo_schedule_ready = '0') then
               if (mem1_request = '1' or instrcache_request = '1') then
                  mem1_request_latched <= '1';
                  mem1_cache_latched   <= instrcache_request;
                  if (instrcache_request = '1') then
                     mem1_address_latched <=
                        "000" & mem1_address(28 downto 5) & "00000";
                  else
                     mem1_address_latched <=
                        "000" & mem1_address(28 downto 0);
                  end if;
               end if;            
            end if;

            -- A retained request is already backpressuring stage 4, so it must
            -- run before the request that is being held by that backpressure.
            if (writefifo_issue_pending = '1') then
               if (writefifo_wr_accept = '1') then
                  writefifo_issue_pending <= '0';
                  writefifo_issue_wb      <= '0';
               end if;
            elsif (datacache_wb_fifo_count = 4 and wb_line_issued = '0' and
                   datacache_wb_hold = '0') then
               -- The complete line goes out as ONE transaction - once its
               -- miss's fill has gone, if that fill goes first
               -- (datacache_wb_hold). Its four words
               -- stay in the staging queue - slot 0 is the line base, because
               -- the queue is empty when a write-back starts and its pointer
               -- wraps after exactly four beats - and the clk1x side reads
               -- them from there. wb_line_release, not this accept, is what
               -- frees the queue.
               if (writefifo_schedule_ready = '1') then
                  writefifo_issue_pending      <= '1';
                  writefifo_issue_wb           <= '1';
                  writefifo_Din( 63 downto  0) <= datacache_wb_fifo(0)(63 downto 0);
                  writefifo_Din( 95 downto 64) <= datacache_wb_fifo(0)(95 downto 64);
                  -- The qwords and bytes the line really holds, latched when
                  -- its first word was staged: the cache may have moved on.
                  writefifo_Din(103 downto 96) <= "0000" & wb_line_mask_93;
                  writefifo_Din(104)           <= '1';
                  writefifo_Din(105)           <= '0';
                  writefifo_Din(106)           <= '1';
                  writefifo_Din(107)           <= '0';
                  writefifo_Din(115 downto 108) <= std_logic_vector(read_sequence_93);
                  -- Every other branch assigns this a '0'. It has to: a held
                  -- signal would pass the flag on to the NEXT transaction, and
                  -- a read that looks like a line write releases the staging
                  -- queue while its words are still needed.
                  writefifo_Din(116)           <= '1';
                  writefifo_Din(117)           <= '0';
               end if;
            elsif (datacache_wb_ena = '1' or
                   (datacache_wb_fifo_count > 0 and datacache_wb_fifo_count < 4)) then
               -- Reserve this scheduler cycle while the line is still being
               -- captured. Once it is complete and issued the scheduler is
               -- free again, so the fill's request goes out right behind it.
               null;
             elsif (datacache_request_latched = '1') then
                if (writefifo_schedule_ready = '1') then
                   writefifo_issue_pending      <= '1';
                   writefifo_issue_wb           <= '0';
                   writefifo_Din( 95 downto 64) <= std_logic_vector(datacache_address_latched);
                  writefifo_Din(104)           <= '1';
                  writefifo_Din(105)           <= '1';
                  writefifo_Din(106)           <= '1';
                  writefifo_Din(107)           <= '1';
                  writefifo_Din(115 downto 108) <= std_logic_vector(read_sequence_93);
                  writefifo_Din(116)           <= '0';
               writefifo_Din(117)           <= '0';

                  -- A cache cannot normally issue a second miss while its
                  -- first is outstanding, but retaining a simultaneous pulse
                  -- here makes that interface lossless as well.
                  if (datacache_request = '1') then
                     datacache_request_latched <= '1';
                     datacache_address_latched <=
                        datacache_reqAddr(31 downto 3) & "000";
                  else
                     datacache_request_latched <= '0';
                  end if;
               end if;
             elsif (mem1_request_latched = '1') then
                if (writefifo_schedule_ready = '1') then
                   writefifo_issue_pending      <= '1';
                   writefifo_issue_wb           <= '0';
                   writefifo_Din( 95 downto 64) <= std_logic_vector(mem1_address_latched);
                  writefifo_Din(104)           <= '0';
                  writefifo_Din(105)           <= '1';
                  writefifo_Din(106)           <= mem1_cache_latched;
                  writefifo_Din(107)           <= mem1_cache_latched;
                  writefifo_Din(115 downto 108) <= std_logic_vector(read_sequence_93);
                  writefifo_Din(116)           <= '0';
               writefifo_Din(117)           <= '0';

                  if (mem1_request = '1' or instrcache_request = '1') then
                     mem1_request_latched <= '1';
                     mem1_cache_latched   <= instrcache_request;
                     if (instrcache_request = '1') then
                        mem1_address_latched <=
                           "000" & mem1_address(28 downto 5) & "00000";
                     else
                        mem1_address_latched <=
                           "000" & mem1_address(28 downto 0);
                     end if;
                  else
                     mem1_request_latched <= '0';
                  end if;
               end if;
             elsif (mem4_request = '1' and mem4_rnw = '0' and
                    writefifo_mem4_ready = '1') then
                writefifo_issue_pending      <= '1';
                writefifo_issue_wb           <= '0';
               writefifo_Din( 63 downto  0) <= mem4_dataWrite;
               writefifo_Din( 95 downto 64) <= std_logic_vector(mem4_address);
               writefifo_Din(103 downto 96) <= mem4_writeMask;
               writefifo_Din(104)           <= '1';
                writefifo_Din(105)           <= '0';
                writefifo_Din(106)           <= mem4_req64;
                writefifo_Din(107)           <= '0';
                writefifo_Din(115 downto 108) <= std_logic_vector(read_sequence_93);
                writefifo_Din(116)           <= '0';
               writefifo_Din(117)           <= '0';
             elsif (mem4_request = '1' and writefifo_mem4_ready = '1' and fast_unc_go = '0' and
                    fast_s3_launched = '0') then
                writefifo_issue_pending      <= '1';
                writefifo_issue_wb           <= '0';
                writefifo_Din( 95 downto 64) <= std_logic_vector(mem4_address);
               writefifo_Din(104)           <= '1';
               writefifo_Din(105)           <= '1';
               writefifo_Din(106)           <= mem4_req64;
               writefifo_Din(107)           <= '0';
               writefifo_Din(115 downto 108) <= std_logic_vector(read_sequence_93);
               writefifo_Din(116)           <= '0';
               writefifo_Din(117)           <= '0';
             elsif (datacache_request = '1' and
                    writefifo_schedule_ready = '1') then
                writefifo_issue_pending      <= '1';
                writefifo_issue_wb           <= '0';
                writefifo_Din( 95 downto 64) <=
                  std_logic_vector(datacache_reqAddr(31 downto 3)) & "000";
               writefifo_Din(104)           <= '1';
               writefifo_Din(105)           <= '1';
               writefifo_Din(106)           <= '1';
               writefifo_Din(107)           <= '1';
               writefifo_Din(115 downto 108) <= std_logic_vector(read_sequence_93);
               writefifo_Din(116)           <= '0';
               writefifo_Din(117)           <= '0';
             elsif ((mem1_request = '1' or instrcache_request = '1') and
                    writefifo_schedule_ready = '1') then
                writefifo_issue_pending      <= '1';
                writefifo_issue_wb           <= '0';
                writefifo_Din( 95 downto 64) <=
                  "000" & std_logic_vector(mem1_address(28 downto 0));
               writefifo_Din(104)           <= '0';
               writefifo_Din(105)           <= '1';
               writefifo_Din(106)           <= instrcache_request;
               writefifo_Din(107)           <= instrcache_request;
               writefifo_Din(115 downto 108) <= std_logic_vector(read_sequence_93);
               writefifo_Din(116)           <= '0';
               writefifo_Din(117)           <= '0';
               if (instrcache_request = '1') then
                  writefifo_Din( 95 downto 64) <=
                     "000" & std_logic_vector(mem1_address(28 downto 5)) & "00000";
               end if;
             elsif (DCRA_ON and datacache_ra_pending = '1' and
                    writefifo_mem4_ready = '1' and fast_ra_go = '0') then
                -- The data cache's read-ahead, below everything: a line fetch
                -- (117) marked as the cache's (107), so clk1x captures its four
                -- qwords as a line rather than giving them to the cache as a
                -- fill.
                writefifo_issue_pending      <= '1';
                writefifo_issue_wb           <= '0';
                writefifo_Din( 95 downto 64) <=
                   std_logic_vector(datacache_ra_addr(31 downto 5)) & "00000";
                writefifo_Din(104)           <= '1';
                writefifo_Din(105)           <= '1';
                writefifo_Din(106)           <= '1';
                writefifo_Din(107)           <= '1';
                writefifo_Din(115 downto 108) <= std_logic_vector(read_sequence_93);
                writefifo_Din(116)           <= '0';
                writefifo_Din(117)           <= '1';
                datacache_ra_pending         <= '0';
            end if;
            if (fast_ra_go = '1') then
               datacache_ra_pending <= '0';
            end if;
            -- A read-ahead that took the direct port from its ask
            -- (RA_LAUNCH_EARLY) has left: it waits for nothing, and pending
            -- would send it through the scheduler as well.
            if (DCRA_ON and datacache_ra_request = '1' and
                not (RA_LAUNCH_EARLY and fast_ra_go = '1')) then
               datacache_ra_pending <= '1';
            end if;
            
            -- A direct read leaves here, and its completion comes back here:
            -- a demand fill's as ram_done, with the same last-qword hold a
            -- bridge fill's takes below; a read-ahead's as ra_done with
            -- line_fill_1x, as a bridge read-ahead's comes; an uncached
            -- load's into the rotation below, as a bridge one's goes. An
            -- uncached load asks for its qword, bit 0 set to say so, from stage
            -- 4 (fast_unc_go) or stage 3 (fast_s3_go).
            -- Direct reads outstanding, and the newest one's first beat.
            if ((fast_go = '1' or fast_ra_go = '1' or fast_unc_go = '1' or fast_go_q = '1' or
                 fast_s3_go = '1') and fast_ret = '0') then
               fast_out <= fast_out + 1;
            elsif (not (fast_go = '1' or fast_ra_go = '1' or fast_unc_go = '1' or fast_go_q = '1' or
                        fast_s3_go = '1') and fast_ret = '1') then
               fast_out <= fast_out - 1;
            end if;
            if (fast_go = '1' or fast_ra_go = '1' or fast_unc_go = '1' or fast_go_q = '1' or
                fast_s3_go = '1') then
               fast_first_seen <= '0';
            elsif (fast_window = '1' and fast_first = '1') then
               fast_first_seen <= '1';
            end if;
            if (fast_go = '1' or fast_ra_go = '1' or fast_unc_go = '1' or fast_go_q = '1' or
                fast_s3_go = '1') then
               fast_tog_r    <= not fast_tog_r;
               fast_is_ra_r  <= fast_ra_go;
               fast_stream_r <= fast_ra_go and (datacache_ra_stream or fast_chain_term);
               fast_is_unc_r <= fast_unc_go or fast_s3_go;
               if (fast_s3_go = '1') then
                  fast_line_r <= executeMemAddress(31 downto 3) & "001";
               elsif (fast_unc_go = '1') then
                  fast_line_r <= mem4_address(31 downto 3) & "001";
               elsif (fast_ra_go = '1') then
                  fast_line_r <= fast_ra_line;
                  -- Bit 1: its qwords back on fast_ra_valid.
                  if (RA_CTL_RETURN) then
                     fast_line_r(1) <= '1';
                  end if;
               else
                  fast_line_r <= fast_line;
               end if;
            end if;
            if (fast_done_tog /= fast_done_seen) then
               if (fast_is_unc_r = '1') then
                  null;   -- after the response FIFO's own completions, below
               elsif (fast_is_ra_r = '1') then
                  datacache_ra_data <= line_fill_1x;
                  datacache_ra_done <= '1';
               elsif (datacache_fill_last = '1') then
                  datacache_fill_due <= '1';
               else
                  datacache_fill_done <= '1';
               end if;
            end if;
            -- RA_CTL_RETURN: a direct read-ahead's qwords into the staging
            -- register as they come, its completion with the fourth. The
            -- copy that reads it is over before the next line's first comes
            -- (asserted in the data cache).
            if (fast_ra_take = '1') then
               case (fast_ra_q) is
                  when "00"   => datacache_ra_data( 63 downto   0) <= fast_unc_qword;
                  when "01"   => datacache_ra_data(127 downto  64) <= fast_unc_qword;
                  when "10"   => datacache_ra_data(191 downto 128) <= fast_unc_qword;
                  when others => datacache_ra_data(255 downto 192) <= fast_unc_qword;
               end case;
               datacache_ra_wr <= '1';
               if (fast_ra_q = 3) then
                  datacache_ra_done <= '1';
               end if;
            end if;
            -- RA_CHAIN: the data cache stages the chained line at its exit.
            if (fast_chain_go = '1') then
               datacache_ra_chain_taken <= '1';
            end if;

            -- The FIFO holds its head until resp_take pops it, so the payload
            -- is stable here.
            --
            -- An UNCACHED stage-4 read is the only completion that carries
            -- data this side has to work on: capture the raw word first,
            -- register the load-aligned copy on the next cycle, and only then
            -- pulse, which keeps completion, transaction type and data atomic
            -- across the boundary. A CACHE fill's data went into the cache as
            -- beats in clk1x - the last one no later than mem_done - and the
            -- completion itself carries nothing. Those pulse on the cycle they
            -- are taken, or the one after for a data cache fill whose access
            -- is to the line's last qword (below), instead of two later.
            if (response_cdc_deliver_93 = '1') then
               mem_finished_read       <= '1';
               response_cdc_deliver_93 <= '0';
            elsif (response_cdc_pending_93 = '1') then
               mem_finished_dataRot    <= std_logic_vector(read4_uncachedData);
               response_cdc_pending_93 <= '0';
               response_cdc_deliver_93 <= '1';
            elsif (resp_fifo_empty = '0') then
               -- resp_take is this same condition, and pops the FIFO.
               if (DCRA_ON and resp_fifo_dout(105) = '1') then
                  -- The data cache's read-ahead is back. Stage its four
                  -- qwords; the cache decides what they are worth.
                  datacache_ra_data        <= line_fill_1x;
                  datacache_ra_done        <= '1';
               else
                  -- Everything that is not a line fetch carries a data word,
                  -- an instruction fetch included: stage 1 takes an UNCACHED
                  -- opcode from mem_finished_dataRead beside
                  -- mem_finished_instr, so this is not the uncached load's
                  -- alone. Dropping it here hangs the boot ROM.
                  mem_finished_dataRead <= resp_fifo_dout(63 downto 0);
                  if (resp_fifo_dout(64) = '0') then
                     -- An instruction fetch. A cached one is beats in clk1x
                     -- and this is only its ram_done; an uncached one is the
                     -- word just captured, which is registered on this same
                     -- edge and therefore valid in the cycle stage 1 reads it.
                     mem_finished_instr <= '1';
                  elsif (resp_fifo_dout(106) = '1') then
                     -- A data cache fill: beats in clk1x, the last one no
                     -- later than mem_done - on its own clock, for an SDRAM
                     -- read. Its ram_done. FILL reads or writes its access's
                     -- qword through port b on the edge ram_done arrives,
                     -- half a clk1x cycle after port a wrote the last beat,
                     -- and a dual-clock M10K's access to an address the
                     -- other port is writing is undefined until the writing
                     -- clock's next edge. Only the last qword can be that
                     -- address, so a fill whose access is to it waits a
                     -- cycle.
                     if (datacache_fill_last = '1') then
                        datacache_fill_due <= '1';
                     else
                        datacache_fill_done <= '1';
                     end if;
                  elsif (UNC_BRIDGE_FAST_DONE and read4_useLoadType = LOADTYPE_QWORD) then
                     -- An uncached 64-bit load: qword-aligned, so its
                     -- rotation is none, and it completes on this edge.
                     mem_finished_dataRot    <= resp_fifo_dout(63 downto 0);
                     mem_finished_read       <= '1';
                  else
                     -- An uncached stage-4 read, the one completion whose
                     -- data this side still has to rotate. Two more cycles.
                     response_cdc_pending_93 <= '1';
                  end if;
               end if;
            end if;
            -- A direct uncached load's, the same way. It is the only memory
            -- operation of the CPU's outstanding, so nothing above is using
            -- the rotation (asserted). With UNC_FAST_DONE it skips it: a
            -- qword-aligned load's rotation is none (read4_uncachedRot "00"
            -- for every load type at a qword address), so it completes on
            -- this edge. Its qword goes only where its completion reads it:
            -- an uncached opcode taken beside it is in mem_finished_dataRead.
            if (fast_done_tog /= fast_done_seen and fast_is_unc_r = '1') then
               if (UNC_FAST_DONE) then
                  mem_finished_dataRot <= fast_unc_q_1x;
                  mem_finished_read    <= '1';
               else
                  mem_finished_dataRead   <= fast_unc_q_1x;
                  response_cdc_pending_93 <= '1';
               end if;
            end if;
            -- And on fast_unc_valid, as UNC_FAST_DONE has it.
            if (fast_unc_ret = '1') then
               mem_finished_dataRot <= fast_unc_qword;
               mem_finished_read    <= '1';
            end if;

         end if;
      end if;
   end process;
   
   iSyncFifo: entity mem.SyncFifoFallThroughMLAB
   generic map
   (
      SIZE              => 8,
      DATAWIDTH         => 118, -- 108-bit transaction, 8-bit read sequence tag, 1-bit whole-line write, 1-bit read-ahead line fetch
      NEARFULLDISTANCE  => 4
   )
   port map
   ( 
      clk       => clk93,
      reset     => reset_93,  
      Din       => writefifo_Din,     
      Wr        => writefifo_fifo_wr, 
      Full      => writefifo_Full,
      Dout      => writefifo_Dout,    
      Rd        => writefifo_Rd,      
      Empty     => writefifo_Empty
   );

   -- Keep the established full indication and make the first ownership
   -- failure sticky through the existing protocol-error output.
   error_fifo <= writefifo_Full or debug_response_status_reg(31);

   -- Pending is the producer-valid bit. The payload is loaded once and held
   -- unchanged until the FIFO acknowledges it.
   writefifo_wr <= writefifo_issue_pending;

   writefifo_rd_accept <= writefifo_Rd and not writefifo_Empty;
   -- A request with nothing queued ahead of it and the mailbox free goes
   -- straight into the mailbox on the edge the FIFO would have taken it, a
   -- clk93 cycle sooner than through the FIFO and out of it again - and,
   -- with the clocks aligned, a whole clk1x cycle sooner on the other side.
   -- Order is kept: Empty falls on the edge that writes the FIFO, so while
   -- it is set nothing is queued. The request is still ACCEPTED - the read
   -- tags, the read-ahead's store report and the write-back's issue all see
   -- it as before - it just never occupies the FIFO.
   writefifo_bypass <= '1' when (writefifo_issue_pending = '1' and
                                 writefifo_Empty = '1' and
                                 write_cdc_busy_93 = '0') else '0';
   writefifo_fifo_wr <= writefifo_wr and not writefifo_bypass;
   writefifo_wr_accept <= writefifo_wr and
                          (not writefifo_Full or writefifo_rd_accept);
   writefifo_schedule_ready <= '1' when
      (writefifo_issue_pending = '0' and
       (writefifo_Full = '0' or writefifo_rd_accept = '1')) else '0';

   -- The line's four words are released together, when clk1x reports it has
   -- handed them over (wb_line_release below).
   -- THE CROSSING (see its declarations): the other side's register, or its
   -- synchroniser.
   write_cdc_req_in_1x <= write_cdc_req_93 when SYNC_CROSSING else write_cdc_req_sync_1x;
   write_cdc_ack_in_93 <= write_cdc_ack_1x when SYNC_CROSSING else write_cdc_ack_sync_93;
   wb_line_done_in_93  <= wb_line_done_1x  when SYNC_CROSSING else wb_line_done_sync_93;

   wb_line_release <= '1' when (wb_line_done_in_93 /= wb_line_done_seen_93) else '0';
   datacache_wb_busy <= '1' when
      (datacache_wb_fifo_count > 0 or
       (writefifo_issue_pending = '1' and writefifo_issue_wb = '1') or
       datacache_wb_ena = '1') else '0';
   -- Exactly the scheduler branches through which the write-back pre-empts a
   -- request: its issue pending, the whole line staged and not yet issued
   -- nor held behind its miss's fill (a held line does not take the cycle,
   -- so a request then goes out directly and must not be latched as well),
   -- or words still arriving.
   datacache_wb_sched <= '1' when
      ((writefifo_issue_pending = '1' and writefifo_issue_wb = '1') or
       (datacache_wb_fifo_count = 4 and wb_line_issued = '0' and datacache_wb_hold = '0') or
       (datacache_wb_fifo_count > 0 and datacache_wb_fifo_count < 4) or
       datacache_wb_ena = '1') else '0';

   -- synthesis translate_off
   -- Each cache has at most ONE line fill in flight, so a second fill read
   -- from the same cache accepted into the write FIFO before the first one's
   -- completion is a duplicate by definition. Its only other symptom shows
   -- up much later; this names it where it happens.
   process(clk93)
      variable ic_out : boolean := false;
      variable dc_out : boolean := false;
   begin
      if rising_edge(clk93) then
         if (reset_93 = '1') then
            ic_out := false; dc_out := false;
         else
            if (mem_finished_instr = '1') then ic_out := false; end if;
            if (datacache_fill_done = '1') then dc_out := false; end if;
            if (writefifo_wr_accept = '1' and writefifo_Din(105) = '1' and writefifo_Din(116) = '0') then
               if (writefifo_Din(104) = '0' and writefifo_Din(107) = '1') then
                  assert not ic_out
                     report "a second instruction-cache line fill issued while one is outstanding"
                     severity failure;
                  ic_out := true;
               elsif (writefifo_Din(104) = '1' and writefifo_Din(107) = '1' and writefifo_Din(117) = '0') then
                  assert not dc_out
                     report "a second data-cache fill issued while one is outstanding"
                     severity failure;
                  dc_out := true;
               end if;
            end if;
         end if;
      end if;
   end process;
   -- synthesis translate_on

   -- The line's mask is latched with its first word (wb_line_mask_93), and
   -- with DCACHE_WB_EARLY the cache leaves for ALLOC with its line still
   -- staged. What must hold - no second write-back over a staged line - is
   -- the staging check below, and WRITEBACK1ADDR waiting on fifo_block,
   -- which datacache_wb_busy holds high while any word is staged.

   process(clk93)
      variable held_valid : boolean := false;
      variable held_data  : std_logic_vector(117 downto 0) := (others => '0');
   begin
      if rising_edge(clk93) then
         if reset_93 = '1' then
            held_valid := false;
         elsif writefifo_issue_pending = '1' and
               writefifo_wr_accept = '0' then
            if held_valid then
               assert writefifo_Din = held_data
                  report "write FIFO request changed while backpressured"
                  severity failure;
            end if;
            held_data := writefifo_Din;
            held_valid := true;
         else
            held_valid := false;
         end if;
      end if;
   end process;

-- synthesis translate_off
   -- An instruction fetch request is issued the cycle it arrives or latched
   -- for a later one, never neither: otherwise stage 1 waits for ever.
   process (clk93)
      variable req_d : boolean := false;
   begin
      if rising_edge(clk93) then
         if (reset_93 = '1') then
            req_d := false;
         else
            if (req_d) then
               assert (mem1_request_latched = '1' or
                       (writefifo_issue_pending = '1' and writefifo_Din(104) = '0'))
                  report "an instruction fetch request was neither issued nor latched"
                  severity failure;
            end if;
            req_d := (mem1_request = '1' or instrcache_request = '1');
         end if;
      end if;
   end process;
-- synthesis translate_on

-- synthesis translate_off
   -- LOAD_MERGE_BYPASS's one assumption: a flagged merge load entered stage 4
   -- on the edge the load it merges behind left it, with no bubble between
   -- (executeMergeBehind), so while it is in stage 4 the writeback slot holds
   -- that load - the same target register - and writebackData is its result.
   process(clk93)
   begin
      if rising_edge(clk93) then
         if (reset_93 = '0' and ce_93 = '1') then
            assert not (executeMergeFwd = '1' and executeNew = '1' and stall4 = '0' and
                        (executeMergeBehind = '0' or writebackTarget /= resultTarget))
               report "a merge load flagged to skip its bubble is not straight behind the load it merges into"
               severity failure;
            -- BOOT_HOLD's rule: nothing reaches the data cache while it
            -- clears its tags, where it would be dropped.
            assert not (datacache_clear_busy = '1' and
                        (datacache_readena = '1' or datacache_writeena = '1' or
                         cache_commandEnableD = '1'))
               report "a data access reached the data cache while it was clearing its tags - it is lost"
               severity failure;
         end if;
      end if;
   end process;

   -- THE CROSSING's bundled data, as checks rather than prose(see its
   -- declarations). Under SYNC_CROSSING the margin behind each is one clock
   -- edge, and a late write is invisible to a data check whenever the stale
   -- value happens to equal the new one - a line of zeros after another.
   --
   -- A fetched line is complete when its completion enters the response
   -- FIFO: clk93 copies line_fill_1x on the edge it takes that completion,
   -- which can be the very next one. So no beat may land in it on any edge
   -- AFTER the completion's, until the next line fetch starts. Detected as a
   -- change of value, so a late write by any path is caught, not only one
   -- through the capture below: a change seen at edge N was written at N-1,
   -- hence the check arms one edge after the completion's.
   process(clk1x)
      variable line_done  : boolean := false;
      variable line_armed : boolean := false;
      variable line_prev  : std_logic_vector(255 downto 0) := (others => '0');
   begin
      if rising_edge(clk1x) then
         if (reset_1x = '1') then
            line_done  := false;
            line_armed := false;
         else
            if ((line_active_1x = '1' or (fast_window = '1' and fast_is_ra_r = '1')) and
                resp_fifo_wr = '0') then
               line_done  := false;
               line_armed := false;
            end if;
            assert not (line_armed and line_fill_1x /= line_prev)
               report "a fetched line changed after its completion entered the response FIFO"
               severity failure;
            line_armed := line_done;
            if (resp_fifo_wr = '1' and line_active_1x = '1') then
               line_done := true;
            end if;
         end if;
         line_prev := line_fill_1x;
      end if;
   end process;

   -- A dirty line's words sit in the staging queue until clk1x has copied
   -- them (wb_line_release), so the cache must not stage the next victim's
   -- first word into it before then: the queue would drop it. That includes
   -- the release's own cycle - the queue takes a word only below four, and
   -- the release empties it on the same edge.
   process(clk93)
   begin
      if rising_edge(clk93) then
         if (reset_93 = '0') then
            assert not (datacache_wb_ena = '1' and datacache_wb_fifo_count = 4)
               report "a write-back word was staged while the queue still held the previous line"
               severity failure;
         end if;
      end if;
   end process;
-- synthesis translate_on

    writefifo_block <= '1' when
      (writefifo_issue_pending = '1' or
       writefifo_cnt >= 4 or
       (writefifo_cnt = 3 and writefifo_wr = '1') or
       datacache_wb_busy = '1' or
       datacache_request_latched = '1' or
       mem1_request_latched = '1') else '0';

   -- Stage 4 uses a real ready/valid handshake. Higher-priority writebacks
   -- and retained refills must finish before its request may enter the FIFO.
   writefifo_mem4_ready <= '1' when
      (writefifo_block = '0' and datacache_wb_busy = '0' and
       datacache_request_latched = '0' and
       mem1_request_latched = '0' and
       writefifo_schedule_ready = '1') else '0';
   
   process (clk1x)
   begin
      if (rising_edge(clk1x)) then
      
         write_cdc_req_meta_1x <= write_cdc_req_93;
         write_cdc_req_sync_1x <= write_cdc_req_meta_1x;
         mem_request           <= '0';
      
         if (reset_1x = '1') then
         
            memoryMuxStage4       <= '0'; 
            memstate              <= MEMSTATE_IDLE;
            mem_line_write        <= '0';
            mem_line_fb           <= '0';
            wb_line_done_1x       <= '0';
            write_cdc_req_meta_1x <= '0';
            write_cdc_req_sync_1x <= '0';
            write_cdc_req_seen_1x <= '0';
            write_cdc_ack_1x      <= '0';
             memory_read_tag_1x       <= (others => '0');
             memory_read_address_1x   <= (others => '0');
             line_active_1x         <= '0';

         else

            -- A read-ahead line fetch's beats, in address order. The bridge
            -- raises the last one no later than mem_done, and line_active_1x
            -- is still set on that cycle, so all four are in before the
            -- completion is sent.
            if (DCRA_ON and line_active_1x = '1' and ddr3_DOUT_READY = '1') then
               case (line_beat_1x) is
                  when "00"   => line_fill_1x( 63 downto   0) <= ddr3_DOUT;
                  when "01"   => line_fill_1x(127 downto  64) <= ddr3_DOUT;
                  when "10"   => line_fill_1x(191 downto 128) <= ddr3_DOUT;
                  when others => line_fill_1x(255 downto 192) <= ddr3_DOUT;
               end case;
               line_beat_1x <= line_beat_1x + 1;
            -- A direct read-ahead's, from the direct port, in the same order.
            -- Only one read-ahead is ever in flight, so the two never meet.
            elsif (FAST_ON and DCRA_ON and fast_is_ra_r = '1' and fast_window = '1' and
                   fast_beat = '1') then
               if (fast_first = '1') then
                  line_fill_1x(63 downto 0) <= fast_qword;
                  line_beat_1x <= "01";
               else
                  case (line_beat_1x) is
                     when "01"   => line_fill_1x(127 downto  64) <= fast_qword;
                     when "10"   => line_fill_1x(191 downto 128) <= fast_qword;
                     when others => line_fill_1x(255 downto 192) <= fast_qword;
                  end case;
                  line_beat_1x <= line_beat_1x + 1;
               end if;
            end if;

            -- The previous transaction ends.
            if (memstate = MEMSTATE_BUSY and mem_done = '1') then
               -- resp_fifo_din / resp_fifo_wr are concurrent above, so
               -- the response enters the FIFO on THIS edge. It cannot
               -- be full: the bridge only started this transaction
               -- because there was room for its answer.
               memstate          <= MEMSTATE_IDLE;
               if (memoryMuxStage4 = '1') then
                  datacache_active <= '0';
               else
                  instrcache_active <= '0';
               end if;
               if (mem_line_write = '1') then
                  mem_line_write  <= '0';
                  mem_line_fb     <= '0';
               end if;
               line_active_1x <= '0';
            end if;

            -- The next request is taken in IDLE, or on the edge the previous
            -- one ends, so a request already waiting in the mailbox loses no
            -- clock to IDLE. resp_fifo_full: the bridge may start again as
            -- soon as there is somewhere to put the answer, not once the CPU
            -- has taken the last one; on the ending edge the FIFO must have
            -- been empty, as it may take that transaction's answer now.
            -- resp_fifo_wempty also holds back a LINE fetch, which would
            -- overwrite line_fill_1x under a completion clk93 has not read
            -- yet; one waits for IDLE.
            if (ce_1x = '1' and write_cdc_req_in_1x /= write_cdc_req_seen_1x and
                ((memstate = MEMSTATE_IDLE and resp_fifo_full = '0' and
                  (write_cdc_data_93(117) = '0' or resp_fifo_wempty = '1')) or
                 (memstate = MEMSTATE_BUSY and mem_done = '1' and
                  resp_fifo_wempty = '1' and write_cdc_data_93(117) = '0'))) then

               write_cdc_req_seen_1x <= write_cdc_req_in_1x;
               write_cdc_ack_1x      <= write_cdc_req_in_1x;
               memstate          <= MEMSTATE_BUSY;
               mem_request       <= '1';
               memoryMuxStage4   <= '1';
               mem_dataWrite     <= write_cdc_data_93(63 downto 0);
               mem_address       <= unsigned(write_cdc_data_93(95 downto 64));
               mem_writeMask     <= write_cdc_data_93(103 downto 96);
               memoryMuxStage4   <= write_cdc_data_93(104);
               mem_rnw           <= write_cdc_data_93(105);
               mem_req64         <= write_cdc_data_93(106);
               memory_read_tag_1x <= write_cdc_data_93(115 downto 108);
               memory_read_address_1x <= write_cdc_data_93(95 downto 64);
               
               mem_size          <= "001";
               mem_line_ra       <= '0';
               
               if (write_cdc_data_93(104) = '1' and write_cdc_data_93(107) = '1' and
                   write_cdc_data_93(117) = '0') then
                  -- The KI data cache fills a 32-byte line as four
                  -- 64-bit DDR words (see cpu_datacache.vhd). Not its
                  -- read-ahead: that is a line fetch, below.
                  mem_size          <= "100";
                  datacache_active  <= '1';
               end if;
               
               if (write_cdc_data_93(104) = '0' and write_cdc_data_93(107) = '1') then
                  mem_size          <= "100";
                  instrcache_active  <= '1';
               end if;

               if (DCRA_ON and write_cdc_data_93(117) = '1') then
                  -- The data cache's read-ahead: four qwords,
                  -- captured above as they arrive. Not datacache_active
                  -- - the D-cache would take the beats as a fill.
                  mem_size          <= "100";
                  mem_line_ra       <= '1';
                  line_active_1x  <= '1';
                  line_beat_1x    <= "00";
               end if;

               if (write_cdc_data_93(116) = '1') then
                  -- One transaction for the whole dirty line. The
                  -- four words are read straight out of the clk93
                  -- staging queue, which holds them still until this
                  -- cycle - the same bundled-data rule as this
                  -- mailbox's own payload. mem_writeMask carries the
                  -- qwords to write, set above from the payload.
                  mem_line_write <= '1';
                  mem_line_fb    <= is_fb_line(unsigned(write_cdc_data_93(95 downto 64)));
                  mem_line_bytes <= wb_line_bytes_93;
                  mem_line_data  <= datacache_wb_fifo(3)(63 downto 0) &
                                    datacache_wb_fifo(2)(63 downto 0) &
                                    datacache_wb_fifo(1)(63 downto 0) &
                                    datacache_wb_fifo(0)(63 downto 0);
                  -- Released HERE, not when the bridge acknowledges:
                  -- the words are in mem_line_data from this edge, so
                  -- the queue is free, and the cache is waiting on it
                  -- to request its fill. Releasing on the ack instead
                  -- would hold every dirty miss in the cache's own
                  -- WRITEBACK states.
                  wb_line_done_1x <= not wb_line_done_1x;
               end if;

            end if;
            
         end if;
      end if;
   end process;
   
--##############################################################
--############################### FPU register file
--##############################################################
   iregisterfileFPU1LO : entity mem.RamMLAB
	GENERIC MAP 
   (
      width                               => 32,
      widthad                             => 5
	)
	PORT MAP (
      inclock    => clk93,
      wren       => FPUregs_wren_a(0),
      data       => FPUregs_data_a(31 downto 0),
      wraddress  => FPUregs_address_a,
      rdaddress  => FPUregs1_address_b,
      q          => FPUregs1_q_b(31 downto 0)
	);
   iregisterfileFPU1HI : entity mem.RamMLAB
	GENERIC MAP 
   (
      width                               => 32,
      widthad                             => 5
	)
	PORT MAP (
      inclock    => clk93,
      wren       => FPUregs_wren_a(1),
      data       => FPUregs_data_a(63 downto 32),
      wraddress  => FPUregs_address_a,
      rdaddress  => FPUregs1_address_b,
      q          => FPUregs1_q_b(63 downto 32)
	);
   
   FPUregs_wren_a    <= "11" when (ss_fpuregs_load = '1') else
                        cop1_stage4_writeMask when (ce_93 = '1' and cop1_stage4_writeEnable = '1') else 
                        FPUWriteMask          when (ce_93 = '1' and FPUWriteEnable = '1') else 
                        "00";
   
   FPUregs_data_a    <= ss_FPUregs_data                    when (ss_FPUregs_load = '1') else 
                        std_logic_vector(cop1_stage4_data) when (cop1_stage4_writeEnable = '1') else
                        std_logic_vector(FPUWriteData);
                     
   FPUregs_address_a <= std_logic_vector(ss_FPUregs_addr)    when (ss_FPUregs_load = '1') else 
                        std_logic_vector(cop1_stage4_target) when (cop1_stage4_writeEnable = '1') else
                        std_logic_vector(FPUWriteTarget);
   
   FPUregs1_address_b <= std_logic_vector(decFPUSource1);
   FPUregs2_address_b <= std_logic_vector(decFPUSource2);
   
   iregisterfileFPU2LO : entity mem.RamMLAB
	GENERIC MAP 
   (
      width                               => 32,
      widthad                             => 5
	)
	PORT MAP (
      inclock    => clk93,
      wren       => FPUregs_wren_a(0),
      data       => FPUregs_data_a(31 downto 0),
      wraddress  => FPUregs_address_a,
      rdaddress  => FPUregs2_address_b,
      q          => FPUregs2_q_b(31 downto 0)
	);
   iregisterfileFPU2HI : entity mem.RamMLAB
	GENERIC MAP 
   (
      width                               => 32,
      widthad                             => 5
	)
	PORT MAP (
      inclock    => clk93,
      wren       => FPUregs_wren_a(1),
      data       => FPUregs_data_a(63 downto 32),
      wraddress  => FPUregs_address_a,
      rdaddress  => FPUregs2_address_b,
      q          => FPUregs2_q_b(63 downto 32)
	);
   
--##############################################################
--############################### register file
--##############################################################
   iregisterfile1 : entity mem.RamMLAB
	GENERIC MAP 
   (
      width                               => 64,
      widthad                             => 5
	)
	PORT MAP (
      inclock    => clk93,
      wren       => regs_wren_a,
      data       => regs_data_a,
      wraddress  => regs_address_a,
      rdaddress  => regs1_address_b,
      q          => regs1_q_b
	);
   
   regs_wren_a    <= '1' when (ss_regs_load = '1') else
                     '1' when (ce_93 = '1' and writebackWriteEnable = '1') else 
                     '0';
   
   regs_data_a    <= ss_regs_data when (ss_regs_load = '1') else 
                     std_logic_vector(writebackData);
                     
   regs_address_a <= std_logic_vector(ss_regs_addr) when (ss_regs_load = '1') else 
                     std_logic_vector(writebackTarget);
   
   regs1_address_b <= std_logic_vector(decSource1);
   regs2_address_b <= std_logic_vector(decSource2);
   
   iregisterfile2 : entity mem.RamMLAB
	GENERIC MAP 
   (
      width                               => 64,
      widthad                             => 5
	)
	PORT MAP (
      inclock    => clk93,
      wren       => regs_wren_a,
      data       => regs_data_a,
      wraddress  => regs_address_a,
      rdaddress  => regs2_address_b,
      q          => regs2_q_b
	);
   
   --iregisterfileSS : entity mem.RamMLAB
	--GENERIC MAP 
   --(
   --   width                               => 64,
   --   widthad                             => 5
	--)
	--PORT MAP (
   --   inclock    => clk93,
   --   wren       => regs_wren_a,
   --   data       => regs_data_a,
   --   wraddress  => regs_address_a,
   --   rdaddress  => regsSS_address_b,
   --   q          => regsSS_q_b
	--);

--##############################################################
--############################### stage 1
--##############################################################
   
   cache_commandEnableI <= executeICacheEnable when (stall = 0) else '0';
   
   -- Driven combinationally, not registered a cycle later in the clk1x
   -- process, so a fill's completion enters the FIFO ON the mem_done edge.
   -- Every source here is stable at mem_done. The FIFO ignores a write while
   -- its own reset_wr is high, so reset needs no term.
   resp_fifo_din <= datacache_active &
                    line_active_1x &
                    memory_read_address_1x & memory_read_tag_1x &
                    memoryMuxStage4 & mem_dataRead;
   resp_fifo_wr  <= '1' when (memstate = MEMSTATE_BUSY and mem_done = '1' and
                              mem_rnw = '1') else '0';

   iresponse_fifo : entity work.cpu_cdc_fifo
   generic map
   (
      WIDTH     => 107,
      ADDR_BITS => 1,
      SYNC      => SYNC_CROSSING
   )
   port map
   (
      clk_wr   => clk1x,
      reset_wr => reset_1x,
      wr       => resp_fifo_wr,
      din      => resp_fifo_din,
      full     => resp_fifo_full,
      wr_empty => resp_fifo_wempty,

      clk_rd   => clk93,
      reset_rd => reset_93,
      rd       => resp_fifo_rd,
      dout     => resp_fifo_dout,
      empty    => resp_fifo_empty
   );

   icpu_instrcache : entity work.cpu_instrcache
   generic map
   (
      LITTLE_ENDIAN => LITTLE_ENDIAN
   )
   port map
   (
      clk1x             => clk1x,
      clk93             => clk93,
      reset_1x          => reset_1x,
      reset_93          => reset_93,
      ce_93             => ce_93,
      
      ram_request       => instrcache_request,
      ram_active        => instrcache_active,
      ram_grant         => rdram_granted2X,
      ram_done          => mem_finished_instr,
      ddr3_DOUT         => ddr3_DOUT,      
      ddr3_DOUT_READY   => ddr3_DOUT_READY,
      
      read_select       => FetchAddrSelect,
      read_index1       => FetchIndex1,
      read_index2       => FetchIndex2,
      read_addrCompare1 => FetchAddrTLBMuxed1,
      read_addrCompare2 => FetchAddrTLBMuxed2,
      read_hit          => instrcache_hit,
      read_data         => instrcache_data,
      
      fill_request      => instrcache_fill,
      fill_addrData     => mem1_address(31 downto 0),
      fill_addrTag      => fill_addrTag,
      fill_done         => instrcache_fill_done,
      
      CacheCommandEna   => cache_commandEnableI,
      CacheCommand      => executeCacheCommand,
      CacheCommandAddr  => executeMemAddress,
      
      TagLo_Valid       => TagLo_Valid,
      TagLo_Addr        => TagLo_Addr,
                            
      SS_reset          => SS_reset
   );
   
   fetchCache1 <= '0' when (INSTRCACHEON = '0') else
                  TLB_instrUseCache when (TLB_instrMapped1 = '1') else
                  '1' when (FetchAddr1(31 downto 29) = "100") else  -- todo: only in kernelmode and only in 32bit mode
                  '0';

   fetchCache2 <= '0' when (INSTRCACHEON = '0') else
                  TLB_instrUseCache when (TLB_instrMapped2 = '1') else
                  '1' when (FetchAddr2(31 downto 29) = "100") else  -- todo: only in kernelmode and only in 32bit mode
                  '0';

   fetchCache <= fetchCache2 when (FetchAddrSelect = '1') else fetchCache1;
   
   FetchAddr <= FetchAddr2 when (FetchAddrSelect = '1') else FetchAddr1;
   
   FetchAddrTLBMuxed1 <= TLB_instrAddrOutFound when (TLB_instrMapped1 = '1') else FetchAddr1(31 downto 0);
   FetchAddrTLBMuxed2 <= TLB_instrAddrOutFound when (TLB_instrMapped2 = '1') else FetchAddr2(31 downto 0);

   -- running from 64 bit sections currently not fully supported to not screw up FPGA route timing
   -- kusegUnmapped is Status.ERL: while it is set, region < 4 is unmapped and the
   -- TLB must not be consulted for it. See the note in cpu_cop0.vhd.
   TLB_instrMapped1 <= '0' when INSTR_KSEG_ONLY else
                       '1' when (region64 = '1' and FetchAddr1(63 downto 60) < 8 and kusegUnmapped = '0') else
                       '1' when (region64 = '0' and privilegeMode = "00" and ((FetchAddr1(31 downto 29) < 4 and kusegUnmapped = '0') or FetchAddr1(31 downto 29) = 6 or FetchAddr1(31 downto 29) = 7)) else
                       '1' when (region64 = '0' and privilegeMode = "01" and ((FetchAddr1(31 downto 29) < 4 and kusegUnmapped = '0') or FetchAddr1(31 downto 29) = 6)) else
                       '1' when (region64 = '0' and privilegeMode = "10" and (FetchAddr1(31 downto 29) < 4 and kusegUnmapped = '0')) else
                       '0';

   TLB_instrMapped2 <= '0' when INSTR_KSEG_ONLY else
                       '1' when (region64 = '1' and FetchAddr2(63 downto 60) < 8 and kusegUnmapped = '0') else
                       '1' when (region64 = '0' and privilegeMode = "00" and ((FetchAddr2(31 downto 29) < 4 and kusegUnmapped = '0') or FetchAddr2(31 downto 29) = 6 or FetchAddr2(31 downto 29) = 7)) else
                       '1' when (region64 = '0' and privilegeMode = "01" and ((FetchAddr2(31 downto 29) < 4 and kusegUnmapped = '0') or FetchAddr2(31 downto 29) = 6)) else
                       '1' when (region64 = '0' and privilegeMode = "10" and (FetchAddr2(31 downto 29) < 4 and kusegUnmapped = '0')) else
                       '0';

   TLB_instrMapped <= TLB_instrMapped2 when (FetchAddrSelect = '1') else TLB_instrMapped1;
                      
   TLB_instrReq <= '1' when (TLB_instrMapped = '1' and (stall = 0 or TLB_ss_load = '1')) else '0';

   process (clk93)
   begin
      if (rising_edge(clk93)) then
         if (reset_93 = '1') then
            boot_hold <= '1';
         elsif (ce_93 = '1' and datacache_clear_busy = '0') then
            boot_hold <= '0';
         end if;
      end if;
   end process;
   
   process (clk93)
   begin
      if (rising_edge(clk93)) then
      
         instrcache_fill <= '0';
         mem1_request    <= '0';
         TLB_ss_load     <= '0';
         
         -- BOOT_HOLD. Out of reset the data cache clears its tags for 256
         -- cycles (CLEARCACHE), and it takes an access only in IDLE: one
         -- presented during the clear is dropped, and stage 4 waits for its
         -- done for ever. The KI boot ROM first reaches cached data over a
         -- hundred uncached fetches in, long after; code entering the ROM's
         -- reader directly reaches it much sooner. So
         -- stage 1 stays at the reset vector until the clear ends and sends
         -- the first fetch, as one request, on that cycle. The instruction
         -- cache needs none of this: it latches a fill asked for while it
         -- clears.
         if (reset_93 = '1' or boot_hold = '1') then

            PCold0         <= (others => '0');
            mem1_request   <= (not TLB_instrMapped) and not (reset_93 or datacache_clear_busy);
            TLB_ss_load    <= TLB_instrMapped and not (reset_93 or datacache_clear_busy);
            if (ss_in(16)(3) = '1') then
               mem1_address   <= unsigned(ss_in(5)(31 downto 0)); -- last was branch -> should be patched in the savestate already
               fill_addrTag   <= unsigned(ss_in(5)(31 downto 0));
               PC             <= unsigned(ss_in(5)); 
            else
               mem1_address   <= unsigned(ss_in(0)(31 downto 0)); -- x"FFFFFFFFBFC00000";    
               fill_addrTag   <= unsigned(ss_in(0)(31 downto 0));
               PC             <= unsigned(ss_in(0)); -- x"FFFFFFFFBFC00000";                    
            end if;
            stall1         <= '1';
            fetchReady     <= '1';
            useCached_data <= '0';
            opcode0        <= (others => '0'); --unsigned(ss_in(14));
         
         elsif (ce_93 = '1') then

            if (stall = 0) then
               fetchReady <= '0';
            end if;
            
            if (INSTRCACHEON = '1') then
               cacheHitLast <= instrcache_hit;
            else
               cacheHitLast <= '0';
            end if;
            if (useCached_data = '1' and cacheHitLast = '1' and stall(4 downto 1) > 0 and stall1 = '0') then
               useCached_data <= '0';
               opcode0        <= unsigned(instrcache_data);
            end if;
         
            if (stall1 = '1') then
            
               if (instrcache_fill_done = '1' and useCached_data = '1') then
                  useCached_data <= '0';
                  stall1         <= '0';
                  opcode0        <= unsigned(instrcache_data);
               elsif (mem_finished_instr = '1' and useCached_data = '0') then
                  stall1         <= '0';
                  opcode0        <= bus_to_cpu32(mem_finished_dataRead(31 downto 0));
               end if;
               
               if (TLB_instrUnStall = '1') then
                  if (exceptionStage1 = '1') then
                     stall1         <= '0';
                     opcode0        <= (others => '0');
                     useCached_data <= '0';
                  else
                     mem1_address    <= TLB_instrAddrOutLookup;
                     useCached_data  <= TLB_instrUseCache and INSTRCACHEON;
                     if (TLB_instrUseCache = '1' and INSTRCACHEON = '1') then
                        instrcache_fill <= '1';
                     else
                        mem1_request    <= '1';
                     end if;
                  end if;
               end if;
            
            elsif (stall = 0 or fetchReady = '0') then
            
               PCold0             <= FetchAddr;
               PC                 <= FetchAddr;
               useCached_data     <= fetchCache;
               fetchReady         <= '1';
               
               if (TLB_instrMapped = '1') then
                  mem1_address <= TLB_instrAddrOutFound;
                  fill_addrTag <= FetchAddr(31 downto 0);
               else
                  mem1_address <= FetchAddr(31 downto 0);
                  fill_addrTag <= FetchAddr(31 downto 0);
               end if;
      
               if (TLB_instrStall = '1') then
                  stall1          <= '1'; 
               elsif (fetchCache = '1') then
                  if (instrcache_hit = '0') then
                     instrcache_fill    <= '1';
                     stall1             <= '1';
                  end if;
               else
                  mem1_request    <= '1';
                  stall1          <= '1';     
               end  if;  
               
            end if;
              
         end if;
      end if;
     
   end process;
   
   
--##############################################################
--############################### stage 2
--##############################################################
   
   opcodeCacheMuxed <= unsigned(instrcache_data) when (useCached_data = '1') else 
                       opcode0;     
                       
   decImmData    <= opcodeCacheMuxed(15 downto 0);
   decJumpTarget <= opcodeCacheMuxed(25 downto 0);
   decSource1    <= opcodeCacheMuxed(25 downto 21);
   decSource2    <= opcodeCacheMuxed(20 downto 16);
   decOP         <= opcodeCacheMuxed(31 downto 26);
   decFunct      <= opcodeCacheMuxed(5 downto 0);
   decShamt      <= opcodeCacheMuxed(10 downto 6);
   decRD         <= opcodeCacheMuxed(15 downto 11);
   decTarget     <= opcodeCacheMuxed(20 downto 16) when (opcodeCacheMuxed(31 downto 26) > 0) else opcodeCacheMuxed(15 downto 11);                  

   process (opcodeCacheMuxed, fpuRegMode, decOP)
   begin
      decFPUSource1 <= opcodeCacheMuxed(15 downto 11);
      decFPUSource2 <= opcodeCacheMuxed(20 downto 16);
   
      if (fpuRegMode = '0') then
         decFPUSource1(0) <= '0';
         if (decOP = 16#39# or decOP = 16#3D#) then -- SWC1 and SDC1
            decFPUSource2(0) <= '0';
         end if;
      end if;
  
   end process;
   
   decRequiresFPUreg1 <= '1' when (decOP = 16#11# and (decSource1(4) = '1' or decSource1(3 downto 1) = 0)) else 
                         '0';
                         
   -- can be optimized to only request opcodes that really need 2 ops
   decRequiresFPUreg2 <= '1' when (decOP = 16#11# and (decSource1(4) = '1' or decSource1(3 downto 1) = 0)) else 
                         '1' when (decOP = 16#39# or decOP = 16#3D#) else
                         '0';
   
   decFPUForwardUse <= (decodeFPUCommandEnable or decodeFPUTransferEnable) when (decRequiresFPUreg1 = '1' and decodeFPUTarget(4 downto 1) = decFPUSource1(4 downto 1)) else
                       (decodeFPUCommandEnable or decodeFPUTransferEnable) when (decRequiresFPUreg2 = '1' and decodeFPUTarget(4 downto 1) = decFPUSource2(4 downto 1)) else
                       '0';

   process (clk93)
   begin
      if (rising_edge(clk93)) then
      
         error_instr  <= '0';
      
         if (reset_93 = '1') then
         
            stall2           <= '0';
            decodeNew        <= '0';
            decodeNewPulse   <= '0';
            -- Cleared for the same reason as pcOld0 in stage 1: a stale pc or
            -- opcode surviving a reset is indistinguishable from a real decode
            -- to anything watching this stage.
            pcOld1           <= (others => '0');
            opcode1          <= (others => '0');
            decode_irq       <= '0';
            decodeBranchType <= BRANCH_OFF;

         elsif (ce_93 = '1') then

            decodeNewPulse <= '0';

            if (stall = 0) then

               decodeNew      <= '0';
               decodeMergeFwd <= '0';

               if (exception = '1') then

                  decode_irq <= '0';

               elsif (fetchReady = '1') then

                  decodeNew        <= '1';
                  decodeNewPulse   <= '1';
                  decodeMergeFwd   <= merge_bypass;

                  pcOld1           <= pcOld0;
                  opcode1          <= opcodeCacheMuxed;

                  decodeImmData    <= decImmData;   
                  decodeJumpTarget <= decJumpTarget;
                  decodeSource1    <= decSource1;
                  decodeSource2    <= decSource2;
                  decodeShamt      <= '0' & decShamt;     
                  decodeRD         <= decRD;        
                  decodeTarget     <= decTarget;    
                  decodeFPUSource1 <= decFPUSource1;
                  decodeFPUSource2 <= decFPUSource2;
                  
                  -- operand fetching
                  decodeValue1     <= unsigned(regs1_q_b);
                  if (decSource1 > 0 and writebackTarget = decSource1 and writebackWriteEnable = '1') then 
                     decodeValue1 <= writebackData;
                  end if;
                  
                  decodeValue2     <= unsigned(regs2_q_b);
                  if (decSource2 > 0 and writebackTarget = decSource2 and writebackWriteEnable = '1') then 
                     decodeValue2 <= writebackData;
                  end if;
                  
                  executeForwardValue1 <= '0';
                  executeForwardValue2 <= '0';
                  if (decSource1 > 0 and decodeTarget = decSource1) then executeForwardValue1 <= '1'; end if;
                  if (decSource2 > 0 and decodeTarget = decSource2) then executeForwardValue2 <= '1'; end if;

                  -- FPU operand fetching
                  decodeFPUValue1 <= unsigned(FPUregs1_q_b);
                  decodeFPUValue2 <= unsigned(FPUregs2_q_b);
                  decodeFPUTarget <= opcodeCacheMuxed(10 downto 6);
                  
                  if (unsigned(FPUregs_address_a) = decFPUSource1 and FPUregs_wren_a(1) = '1') then decodeFPUValue1(63 downto 32) <= unsigned(FPUregs_data_a(63 downto 32)); end if;
                  if (unsigned(FPUregs_address_a) = decFPUSource1 and FPUregs_wren_a(0) = '1') then decodeFPUValue1(31 downto  0) <= unsigned(FPUregs_data_a(31 downto  0)); end if;
                  if (unsigned(FPUregs_address_a) = decFPUSource2 and FPUregs_wren_a(1) = '1') then decodeFPUValue2(63 downto 32) <= unsigned(FPUregs_data_a(63 downto 32)); end if;
                  if (unsigned(FPUregs_address_a) = decFPUSource2 and FPUregs_wren_a(0) = '1') then decodeFPUValue2(31 downto  0) <= unsigned(FPUregs_data_a(31 downto  0)); end if;

                  decodeFPUForwardUse <= decFPUForwardUse;

                  -- decoding default
                  decodeResultWriteEnable <= '0';
                  decodeUseImmidateValue2 <= '0';
                  decodeShiftSigned       <= '0';
                  decodeShift32           <= '0';
                  decodeResult32          <= '0';
                  decodeBranchType        <= BRANCH_OFF;
                  decodeBranchLikely      <= '0';
                  decodeFPUCommandEnable  <= '0';
                  decodeFPUTransferEnable <= '0';
                  decodeFPUMULS           <= '0';
                  decodeFPUMULD           <= '0';
                  blockIRQ                <= '0';
                  decodeExcType           <= EXCTYPE_NONE;
                  decodeExcCode           <= x"0";
                  decodeExcCOP            <= "00";
                  decodecalcMULT          <= '0';
                  decodecalcMULTU         <= '0';
                  decodecalcDMULT         <= '0';
                  decodecalcDMULTU        <= '0';
                  decodecalcDIV           <= '0';
                  decodecalcDIVU          <= '0';
                  decodecalcDDIV          <= '0';
                  decodecalcDDIVU         <= '0';
                  decodehiUpdate          <= '0';
                  decodeloUpdate          <= '0';
                  decodeMemWriteEnable    <= '0';
                  decodeMemWriteLL        <= '0';
                  decodeMemReadEnable     <= '0';
                  decodeMem64Bit          <= '0';
                  decodeCacheEnable       <= '0';
                  decodeCacheTLBTranslate <= '0';
                  decodeSetLL             <= '0';
                  decodeResetLL           <= '0';
                  decodeERET              <= '0';
                  decodeCOP0ReadEnable    <= '0';
                  decodeCOP0WriteEnable   <= '0';
                  decodeCOP0Register      <= decRD;
                  decodeCOP1ReadEnable    <= '0';
                  decodeCOP2ReadEnable    <= '0';
                  decodeCOP2WriteEnable   <= '0';
                  decodeCOP64             <= '0';
                  decodeTLBR              <= '0';
                  decodeTLBWI             <= '0';
                  decodeTLBWR             <= '0';
                  decodeTLBP              <= '0';
                  
                  -- decoding opcode specific
                  case (to_integer(decOP)) is
         
                     when 16#00# =>
                        case (to_integer(decFunct)) is
                        
                           when 16#00# => -- SLL
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTLEFT;
                              decodeShiftAmountType   <= "00";
                              decodeResult32          <= '1';
                              
                           when 16#02# => -- SRL
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTRIGHT;
                              decodeShift32           <= '1';
                              decodeShiftAmountType   <= "00";
                              decodeResult32          <= '1';
                           
                           when 16#03# => -- SRA
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTRIGHT; 
                              decodeShiftSigned       <= '1';
                              decodeShiftAmountType   <= "00";
                              decodeResult32          <= '1';
                              
                           when 16#04# => -- SLLV
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTLEFT;
                              decodeShiftAmountType   <= "01";
                              decodeResult32          <= '1';
                              
                           when 16#06# => -- SRLV
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTRIGHT;
                              decodeShift32           <= '1';
                              decodeShiftAmountType   <= "01";
                              decodeResult32          <= '1';
                           
                           when 16#07# => -- SRAV
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTRIGHT;
                              decodeShiftSigned       <= '1';
                              decodeShiftAmountType   <= "01";
                              decodeResult32          <= '1';

                           when 16#08# => -- JR
                              decodeBranchType        <= BRANCH_ALWAYS_REG;
                              decodeExcType           <= EXCTYPE_PC;
                              decodeExcCode           <= x"4";
                              
                           when 16#09# => -- JALR
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_PC;
                              decodeTarget            <= decRD;
                              decodeBranchType        <= BRANCH_ALWAYS_REG;
                              decodeExcType           <= EXCTYPE_PC;
                              decodeExcCode           <= x"4";
                              
                           when 16#0C# => -- SYSCALL
                              decodeExcType           <= EXCTYPE_DECODE;
                              decodeExcCode           <= x"8";
                     
                           when 16#0D# => -- BREAK
                              decodeExcType           <= EXCTYPE_DECODE;
                              decodeExcCode           <= x"9";
                              
                           when 16#0F# => -- SYNC
                              null;
                              
                           when 16#10# => -- MFHI
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_HI;
                            
                           when 16#11# => -- MTHI
                              decodehiUpdate <= '1';
                  
                           when 16#12# => -- MFLO
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_LO;
                              
                           when 16#13# => -- MTLO
                              decodeloUpdate <= '1';
                              
                           when 16#14# => -- DSLLV
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTLEFT;
                              decodeShiftAmountType   <= "10";   
                  
                           when 16#16# => -- DSRLV
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTRIGHT;
                              decodeShiftAmountType   <= "10";   
                              
                           when 16#17# => -- DSRAV
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTRIGHT;
                              decodeShiftAmountType   <= "10";   
                              decodeShiftSigned       <= '1';
                              
                           when 16#18# => -- MULT
                              decodecalcMULT <= '1';
                              
                           when 16#19# => -- MULTU
                              decodecalcMULTU <= '1';
                              
                           when 16#1A# => -- DIV
                              decodecalcDIV <= '1';
                              
                           when 16#1B# => -- DIVU
                              decodecalcDIVU <= '1';
                              
                           when 16#1C# => -- DMULT
                              decodecalcDMULT <= '1';                
                              
                           when 16#1D# => -- DMULTU
                              decodecalcDMULTU <= '1';                  
                              
                           when 16#1E# => -- DDIV
                              decodecalcDDIV <= '1';             
                              
                           when 16#1F# => -- DDIVU
                              decodecalcDDIVU <= '1';
                              
                           when 16#20# => -- ADD
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_ADD;
                              decodeResult32          <= '1';
                              decodeExcType           <= EXCTYPE_ADD;
                              decodeExcCode           <= x"C";
                  
                           when 16#21# => -- ADDU
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_ADD;
                              decodeResult32          <= '1';
                              
                           when 16#22# => -- SUB
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SUB;
                              decodeResult32          <= '1';
                              decodeExcType           <= EXCTYPE_SUB;
                              decodeExcCode           <= x"C";
                           
                           when 16#23# => -- SUBU
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SUB;
                              decodeResult32          <= '1';
                           
                           when 16#24# => -- AND
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_AND;
                           
                           when 16#25# => -- OR
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_OR;
                              
                           when 16#26# => -- XOR
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_XOR;
                              
                           when 16#27# => -- NOR
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_NOR;
                              
                           when 16#2A# => -- SLT
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_BIT;
                              decodeBitFuncType       <= BITFUNC_SIGNED;
                           
                           when 16#2B# => -- SLTU
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_BIT;
                              decodeBitFuncType       <= BITFUNC_UNSIGNED;
                              
                           when 16#2C# => -- DADD 
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_ADD;
                              decodeExcType           <= EXCTYPE_DADD;
                              decodeExcCode           <= x"C";
                  
                           when 16#2D# => -- DADDU
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_ADD;  
                              
                           when 16#2E# => -- DSUB
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SUB;
                              decodeExcType           <= EXCTYPE_DSUB;
                              decodeExcCode           <= x"C";
                              
                           when 16#2F# => -- DSUBU
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SUB;
                  
                           when 16#30# => -- TGE
                              decodeExcType  <= EXCTYPE_TRAPS0;
                              decodeExcCode  <= x"D";
                              
                           when 16#31# => -- TGEU
                              decodeExcType  <= EXCTYPE_TRAPU0;
                              decodeExcCode  <= x"D";
                              
                           when 16#32# => -- TLT
                              decodeExcType  <= EXCTYPE_TRAPS1;
                              decodeExcCode  <= x"D";
                              
                           when 16#33# => -- TLTU
                              decodeExcType  <= EXCTYPE_TRAPU1;
                              decodeExcCode  <= x"D";
                              
                           when 16#34# => -- TEQ
                              decodeExcType  <= EXCTYPE_TRAPE1;
                              decodeExcCode  <= x"D";
                              
                           when 16#36# => -- TNE
                              decodeExcType  <= EXCTYPE_TRAPE0;
                              decodeExcCode  <= x"D";
                  
                           when 16#38# => -- DSLL
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTLEFT;
                              decodeShiftAmountType   <= "00"; 
                  
                           when 16#3A# => -- DSRL
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTRIGHT;
                              decodeShiftAmountType   <= "00"; 
                              
                           when 16#3B# => -- DSRA
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTRIGHT;
                              decodeShiftAmountType   <= "00"; 
                              decodeShiftSigned       <= '1';
                              
                           when 16#3C# => -- DSLL + 32
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTLEFT;
                              decodeShiftAmountType   <= "00"; 
                              decodeShamt(5)          <= '1';
                              
                           when 16#3E# => -- DSRL + 32
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTRIGHT;
                              decodeShiftAmountType   <= "00"; 
                              decodeShamt(5)          <= '1';
                              
                           when 16#3F# => -- DSRA + 32
                              decodeResultWriteEnable <= '1';
                              decodeResultMux         <= RESULTMUX_SHIFTRIGHT;
                              decodeShiftAmountType   <= "00"; 
                              decodeShamt(5)          <= '1';
                              decodeShiftSigned       <= '1';

                           when others =>
                              decodeExcType  <= EXCTYPE_DECODE;
                              decodeExcCode  <= x"A";
                           
                        end case;
  
                     when 16#01# => 
                        decodeResultMux      <= RESULTMUX_PC;
                        decodeTarget         <= to_unsigned(31, 5);
                        if (decSource2(3) = '1') then -- Traps
                           case (decSource2(2 downto 0)) is
                              when 3x"0" => -- TGEI
                                 decodeExcType  <= EXCTYPE_TRAPIS0;
                                 decodeExcCode  <= x"D";
                                 
                              when 3x"1" => -- TGEIU
                                 decodeExcType  <= EXCTYPE_TRAPIU0;
                                 decodeExcCode  <= x"D";
                                 
                              when 3x"2" => -- TLTI
                                 decodeExcType  <= EXCTYPE_TRAPIS1;
                                 decodeExcCode  <= x"D";
                                 
                              when 3x"3" => -- TLTIU
                                 decodeExcType  <= EXCTYPE_TRAPIU1;
                                 decodeExcCode  <= x"D";
                                 
                              when 3x"4" => -- TEQI
                                 decodeExcType  <= EXCTYPE_TRAPIE1;
                                 decodeExcCode  <= x"D";
                                 
                              when 3x"6" => -- TNEI
                                 decodeExcType  <= EXCTYPE_TRAPIE0;
                                 decodeExcCode  <= x"D";
                              
                              when others =>
                                 decodeExcType  <= EXCTYPE_DECODE;
                                 decodeExcCode  <= x"A";
                                 
                           end case;
                           
                        else -- B: BLTZ, BGEZ, BLTZAL, BGEZAL
                           if (decSource2(4) = '1') then
                              decodeResultWriteEnable <= '1';
                           end if;
                           if (decSource2(0) = '1') then
                              decodeBranchType     <= BRANCH_BRANCH_BGEZ;
                           else
                              decodeBranchType     <= BRANCH_BRANCH_BLTZ;
                           end if;
                           decodeBranchLikely      <= decSource2(1);
                           if (decSource2(1) = '1') then blockIRQ <= '1'; end if;
                        end if;
                        
                     when 16#02# => -- J
                        decodeBranchType        <= BRANCH_JUMPIMM;
               
                     when 16#03# => -- JAL
                        decodeResultWriteEnable <= '1';
                        decodeResultMux         <= RESULTMUX_PC;
                        decodeTarget            <= to_unsigned(31, 5);
                        decodeBranchType        <= BRANCH_JUMPIMM;
                        
                     when 16#04# => -- BEQ
                        decodeBranchType        <= BRANCH_BRANCH_BEQ;
                     
                     when 16#05# => -- BNE
                        decodeBranchType        <= BRANCH_BRANCH_BNE;
                     
                     when 16#06# => -- BLEZ
                        decodeBranchType        <= BRANCH_BRANCH_BLEZ;
                        
                     when 16#07# => -- BGTZ
                        decodeBranchType        <= BRANCH_BRANCH_BGTZ;
                        
                     when 16#08# => -- ADDI
                        decodeResultWriteEnable <= '1';
                        decodeResultMux         <= RESULTMUX_ADD;
                        decodeResult32          <= '1';
                        decodeUseImmidateValue2 <= '1';
                        decodeExcType           <= EXCTYPE_ADDI;
                        decodeExcCode           <= x"C";
            
                     when 16#09# => -- ADDIU
                        decodeResultWriteEnable <= '1';
                        decodeResultMux         <= RESULTMUX_ADD;
                        decodeResult32          <= '1';
                        decodeUseImmidateValue2 <= '1';
                        
                     when 16#0A# => -- SLTI
                        decodeResultWriteEnable <= '1';
                        decodeResultMux         <= RESULTMUX_BIT;
                        decodeBitFuncType       <= BITFUNC_IMM_SIGNED;   
                        
                     when 16#0B# => -- SLTIU
                        decodeResultWriteEnable <= '1';
                        decodeResultMux         <= RESULTMUX_BIT;
                        decodeBitFuncType       <= BITFUNC_IMM_UNSIGNED; 
                        
                     when 16#0C# => -- ANDI
                        decodeResultWriteEnable <= '1';
                        decodeResultMux         <= RESULTMUX_AND;
                        decodeUseImmidateValue2 <= '1';
                        
                     when 16#0D# => -- ORI
                        decodeResultWriteEnable <= '1';
                        decodeResultMux         <= RESULTMUX_OR;
                        decodeUseImmidateValue2 <= '1';
                        
                     when 16#0E# => -- XORI
                        decodeResultWriteEnable <= '1';
                        decodeResultMux         <= RESULTMUX_XOR;
                        decodeUseImmidateValue2 <= '1';
                        
                     when 16#0F# => -- LUI
                        decodeResultWriteEnable <= '1';
                        decodeResultMux         <= RESULTMUX_LUI;
                        
                     when 16#10# => -- COP0
                        blockIRQ <= '1';
                        if (COP0_enable = '0') then
                           decodeExcType           <= EXCTYPE_DECODE;
                           decodeExcCode           <= x"B";
                           decodeExcCOP            <= "00";
                        elsif (decSource1(4) = '1') then
                           case (to_integer(decImmData(5 downto 0))) is
                              when 1 => decodeTLBR  <= '1';                         
                              when 2 => decodeTLBWI <= '1'; 
                              when 6 => decodeTLBWR <= '1';
                              when 8 => decodeTLBP  <= '1';
                              when 16#18# => -- ERET
                                 decodeBranchType <= BRANCH_ERET;
                                 decodeERET       <= '1';
                                 
                              when others => null;
                                 
                           end case;
                        else
                           case (to_integer(decSource1(3 downto 0))) is
                           
                              when 0 => -- mfc0
                                 decodeCOP0ReadEnable  <= '1';
                                                   
                              when 1 => -- dmfc0
                                 decodeCOP0ReadEnable  <= '1';
                                 decodeCOP64           <= '1';
                           
                              when 4 => -- mtc0
                                 decodeCOP0WriteEnable <= '1';
                                 
                              when 5 => -- dmtc0
                                 decodeCOP0WriteEnable <= '1';
                                 decodeCOP64           <= '1';
                              
                              when others => null;
                                 
                           end case;
                        end if;

                     when 16#11# => -- COP1
                        decodeResultMux         <= RESULTMUX_FPU;
                        if (decSource1(4) = '1') then -- FPU execute
                           decodeFPUCommandEnable  <= COP1_enable;
                           if (decFunct = 2) then
                              if (decSource1 = 16) then decodeFPUMULS <= '1'; end if;
                              if (decSource1 = 17) then decodeFPUMULD <= '1'; end if;
                           end if;
                        else
                           decodeFPUTarget         <= decRD;
                           decodeFPUTransferEnable <= COP1_enable;
                           if (decSource1(3 downto 0) < 3) then
                              decodeResultWriteEnable <= '1';
                           end if;
                           if (decSource1(3 downto 0) = x"8") then
                              decodeBranchType   <= BRANCH_BC1;
                              decodeBranchLikely <= decSource2(1);
                              if (decSource2(1) = '1') then blockIRQ <= '1'; end if;
                           end if;
                        end if;
                        if (COP1_enable = '0' or (decSource1(4) = '0' and decSource1(3 downto 0) > 8)) then
                           decodeExcType           <= EXCTYPE_DECODE;
                           decodeExcCode           <= x"B";
                           decodeExcCOP            <= "01";
                        end if;
                       
                     when 16#12# => -- COP2
                        if (COP2_enable = '0') then
                           decodeExcType           <= EXCTYPE_DECODE;
                           decodeExcCode           <= x"B";
                           decodeExcCOP            <= "10";
                        else
                           case (to_integer(decSource1)) is
                  
                              when 0 | 2 =>
                                 decodeCOP2ReadEnable <= '1';
                              
                              when 1 =>
                                 decodeCOP2ReadEnable <= '1';
                                 decodeCOP64 <= '1';
                                 
                              when 4 | 5 | 6 =>
                                 decodeCOP2WriteEnable <= '1';
                           
                              when others => 
                                 decodeExcType           <= EXCTYPE_DECODE;
                                 decodeExcCode           <= x"A";
                                 decodeExcCOP            <= "10";
                                 
                           end case;
                        end if;

                     when 16#13# => -- COP3 -> does not exist
                        decodeExcType           <= EXCTYPE_DECODE;
                        decodeExcCode           <= x"A";
                        
                     when 16#14# => -- BEQL
                        decodeBranchType        <= BRANCH_BRANCH_BEQ;
                        decodeBranchLikely      <= '1';
                        blockIRQ                <= '1';
                           
                     when 16#15# => -- BNEL
                        decodeBranchType        <= BRANCH_BRANCH_BNE;
                        decodeBranchLikely      <= '1';
                        blockIRQ                <= '1';
                        
                     when 16#16# => -- BLEZL
                        decodeBranchType        <= BRANCH_BRANCH_BLEZ;
                        decodeBranchLikely      <= '1';
                        blockIRQ                <= '1';
                        
                     when 16#17# => -- BGTZL
                        decodeBranchType        <= BRANCH_BRANCH_BGTZ;
                        decodeBranchLikely      <= '1';
                        blockIRQ                <= '1';
                        
                     when 16#18# => -- DADDI   
                        decodeResultWriteEnable <= '1';
                        decodeResultMux         <= RESULTMUX_ADD;
                        decodeUseImmidateValue2 <= '1';
                        decodeExcType           <= EXCTYPE_DADDI;
                        decodeExcCode           <= x"C";
            
                     when 16#19# => -- DADDIU 
                        decodeResultWriteEnable <= '1';
                        decodeResultMux         <= RESULTMUX_ADD;
                        decodeUseImmidateValue2 <= '1';
                        
                     when 16#1A# => -- LDL
                        decodeMemReadEnable     <= '1';
                        decodeMem64Bit          <= '1';
                        decodeLoadType          <= LOADTYPE_LEFT64;
               
                     when 16#1B# => -- LDR
                        decodeMemReadEnable     <= '1';
                        decodeMem64Bit          <= '1';
                        decodeLoadType          <= LOADTYPE_RIGHT64;
         
                     when 16#20# => -- LB
                        decodeMemReadEnable     <= '1';
                        decodeLoadType          <= LOADTYPE_SBYTE;
                        
                     when 16#21# => -- LH
                        decodeMemReadEnable     <= '1';
                        decodeLoadType          <= LOADTYPE_SWORD;
                        decodeExcType           <= EXCTYPE_ADDRH;
                        decodeExcCode           <= x"4";

                     when 16#22# => -- LWL
                        decodeMemReadEnable     <= '1';
                        decodeLoadType          <= LOADTYPE_LEFT;

                     when 16#23# => -- LW
                        decodeMemReadEnable     <= '1';
                        decodeLoadType          <= LOADTYPE_DWORD;
                        decodeExcType           <= EXCTYPE_ADDRW;
                        decodeExcCode           <= x"4";
                        
                     when 16#24# => -- LBU
                        decodeMemReadEnable     <= '1';
                        decodeLoadType          <= LOADTYPE_BYTE;
               
                     when 16#25# => -- LHU
                        decodeMemReadEnable     <= '1';
                        decodeLoadType          <= LOADTYPE_WORD;
                        decodeExcType           <= EXCTYPE_ADDRH;
                        decodeExcCode           <= x"4";
                        
                     when 16#26# => -- LWR
                        decodeMemReadEnable     <= '1';
                        decodeLoadType          <= LOADTYPE_RIGHT;
               
                     when 16#27# => -- LWU
                        decodeMemReadEnable     <= '1';
                        decodeLoadType          <= LOADTYPE_DWORDU;
                        decodeExcType           <= EXCTYPE_ADDRW;
                        decodeExcCode           <= x"4";
                        
                     when 16#28# => -- SB
                        decodeMemWriteEnable    <= '1';
                        decodeMemWriteType      <= MEMWRITETYPE_BYTE;
               
                     when 16#29# => -- SH
                        decodeMemWriteEnable    <= '1';
                        decodeMemWriteType      <= MEMWRITETYPE_HALF;
                        decodeExcType           <= EXCTYPE_ADDRH;
                        decodeExcCode           <= x"5";
                        
                     when 16#2A# => -- SWL
                        decodeMemWriteEnable    <= '1';
                        decodeMemWriteType      <= MEMWRITETYPE_SWL;
               
                     when 16#2B# => -- SW
                        decodeMemWriteEnable    <= '1';
                        decodeMemWriteType      <= MEMWRITETYPE_WORD;
                        decodeExcType           <= EXCTYPE_ADDRW;
                        decodeExcCode           <= x"5";

                     when 16#2C# => -- SDL
                        decodeMemWriteEnable    <= '1';
                        decodeMem64Bit          <= '1';
                        decodeMemWriteType      <= MEMWRITETYPE_SDL;

                     when 16#2D# => -- SDR
                        decodeMemWriteEnable    <= '1';
                        decodeMem64Bit          <= '1';
                        decodeMemWriteType      <= MEMWRITETYPE_SDR;
                        
                     when 16#2E# => -- SWR
                        decodeMemWriteEnable    <= '1';
                        decodeMemWriteType      <= MEMWRITETYPE_SWR;
                        
                     when 16#2F# => -- Cache
                        decodeCacheEnable       <= '1';
                        decodeCacheTLBTranslate <= '1';
                        
                        case (to_integer(decSource2)) is
                           when 16#00# | 16#08# | 16#10# => decodeCacheTLBTranslate <= '0';
                           when others => null;
                        end case;
                        
                        case (to_integer(decSource2)) is
                           -- KI's R4600 boot ROM uses Fill I-cache (0x14). The
                           -- uncached bring-up path treats it as a legal hint;
                           -- explicit cache-fill handshaking is added with the
                           -- cached execution milestone.
                           when 16#00# | 16#01# | 16#05# | 16#08# | 16#09# | 16#0D# | 16#10# | 16#11# | 16#14# | 16#15# | 16#19# => null;
                           when others => error_instr <= '1';
                        end case;

                     when 16#30# => -- LL
                        decodeMemReadEnable     <= '1';
                        decodeLoadType          <= LOADTYPE_DWORD;
                        decodeSetLL             <= '1';
                        decodeExcType           <= EXCTYPE_ADDRW;
                        decodeExcCode           <= x"4";

                     when 16#31# => -- LWC1
                        decodeLoadType          <= LOADTYPE_DWORD;
                        if (COP1_enable = '0') then
                           decodeExcType           <= EXCTYPE_DECODE;
                           decodeExcCode           <= x"B";
                           decodeExcCOP            <= "01";
                        else
                           decodeMemReadEnable     <= '1';
                           decodeCOP1ReadEnable    <= '1';
                           decodeExcType           <= EXCTYPE_ADDRW;
                           decodeExcCode           <= x"4";
                        end if;

                     when 16#32# => -- LWC2 -> NOP
                        null;

                     when 16#34# => -- LLD 
                        decodeMemReadEnable     <= '1';
                        decodeMem64Bit          <= '1';
                        decodeLoadType          <= LOADTYPE_QWORD;
                        decodeSetLL             <= '1';
                        decodeExcType           <= EXCTYPE_ADDRD;
                        decodeExcCode           <= x"4";

                     when 16#35# => -- LDC1
                        decodeMem64Bit          <= '1';
                        decodeLoadType          <= LOADTYPE_QWORD;
                        if (COP1_enable = '0') then
                           decodeExcType           <= EXCTYPE_DECODE;
                           decodeExcCode           <= x"B";
                           decodeExcCOP            <= "01";
                        else
                           decodeMemReadEnable     <= '1';
                           decodeCOP1ReadEnable    <= '1';
                           decodeExcType           <= EXCTYPE_ADDRD;
                           decodeExcCode           <= x"4";
                        end if;

                     when 16#37# => -- LD
                        decodeMemReadEnable     <= '1';
                        decodeMem64Bit          <= '1';
                        decodeLoadType          <= LOADTYPE_QWORD;
                        decodeExcType           <= EXCTYPE_ADDRD;
                        decodeExcCode           <= x"4";              
               
                     when 16#38# => -- SC
                        decodeResultWriteEnable <= '1';
                        decodeResultMux         <= RESULTMUX_BIT;
                        decodeBitFuncType       <= BITFUNC_SC;
                        decodeMemWriteLL        <= '1';
                        decodeResetLL           <= '1';
                        decodeMemWriteType      <= MEMWRITETYPE_WORD;
                        decodeExcType           <= EXCTYPE_ADDRW;
                        decodeExcCode           <= x"5";
               
                     when 16#39# => -- SWC1 
                        if (fpuRegMode = '0' and decSource2(0) = '1') then
                           decodeMemWriteType <= MEMWRITETYPE_COP1H;
                        else
                           decodeMemWriteType <= MEMWRITETYPE_COP1L;
                        end if;
                        if (COP1_enable = '0') then
                           decodeExcType           <= EXCTYPE_DECODE;
                           decodeExcCode           <= x"B";
                           decodeExcCOP            <= "01";
                        else
                           decodeMemWriteEnable    <= '1';
                           decodeExcType           <= EXCTYPE_ADDRW;
                           decodeExcCode           <= x"5";
                        end if;

                     when 16#3A# => -- SWC2 -> NOP
                        null;
   
                     when 16#3C# => -- SCD 
                        decodeResultWriteEnable <= '1';
                        decodeResultMux         <= RESULTMUX_BIT;
                        decodeBitFuncType       <= BITFUNC_SC;
                        decodeMemWriteLL        <= '1';
                        decodeResetLL           <= '1';
                        decodeMem64Bit          <= '1';
                        decodeMemWriteType      <= MEMWRITETYPE_DWORD;
                        decodeExcType           <= EXCTYPE_ADDRD;
                        decodeExcCode           <= x"5";
               
                     when 16#3D# => -- SDC1 
                        decodeMem64Bit          <= '1';
                        decodeMemWriteType      <= MEMWRITETYPE_COP1D;
                        if (COP1_enable = '0') then
                           decodeExcType           <= EXCTYPE_DECODE;
                           decodeExcCode           <= x"B";
                           decodeExcCOP            <= "01";
                        else
                           decodeMemWriteEnable    <= '1';
                           decodeExcType           <= EXCTYPE_ADDRD;
                           decodeExcCode           <= x"5";
                        end if;
               
                     when 16#3F# => -- SD
                        decodeMemWriteEnable    <= '1';
                        decodeMem64Bit          <= '1';
                        decodeMemWriteType      <= MEMWRITETYPE_DWORD;
                        decodeExcType           <= EXCTYPE_ADDRD;
                        decodeExcCode           <= x"5";
                     
                     when others =>
                        decodeExcType  <= EXCTYPE_DECODE;
                        decodeExcCode  <= x"A";                     
                     
                  end case;
                  
                  if (irqTrigger = '1' and blockIRQ = '0') then
                     decode_irq <= '1';
                     decodeNew  <= '0';
                  end if;
                  
                  if (decode_irq = '1') then
                     decodeNew <= '0';
                  end if;
                  
               end if; -- fetchReady
      
            else
               
               -- operand forwarding in stall
               if (decodeSource1 > 0 and writebackTarget = decodeSource1 and writebackWriteEnable = '1') then decodeValue1 <= writebackData; end if;
               if (decodeSource2 > 0 and writebackTarget = decodeSource2 and writebackWriteEnable = '1') then decodeValue2 <= writebackData; end if;
      
               if (unsigned(FPUregs_address_a) = decodeFPUSource1 and FPUregs_wren_a(1) = '1') then decodeFPUValue1(63 downto 32) <= unsigned(FPUregs_data_a(63 downto 32)); end if;
               if (unsigned(FPUregs_address_a) = decodeFPUSource1 and FPUregs_wren_a(0) = '1') then decodeFPUValue1(31 downto  0) <= unsigned(FPUregs_data_a(31 downto  0)); end if;
               if (unsigned(FPUregs_address_a) = decodeFPUSource2 and FPUregs_wren_a(1) = '1') then decodeFPUValue2(63 downto 32) <= unsigned(FPUregs_data_a(63 downto 32)); end if;
               if (unsigned(FPUregs_address_a) = decodeFPUSource2 and FPUregs_wren_a(0) = '1') then decodeFPUValue2(31 downto  0) <= unsigned(FPUregs_data_a(31 downto  0)); end if;

            end if; -- stall

            -- An FPU result in its done cycle, for the instruction held in
            -- stage 3 on it: what the write port above carries next cycle,
            -- or, if the op traps, a value the exception discards with that
            -- instruction. The op's stall3 holds that instruction from the
            -- op's issue to its done, so this needs no stall term; and the
            -- earliest done is three cycles after issue, so the register
            -- match, taken a cycle earlier, has settled by then.
            FPU_fwd_match1 <= '0';
            FPU_fwd_match2 <= '0';
            if (FPUWriteTarget = decodeFPUSource1) then FPU_fwd_match1 <= '1'; end if;
            if (FPUWriteTarget = decodeFPUSource2) then FPU_fwd_match2 <= '1'; end if;
            if (FPU_fwd_valid = '1' and FPU_fwd_match1 = '1') then decodeFPUValue1 <= FPU_fwd_data; end if;
            if (FPU_fwd_valid = '1' and FPU_fwd_match2 = '1') then decodeFPUValue2 <= FPU_fwd_data; end if;

         end if; -- ce
      end if; -- clk
   end process;
   
   
--##############################################################
--############################### stage 3
--##############################################################
   
   ---------------------- Operand forward ------------------
   
   value1 <= resultData    when (executeForwardValue1   = '1' and resultWriteEnable = '1') else 
             writebackData when (writebackForwardValue1 = '1') else 
             decodeValue1;
   
   value2 <= resultData    when (executeForwardValue2   = '1' and resultWriteEnable = '1') else 
             writebackData when (writebackForwardValue2 = '1') else 
             decodeValue2;
   
   ---------------------- Adder ------------------
   value2_muxedSigned <= unsigned(resize(signed(decodeImmData), 64)) when (decodeUseImmidateValue2) else value2;
   calcResult_add     <= value1 + value2_muxedSigned;
   
   calcMemAddr        <= value1 + unsigned(resize(signed(decodeImmData), 64));
   
   ---------------------- Shifter ------------------
   -- multiplex immidiate and register based shift amount, so both types can use the same shifters
   executeShamt <= decodeShamt              when (decodeShiftAmountType = "00") else
                   '0' & value1(4 downto 0) when (decodeShiftAmountType = "01") else
                   value1(5 downto 0);
   
   -- multiplex high bit of rightshift so arithmetic shift can be reused for logical shift
   shiftValue(31 downto 0)  <= signed(value2(31 downto 0));
   shiftValue(63 downto 32) <= (others => '0') when (decodeShift32 = '1') else signed(value2(63 downto 32));
   shiftValue(64) <= value2(63) when (decodeShiftSigned = '1') else '0';

   calcResult_shiftL <= value2 sll to_integer(executeShamt);
   calcResult_shiftR <= resize(unsigned(shift_right(shiftValue,to_integer(executeShamt))), 64);  

   ---------------------- Sub ------------------
   calcResult_sub    <= value1 - value2;
   
   ---------------------- logical calcs ------------------
   value2_muxedLogical <= x"000000000000" & decodeImmData when (decodeUseImmidateValue2) else value2;
   
   calcResult_and    <= value1 and value2_muxedLogical;
   calcResult_or     <= value1 or value2_muxedLogical;
   calcResult_xor    <= value1 xor value2_muxedLogical;
   calcResult_nor    <= value1 nor value2;

   ---------------------- bit functions ------------------
   
   calcResult_lesserSigned      <= '1' when (signed(value1) < signed(value2)) else '0'; 
   calcResult_lesserUnsigned    <= '1' when (value1 < value2) else '0';    
   calcResult_lesserIMMSigned   <= '1' when (signed(value1) < resize(signed(decodeImmData), 64)) else '0'; 
   calcResult_lesserIMMUnsigned <= '1' when (value1 < unsigned(resize(signed(decodeImmData), 64))) else '0'; 
   calcResult_equal             <= '1' when (signed(value1) = resize(signed(decodeImmData), 64)) else '0'; 
   
   calcResult_bit(63 downto 1) <= (others => '0');
   calcResult_bit(0) <= calcResult_lesserSigned       when (decodeBitFuncType = BITFUNC_SIGNED) else
                        calcResult_lesserUnSigned     when (decodeBitFuncType = BITFUNC_UNSIGNED) else
                        calcResult_lesserIMMSigned    when (decodeBitFuncType = BITFUNC_IMM_SIGNED) else
                        calcResult_lesserIMMUnsigned  when (decodeBitFuncType = BITFUNC_IMM_UNSIGNED) else
                        llBit;
   
   ---------------------- branching ------------------
   --PCnext       <= PC + 4;
   --PCnextBranch <= pcOld0 + unsigned((resize(signed(decodeImmData), 62) & "00"));
   -- assume region change cannot/will not happen with counting up or short jumps
   PCnext       <= PC(63 downto 29) & (PC(28 downto 0) + 4);
   PCnextBranch <= pcOld0(63 downto 29) & (pcOld0(28 downto 0) + unsigned((resize(signed(decodeImmData), 27) & "00")));
   
   cmpEqual    <= '1' when (value1 = value2) else '0';
   cmpNegative <= value1(63);
   cmpZero     <= '1' when (value1 = 0) else '0';
   
   -- use two nextaddress/branch paths with 2 tag rams, so different paths can be calculated in parallel to improve timing
   
   FetchAddrSelect <= '0'  when (exception = '1' or exceptionStage1 = '1' or executeIgnoreNext = '1' or decodeNew = '0') else
                      '1'  when (decodeBranchType = BRANCH_BRANCH_BGEZ and (cmpZero = '1' or cmpNegative = '0'))  else
                      '1'  when (decodeBranchType = BRANCH_BRANCH_BLTZ and cmpNegative = '1')                     else
                      '1'  when (decodeBranchType = BRANCH_BRANCH_BEQ  and cmpEqual = '1')                        else
                      '1'  when (decodeBranchType = BRANCH_BRANCH_BNE  and cmpEqual = '0')                        else
                      '1'  when (decodeBranchType = BRANCH_BRANCH_BLEZ and (cmpZero = '1' or cmpNegative = '1'))  else
                      '1'  when (decodeBranchType = BRANCH_BRANCH_BGTZ and (cmpZero = '0' and cmpNegative = '0')) else
                      '1'  when (decodeBranchType = BRANCH_BC1         and decodeSource2(0) = FPU_CF) else
                      '0';
   
   FetchAddr1 <= exceptionPC                                    when (exception = '1' or exceptionStage1 = '1') else
                 PCnext                                         when (executeIgnoreNext = '1' or decodeNew = '0') else
                 value1                                         when (decodeBranchType = BRANCH_ALWAYS_REG) else
                 pcOld0(63 downto 28) & decodeJumpTarget & "00" when (decodeBranchType = BRANCH_JUMPIMM) else
                 eretPC                                         when (decodeBranchType = BRANCH_ERET) else
                 PCnext;

   FetchAddr2 <= PCnextBranch;

   -- Same arms, same priority, as FetchAddr1 above, with value1's forwarding
   -- mux folded in so the RAM index is one mux from its sources. The jump
   -- immediate arm reduces to decodeJumpTarget(11 downto 0): FetchAddr1(1
   -- downto 0) is "00" and (27 downto 2) is decodeJumpTarget, so (13 downto 2)
   -- is exactly its low twelve bits. Keep this in step with FetchAddr1 - they
   -- must agree bit for bit.
   FetchIndex1 <= exceptionPC(13 downto 2)      when (exception = '1' or exceptionStage1 = '1') else
                  PCnext(13 downto 2)           when (executeIgnoreNext = '1' or decodeNew = '0') else
                  resultData(13 downto 2)       when (decodeBranchType = BRANCH_ALWAYS_REG and
                                                      executeForwardValue1 = '1' and resultWriteEnable = '1') else
                  writebackData(13 downto 2)    when (decodeBranchType = BRANCH_ALWAYS_REG and
                                                      writebackForwardValue1 = '1') else
                  decodeValue1(13 downto 2)     when (decodeBranchType = BRANCH_ALWAYS_REG) else
                  decodeJumpTarget(11 downto 0) when (decodeBranchType = BRANCH_JUMPIMM) else
                  eretPC(13 downto 2)           when (decodeBranchType = BRANCH_ERET) else
                  PCnext(13 downto 2);

   FetchIndex2 <= PCnextBranch(13 downto 2);

-- synthesis translate_off
   -- The two must never disagree; a mismatch would index a different cache line
   -- than the tag compare is checking. While a stall holds the pipeline, a
   -- jump register's forwarded value can be a load's data still in flight,
   -- unknown in simulation; no fetch takes it, so the pair is compared only
   -- when known, and the fetch PC itself must never latch an unknown address.
   process (clk93)
   begin
      if (rising_edge(clk93)) then
         assert is_x(std_logic_vector(FetchAddr1)) or FetchIndex1 = FetchAddr1(13 downto 2)
            report "FetchIndex1 drifted from FetchAddr1(13 downto 2)" severity failure;
         assert is_x(std_logic_vector(FetchAddr2)) or FetchIndex2 = FetchAddr2(13 downto 2)
            report "FetchIndex2 drifted from FetchAddr2(13 downto 2)" severity failure;
         assert not is_x(std_logic_vector(PC))
            report "fetch PC latched an unknown address" severity failure;
      end if;
   end process;
-- synthesis translate_on

   EXECOPBranchDelaySlot <= '0' when (executeIgnoreNext = '1') else
                            '1' when (decodeBranchType /= BRANCH_OFF) else 
                            '0';

   -- DELAY SLOTS DO NOT CHAIN.
   --
   -- This flag means "the instruction after the one now in decode is a delay
   -- slot", and it feeds cop0's isDelaySlot, which is the ONLY consumer - it
   -- decides Cause.BD and whether EPC is backed up by four. It has no effect on
   -- how branches actually execute.
   --
   -- When a branch sits in another branch's delay slot, the second branch also
   -- raised this flag, so the FIRST branch's TARGET was marked as a delay slot
   -- too. An interrupt arriving at that target then recorded
   -- EPC = target - 4, an address that is not a delay slot of anything in the
   -- real control flow. eret resumed there, executed whatever instruction
   -- happens to precede the target, and fell THROUGH into the target instead of
   -- entering it via the branch.
   --
   -- That is the KI FMV restart. The decompressor uses the "jump either way"
   -- idiom - KI1 880322D4/880322D8, KI2 8802F074/8802F078, a bnez with a beqz
   -- to the same target in its delay slot. cpu_cop0.vhd carries the donor
   -- author's own note that this case was never tested.
   --
   -- A branch in a delay slot is architecturally undefined on MIPS, so there is
   -- no "correct" answer to copy; what matters is that the exception state
   -- stays self-consistent, with EPC pointing at a real instruction.
   --
   -- NOT FIXED HERE YET. The obvious one-liner - suppressing this flag while
   -- executeBranchdelaySlot is already set - is WRONG. That signal is
   -- registered under `if (stall = 0)` and therefore HOLDS across a stall, so
   -- the suppression also swallows the flag for an unrelated branch decoded
   -- after a stall: legitimate delay slots stop being marked, and EPC stops
   -- being backed up.
   --
   -- What this needs is a DECODE-ALIGNED "the instruction now in decode is
   -- itself a delay slot" signal, advanced only when the decode advances,
   -- rather than reusing the execute-stage flag.
   EXEBranchdelaySlot <= '0' when (executeIgnoreNext = '1') else
                         '1' when (decodeBranchType = BRANCH_ALWAYS_REG) else
                         '1' when (decodeBranchType = BRANCH_JUMPIMM) else
                         '1' when (decodeBranchType = BRANCH_BRANCH_BGEZ and (decodeBranchLikely = '0' or (cmpZero = '1' or cmpNegative = '0')))  else
                         '1' when (decodeBranchType = BRANCH_BRANCH_BLTZ and (decodeBranchLikely = '0' or cmpNegative = '1')                   )  else
                         '1' when (decodeBranchType = BRANCH_BRANCH_BEQ  and (decodeBranchLikely = '0' or cmpEqual = '1')                      )  else
                         '1' when (decodeBranchType = BRANCH_BRANCH_BNE  and (decodeBranchLikely = '0' or cmpEqual = '0')                      )  else
                         '1' when (decodeBranchType = BRANCH_BRANCH_BLEZ and (decodeBranchLikely = '0' or (cmpZero = '1' or cmpNegative = '1')))  else
                         '1' when (decodeBranchType = BRANCH_BRANCH_BGTZ and (decodeBranchLikely = '0' or (cmpZero = '0' and cmpNegative = '0'))) else
                         '1' when (decodeBranchType = BRANCH_BC1         and (decodeBranchLikely = '0' or decodeSource2(0) = FPU_CF))             else
                         '0';
                         
   EXEIgnoreNext      <= '0' when (executeIgnoreNext = '1') else
                         '1' when (decodeBranchType = BRANCH_ERET) else                      
                         '1' when (decodeBranchType = BRANCH_BRANCH_BGEZ and decodeBranchLikely = '1' and cmpZero = '0' and cmpNegative = '1')  else
                         '1' when (decodeBranchType = BRANCH_BRANCH_BLTZ and decodeBranchLikely = '1' and cmpNegative = '0')                    else
                         '1' when (decodeBranchType = BRANCH_BRANCH_BEQ  and decodeBranchLikely = '1' and cmpEqual = '0')                       else
                         '1' when (decodeBranchType = BRANCH_BRANCH_BNE  and decodeBranchLikely = '1' and cmpEqual = '1')                       else
                         '1' when (decodeBranchType = BRANCH_BRANCH_BLEZ and decodeBranchLikely = '1' and cmpZero = '0' and cmpNegative = '0')  else
                         '1' when (decodeBranchType = BRANCH_BRANCH_BGTZ and decodeBranchLikely = '1' and (cmpZero = '1' or cmpNegative = '1')) else
                         '1' when (decodeBranchType = BRANCH_BC1         and decodeBranchLikely = '1' and decodeSource2(0) /= FPU_CF)           else
                         '0';

   ---------------------- result muxing ------------------
   resultDataMuxed <= calcResult_shiftL when (decodeResultMux = RESULTMUX_SHIFTLEFT)  else
                      calcResult_shiftR when (decodeResultMux = RESULTMUX_SHIFTRIGHT) else
                      calcResult_add    when (decodeResultMux = RESULTMUX_ADD)        else
                      PCnext            when (decodeResultMux = RESULTMUX_PC)         else
                      HI                when (decodeResultMux = RESULTMUX_HI)         else
                      LO                when (decodeResultMux = RESULTMUX_LO)         else
                      calcResult_sub    when (decodeResultMux = RESULTMUX_SUB)        else
                      calcResult_and    when (decodeResultMux = RESULTMUX_AND)        else
                      calcResult_or     when (decodeResultMux = RESULTMUX_OR )        else
                      calcResult_xor    when (decodeResultMux = RESULTMUX_XOR)        else
                      calcResult_nor    when (decodeResultMux = RESULTMUX_NOR)        else
                      calcResult_bit    when (decodeResultMux = RESULTMUX_BIT)        else
                      FPU_TransferData  when (decodeResultMux = RESULTMUX_FPU)        else
                      unsigned(resize(signed(decodeImmData) & x"0000", 64)); -- (decodeResultMux = RESULTMUX_LUI);
                      
   resultDataMuxed64(31 downto 0) <= resultDataMuxed(31 downto 0);
   resultDataMuxed64(63 downto 32) <= (others => resultDataMuxed(31)) when decodeResult32 else resultDataMuxed(63 downto 32);

   ---------------------- exceptions ------------------
   exceptionCode_3  <= decodeExcCode;
   exception_COP    <= decodeExcCOP;
   
   EXEExceptionMem <= '1' when (decodeExcType = EXCTYPE_ADDRH   and calcMemAddr(0) = '1') else
                      '1' when (decodeExcType = EXCTYPE_ADDRW   and calcMemAddr(1 downto 0) > 0) else
                      '1' when (decodeExcType = EXCTYPE_ADDRD   and calcMemAddr(2 downto 0) > 0) else
                      -- 2 below should use calcMemAddr to allow inter cycle wraparound, but we can't do that due to timing closure
                      '1' when (region64 = '0' and value1(63 downto 32) = x"FFFFFFFF" and value1(31) = '0') else 
                      '1' when (region64 = '0' and value1(63 downto 32) = x"00000000" and value1(31) = '1') else
                      '1' when (region_unused = '1') else
                      '0';
   
   exceptionNew3  <= '0' when (exception = '1' or stall > 0 or executeIgnoreNext = '1' or decodeNew = '0') else
                     '1' when (EXEExceptionMem = '1' and (decodeMemReadEnable = '1' or decodeMemWriteEnable = '1')) else
                     '1' when (decodeExcType = EXCTYPE_DECODE) else
                     '1' when (decodeExcType = EXCTYPE_PC      and value1(1 downto 0) > 0) else
                     '1' when (decodeExcType = EXCTYPE_ADD     and (((calcResult_add(31) xor value1(31)) and (calcResult_add(31) xor value2(31))) = '1')) else
                     '1' when (decodeExcType = EXCTYPE_DADD    and (((calcResult_add(63) xor value1(63)) and (calcResult_add(63) xor value2(63))) = '1')) else
                     '1' when (decodeExcType = EXCTYPE_ADDI    and (((calcResult_add(31) xor value1(31)) and (calcResult_add(31) xor decodeImmData(15))) = '1')) else
                     '1' when (decodeExcType = EXCTYPE_DADDI   and (((calcResult_add(63) xor value1(63)) and (calcResult_add(63) xor decodeImmData(15))) = '1')) else
                     '1' when (decodeExcType = EXCTYPE_SUB     and (((calcResult_sub(31) xor value1(31)) and (value1(31) xor value2(31))) = '1')) else
                     '1' when (decodeExcType = EXCTYPE_DSUB    and (((calcResult_sub(63) xor value1(63)) and (value1(63) xor value2(63))) = '1')) else
                     -- See NO_TRAP_INSTR. When set, none of the twelve trap
                     -- terms below is built, and the 64-bit comparator stops
                     -- feeding the exception path.
                     '1' when ((not NO_TRAP_INSTR) and decodeExcType = EXCTYPE_TRAPU0  and calcResult_lesserUnsigned = '0') else
                     '1' when ((not NO_TRAP_INSTR) and decodeExcType = EXCTYPE_TRAPU1  and calcResult_lesserUnsigned = '1') else
                     '1' when ((not NO_TRAP_INSTR) and decodeExcType = EXCTYPE_TRAPS0  and calcResult_lesserSigned = '0') else
                     '1' when ((not NO_TRAP_INSTR) and decodeExcType = EXCTYPE_TRAPS1  and calcResult_lesserSigned = '1') else
                     '1' when ((not NO_TRAP_INSTR) and decodeExcType = EXCTYPE_TRAPE0  and cmpEqual = '0') else
                     '1' when ((not NO_TRAP_INSTR) and decodeExcType = EXCTYPE_TRAPE1  and cmpEqual = '1') else
                     '1' when ((not NO_TRAP_INSTR) and decodeExcType = EXCTYPE_TRAPIU0 and calcResult_lesserIMMUnsigned = '0') else
                     '1' when ((not NO_TRAP_INSTR) and decodeExcType = EXCTYPE_TRAPIU1 and calcResult_lesserIMMUnsigned = '1') else
                     '1' when ((not NO_TRAP_INSTR) and decodeExcType = EXCTYPE_TRAPIS0 and calcResult_lesserIMMSigned = '0') else
                     '1' when ((not NO_TRAP_INSTR) and decodeExcType = EXCTYPE_TRAPIS1 and calcResult_lesserIMMSigned = '1') else
                     '1' when ((not NO_TRAP_INSTR) and decodeExcType = EXCTYPE_TRAPIE0 and calcResult_equal = '0') else
                     '1' when ((not NO_TRAP_INSTR) and decodeExcType = EXCTYPE_TRAPIE1 and calcResult_equal = '1') else
                     '0';
    
   exceptionNewPC <= '1' when (decodeExcType = EXCTYPE_PC and value1(1 downto 0) > 0) else '0';
    
   ---------------------- COP ------------------                  
   FPU_command_ena      <= decodeFPUCommandEnable  when (exception = '0' and stall = 0 and executeIgnoreNext = '0' and decodeNew = '1') else '0';
   FPU_TransferEna      <= decodeFPUTransferEnable when (exception = '0' and stall = 0 and executeIgnoreNext = '0' and decodeNew = '1') else '0';
                     
   EXECOP0WriteValue    <= unsigned(resize(signed(value2(31 downto 0)), 64)) when (decodeCOP64 = '0') else
                           value2;

   -- region check
   -- we optimize the 64bit region to use only the base address for timing purposes. 
   -- If base+immidiate switches the region-> bad luck
   process (value1, calcMemAddr, privilegeMode, region64, kusegUnmapped)
   begin
   
      region_TLBmapped <= '0';
      region_cached    <= '0';
      region_full32    <= '0';
      region_unused    <= '0';
   
      if (region64 = '1') then
         if (privilegeMode = "00") then
            if    (value1 <= x"000000ffffffffff") then region_TLBmapped <= '1';                   
            elsif (value1 <= x"3fffffffffffffff") then region_unused <= '1';                      
            elsif (value1 <= x"400000ffffffffff") then region_TLBmapped <= '1';                   
            elsif (value1 <= x"7fffffffffffffff") then region_unused <= '1';                      
            elsif (value1 <= x"80000000ffffffff") then region_cached <= '1'; region_full32 <= '1';
            elsif (value1 <= x"87ffffffffffffff") then region_unused <= '1';                      
            elsif (value1 <= x"88000000ffffffff") then region_cached <= '1'; region_full32 <= '1';
            elsif (value1 <= x"8fffffffffffffff") then region_unused <= '1';                      
            elsif (value1 <= x"90000000ffffffff") then region_full32 <= '1';                      
            elsif (value1 <= x"97ffffffffffffff") then region_unused <= '1';                      
            elsif (value1 <= x"98000000ffffffff") then region_cached <= '1'; region_full32 <= '1';
            elsif (value1 <= x"9fffffffffffffff") then region_unused <= '1';                      
            elsif (value1 <= x"a0000000ffffffff") then region_cached <= '1'; region_full32 <= '1';
            elsif (value1 <= x"a7ffffffffffffff") then region_unused <= '1';                      
            elsif (value1 <= x"a8000000ffffffff") then region_cached <= '1'; region_full32 <= '1';
            elsif (value1 <= x"afffffffffffffff") then region_unused <= '1';                      
            elsif (value1 <= x"b0000000ffffffff") then region_cached <= '1'; region_full32 <= '1';
            elsif (value1 <= x"b7ffffffffffffff") then region_unused <= '1';                      
            elsif (value1 <= x"b8000000ffffffff") then region_cached <= '1'; region_full32 <= '1';
            elsif (value1 <= x"bfffffffffffffff") then region_unused <= '1';                      
            elsif (value1 <= x"c00000ff7fffffff") then region_TLBmapped <= '1';                   
            elsif (value1 <= x"ffffffff7fffffff") then region_unused <= '1';                      
            elsif (value1 <= x"ffffffff9fffffff") then region_cached <= '1';                      
            elsif (value1 <= x"ffffffffbfffffff") then null;                                           
            elsif (value1 <= x"ffffffffdfffffff") then region_TLBmapped <= '1';                   
            else region_TLBmapped <= '1'; 
            end if;
         elsif (privilegeMode = "01") then
            if    (value1 <= x"000000ffffffffff") then region_TLBmapped <= '1';
            elsif (value1 <= x"3fffffffffffffff") then region_unused <= '1';   
            elsif (value1 <= x"400000ffffffffff") then region_TLBmapped <= '1';
            elsif (value1 <= x"ffffffffbfffffff") then region_unused <= '1';   
            elsif (value1 <= x"ffffffffdfffffff") then region_TLBmapped <= '1';
            else region_unused <= '1';
            end if;
         elsif (privilegeMode = "10") then
            if (value1 <= x"FFFFFFFFFF") then region_TLBmapped <= '1'; end if;
         end if;
      else
         -- kusegUnmapped is Status.ERL. See the note in cpu_cop0.vhd: while it is
         -- set, region < 4 is unmapped and must not go to the TLB.
         if (privilegeMode = "00") then
            if ((calcMemAddr(31 downto 29) < 4 and kusegUnmapped = '0') or calcMemAddr(31 downto 29) = 6 or calcMemAddr(31 downto 29) = 7) then region_TLBmapped <= '1'; end if;
            if (calcMemAddr(31 downto 29) = 4) then region_cached <= '1'; end if;
         elsif (privilegeMode = "01") then
            if ((calcMemAddr(31 downto 29) < 4 and kusegUnmapped = '0') or calcMemAddr(31 downto 29) = 6) then region_TLBmapped <= '1'; end if;
            if (calcMemAddr(31 downto 29) = 4 or calcMemAddr(31 downto 29) = 5 or calcMemAddr(31 downto 29) = 7) then region_unused <= '1'; end if;
         elsif (privilegeMode = "10") then
            if (calcMemAddr(31 downto 29) < 4 and kusegUnmapped = '0') then region_TLBmapped <= '1'; end if;
            if (calcMemAddr(31 downto 29) > 3 and calcMemAddr(31 downto 29) < 8) then region_unused <= '1'; end if;
         end if;
      end if;
   end process;
   
   region64     <= '0' when ADDR32_ONLY else bit64region;

   EXETLBMapped <= region_TLBmapped;
   
   EXETLBDataAccess <= decodeMemReadEnable or decodeMemWriteEnable or decodeCacheTLBTranslate or decodeMemWriteLL when (EXETLBMapped = '1' and exception = '0' and stall = 0 and executeIgnoreNext = '0' and decodeNew = '1') else '0';

   ---------------------- load/store ------------------
   
   EXECacheAddr(31 downto 3) <= calcMemAddr(31 downto 3);
                                
   EXECacheAddr(2 downto 0)  <= "000"                  when (decodeLoadType = LOADTYPE_LEFT64 or decodeLoadType = LOADTYPE_RIGHT64) else 
                                calcMemAddr(2) & "00"  when (decodeLoadType = LOADTYPE_LEFT or decodeLoadType = LOADTYPE_RIGHT) else 
                                calcMemAddr(2 downto 0);  
   
   
   process (all)
      variable rotatedData          : unsigned(63 downto 0) := (others => '0');
      variable storeHalf            : unsigned(15 downto 0) := (others => '0');
   begin
   
      rotatedData             := cpu_to_bus64(value2);
      storeHalf               := cpu_to_bus16(value2(15 downto 0));
      EXEMemWriteData         <= rotatedData;
      EXEMemWriteMask         <= "00000000";
      
      case (decodeMemWriteType) is
      
         when MEMWRITETYPE_BYTE =>
            EXEMemWriteData <= x"00000000" & value2(7 downto 0) & value2(7 downto 0) &
                               value2(7 downto 0) & value2(7 downto 0);
            case (to_integer(calcMemAddr(1 downto 0))) is 
               when 0 => EXEMemWriteMask(3 downto 0) <= "0001";
               when 1 => EXEMemWriteMask(3 downto 0) <= "0010";
               when 2 => EXEMemWriteMask(3 downto 0) <= "0100";
               when 3 => EXEMemWriteMask(3 downto 0) <= "1000";
               when others => null;
            end case;

         when MEMWRITETYPE_HALF =>
            EXEMemWriteData <= x"00000000" & storeHalf & storeHalf;
            if (calcMemAddr(1) = '1') then
               EXEMemWriteMask(3 downto 0) <= "1100";
            else
               EXEMemWriteMask(3 downto 0) <= "0011";
            end if;
               
         when MEMWRITETYPE_WORD =>
            EXEMemWriteMask(3 downto 0) <= "1111";
               
         when MEMWRITETYPE_SWL =>
            if LITTLE_ENDIAN then
               case (to_integer(calcMemAddr(1 downto 0))) is
                  when 0 => EXEMemWriteMask(3 downto 0) <= "0001"; EXEMemWriteData <= x"00000000" & x"000000" & rotatedData(31 downto 24);
                  when 1 => EXEMemWriteMask(3 downto 0) <= "0011"; EXEMemWriteData <= x"00000000" & x"0000" & rotatedData(31 downto 16);
                  when 2 => EXEMemWriteMask(3 downto 0) <= "0111"; EXEMemWriteData <= x"00000000" & x"00" & rotatedData(31 downto 8);
                  when 3 => EXEMemWriteMask(3 downto 0) <= "1111"; EXEMemWriteData <= x"00000000" & rotatedData(31 downto 0);
                  when others => null;
               end case;
            else
               case (to_integer(calcMemAddr(1 downto 0))) is
                  when 0 => EXEMemWriteMask(3 downto 0) <= "1111"; EXEMemWriteData <= x"00000000" & rotatedData(31 downto 0);
                  when 1 => EXEMemWriteMask(3 downto 0) <= "1110"; EXEMemWriteData <= x"00000000" & rotatedData(23 downto 0) & x"00";
                  when 2 => EXEMemWriteMask(3 downto 0) <= "1100"; EXEMemWriteData <= x"00000000" & rotatedData(15 downto 0) & x"0000";
                  when 3 => EXEMemWriteMask(3 downto 0) <= "1000"; EXEMemWriteData <= x"00000000" & rotatedData(7 downto 0) & x"000000";
                  when others => null;
               end case;
            end if;
            
         when MEMWRITETYPE_SWR =>
            if LITTLE_ENDIAN then
               case (to_integer(calcMemAddr(1 downto 0))) is
                  when 0 => EXEMemWriteMask(3 downto 0) <= "1111"; EXEMemWriteData <= x"00000000" & rotatedData(31 downto 0);
                  when 1 => EXEMemWriteMask(3 downto 0) <= "1110"; EXEMemWriteData <= x"00000000" & rotatedData(23 downto 0) & x"00";
                  when 2 => EXEMemWriteMask(3 downto 0) <= "1100"; EXEMemWriteData <= x"00000000" & rotatedData(15 downto 0) & x"0000";
                  when 3 => EXEMemWriteMask(3 downto 0) <= "1000"; EXEMemWriteData <= x"00000000" & rotatedData(7 downto 0) & x"000000";
                  when others => null;
               end case;
            else
               case (to_integer(calcMemAddr(1 downto 0))) is
                  when 0 => EXEMemWriteMask(3 downto 0) <= "0001"; EXEMemWriteData <= x"00000000" & x"000000" & rotatedData(31 downto 24);
                  when 1 => EXEMemWriteMask(3 downto 0) <= "0011"; EXEMemWriteData <= x"00000000" & x"0000" & rotatedData(31 downto 16);
                  when 2 => EXEMemWriteMask(3 downto 0) <= "0111"; EXEMemWriteData <= x"00000000" & x"00" & rotatedData(31 downto 8);
                  when 3 => EXEMemWriteMask(3 downto 0) <= "1111"; EXEMemWriteData <= x"00000000" & rotatedData(31 downto 0);
                  when others => null;
               end case;
            end if;
            
         when MEMWRITETYPE_DWORD =>  
            EXEMemWriteMask <= "11111111";  
               
         when MEMWRITETYPE_SDL =>
            if LITTLE_ENDIAN then
               case (to_integer(calcMemAddr(2 downto 0))) is
                  when 0 => EXEMemWriteMask <= "00000001"; EXEMemWriteData <= x"00000000000000" & rotatedData(63 downto 56);
                  when 1 => EXEMemWriteMask <= "00000011"; EXEMemWriteData <= x"000000000000" & rotatedData(63 downto 48);
                  when 2 => EXEMemWriteMask <= "00000111"; EXEMemWriteData <= x"0000000000" & rotatedData(63 downto 40);
                  when 3 => EXEMemWriteMask <= "00001111"; EXEMemWriteData <= x"00000000" & rotatedData(63 downto 32);
                  when 4 => EXEMemWriteMask <= "00011111"; EXEMemWriteData <= x"000000" & rotatedData(63 downto 24);
                  when 5 => EXEMemWriteMask <= "00111111"; EXEMemWriteData <= x"0000" & rotatedData(63 downto 16);
                  when 6 => EXEMemWriteMask <= "01111111"; EXEMemWriteData <= x"00" & rotatedData(63 downto 8);
                  when 7 => EXEMemWriteMask <= "11111111"; EXEMemWriteData <= rotatedData;
                  when others => null;
               end case;
            else
               case (to_integer(calcMemAddr(2 downto 0))) is
                  when 0 => EXEMemWriteMask <= "11111111"; EXEMemWriteData <= rotatedData(63 downto 0);
                  when 1 => EXEMemWriteMask <= "11101111"; EXEMemWriteData <= rotatedData(55 downto 0) & rotatedData(63 downto 56);
                  when 2 => EXEMemWriteMask <= "11001111"; EXEMemWriteData <= rotatedData(47 downto 0) & rotatedData(63 downto 48);
                  when 3 => EXEMemWriteMask <= "10001111"; EXEMemWriteData <= rotatedData(39 downto 0) & rotatedData(63 downto 40);
                  when 4 => EXEMemWriteMask <= "00001111"; EXEMemWriteData <= rotatedData(31 downto 0) & rotatedData(63 downto 32);
                  when 5 => EXEMemWriteMask <= "00001110"; EXEMemWriteData <= rotatedData(23 downto 0) & rotatedData(63 downto 24);
                  when 6 => EXEMemWriteMask <= "00001100"; EXEMemWriteData <= rotatedData(15 downto 0) & rotatedData(63 downto 16);
                  when 7 => EXEMemWriteMask <= "00001000"; EXEMemWriteData <= rotatedData(7 downto 0) & rotatedData(63 downto 8);
                  when others => null;
               end case;
            end if;
            
         when MEMWRITETYPE_SDR =>
            if LITTLE_ENDIAN then
               case (to_integer(calcMemAddr(2 downto 0))) is
                  when 0 => EXEMemWriteMask <= "11111111"; EXEMemWriteData <= rotatedData;
                  when 1 => EXEMemWriteMask <= "11111110"; EXEMemWriteData <= rotatedData(55 downto 0) & x"00";
                  when 2 => EXEMemWriteMask <= "11111100"; EXEMemWriteData <= rotatedData(47 downto 0) & x"0000";
                  when 3 => EXEMemWriteMask <= "11111000"; EXEMemWriteData <= rotatedData(39 downto 0) & x"000000";
                  when 4 => EXEMemWriteMask <= "11110000"; EXEMemWriteData <= rotatedData(31 downto 0) & x"00000000";
                  when 5 => EXEMemWriteMask <= "11100000"; EXEMemWriteData <= rotatedData(23 downto 0) & x"0000000000";
                  when 6 => EXEMemWriteMask <= "11000000"; EXEMemWriteData <= rotatedData(15 downto 0) & x"000000000000";
                  when 7 => EXEMemWriteMask <= "10000000"; EXEMemWriteData <= rotatedData(7 downto 0) & x"00000000000000";
                  when others => null;
               end case;
            else
               case (to_integer(calcMemAddr(2 downto 0))) is
                  when 0 => EXEMemWriteMask <= "00010000"; EXEMemWriteData <= rotatedData(55 downto 0) & rotatedData(63 downto 56);
                  when 1 => EXEMemWriteMask <= "00110000"; EXEMemWriteData <= rotatedData(47 downto 0) & rotatedData(63 downto 48);
                  when 2 => EXEMemWriteMask <= "01110000"; EXEMemWriteData <= rotatedData(39 downto 0) & rotatedData(63 downto 40);
                  when 3 => EXEMemWriteMask <= "11110000"; EXEMemWriteData <= rotatedData(31 downto 0) & rotatedData(63 downto 32);
                  when 4 => EXEMemWriteMask <= "11110001"; EXEMemWriteData <= rotatedData(23 downto 0) & rotatedData(63 downto 24);
                  when 5 => EXEMemWriteMask <= "11110011"; EXEMemWriteData <= rotatedData(15 downto 0) & rotatedData(63 downto 16);
                  when 6 => EXEMemWriteMask <= "11110111"; EXEMemWriteData <= rotatedData(7 downto 0) & rotatedData(63 downto 8);
                  when 7 => EXEMemWriteMask <= "11111111"; EXEMemWriteData <= rotatedData(63 downto 0);
                  when others => null;
               end case;
            end if;
         
         when MEMWRITETYPE_COP1L =>         
            EXEMemWriteMask(3 downto 0) <= "1111";
            EXEMemWriteData(31 downto 0) <= cpu_to_bus32(decodeFPUValue2(31 downto 0));
                  
         when MEMWRITETYPE_COP1H =>         
            EXEMemWriteMask(3 downto 0) <= "1111";
            EXEMemWriteData(31 downto 0) <= cpu_to_bus32(decodeFPUValue2(63 downto 32));
               
         when MEMWRITETYPE_COP1D =>    
            EXEMemWriteMask <= "11111111";
            EXEMemWriteData   <= cpu_to_bus64(decodeFPUValue2);

      end case;

   end process;
   
   
   process (clk93)
   begin
      if (rising_edge(clk93)) then
      
         DIVstart    <= '0';
      
         if (reset_93 = '1') then
         
            stall3                        <= '0';
            executeNew                    <= '0';
            executeIgnoreNext             <= '0';
            executeStallFromMEM           <= '0';

            resultWriteEnable             <= '0';
            executeBranchdelaySlot        <= '0';
            executeMemWriteEnable         <= '0';
            executeMemReadEnable          <= '0';
            executeCOP0WriteEnable        <= '0';
            executeICacheEnable           <= '0';
            executeDCacheEnable           <= '0';
            executeSetLL                  <= '0';
            llBit                         <= '0';
            hiloWait                      <= 0;
            exceptionAllowDelay           <= '0';
            
            hi                            <= unsigned(ss_in(3)); -- (others => '0');
            lo                            <= unsigned(ss_in(4)); -- (others => '0');
            
         elsif (ce_93 = '1') then
            
            -- load delay block
            if (stall3) then
            
               if (stall = "00100") then
                  executeStallFromMEM <= '0';
                  executeNew          <= '0';
                  perf_ex_ld          <= '1';  -- perf-only
               end if;

               if (writebackStallFromMEM = '1') then
                  if (writebackNew = '1' or (mem_finished_read = '1' and writeback_COP1_ReadEnable = '0')) then
                     stall3 <= '0';
                  end if;
               end if;
               
               -- The answer must be THIS load's: presented now, so stage 4 is
               -- not stalled. With LOAD_INTERLOCK an older load that did not
               -- bubble can still be missing in writeback behind it, and its
               -- answer would release this one's bubble: the dependent
               -- instruction would run on the old register, and
               -- executeStallFromMEM - cleared only in the bubble cycle this
               -- skipped - would stay set. See the assertion beside
               -- stall4Masked.
               if (executeStallFromMEM = '1') then               
                  if (executeMemReadEnable = '1' and executeCOP1ReadEnable = '0') then
                     if (executeMemUseCache = '1') then
                        if (datacache_readdone = '1' and (not LOAD_INTERLOCK or stall4 = '0')) then
                           stall3 <= '0';
                        end if;
                     end if;
                  end if;
               end if;
               
            end if;
            
            -- mul/div calc/wait
            if (hiloWait > 0) then
               hiloWait <= hiloWait - 1;
               if (hiloWait = 1) then
                  stall3     <= '0';
                  executeNew <= '1';
                  case (hilocalc) is
                     when HILOCALC_MULT | HILOCALC_MULTU => 
                        hi <= unsigned(resize(  signed(mulResult(63 downto 32)),64)); 
                        lo <= unsigned(resize(  signed(mulResult(31 downto 0)),64));
                     when HILOCALC_DMULT | HILOCALC_DMULTU => 
                        hi <= unsigned(mulResult(127 downto 64)); 
                        lo <= unsigned(mulResult(63 downto 0));
                     when HILOCALC_DIV | HILOCALC_DIVU => 
                        hi <= unsigned(resize(DIVremainder(31 downto  0), 64)); 
                        lo <= unsigned(resize(DIVquotient(31 downto 0), 64));
                     when HILOCALC_DDIV | HILOCALC_DDIVU => 
                        hi <= unsigned(DIVremainder(63 downto  0)); 
                        lo <= unsigned(DIVquotient(63 downto 0));
                  end case;
               end if;
            end if;
            
            -- FPU unstall
            execute_unstallFPUForward <= '0';
            
            if (FPU_command_done = '1') then
               if (decodeFPUForwardUse = '1' and FPU_fwd_valid = '0') then
                  execute_unstallFPUForward <= '1';
               else
                  stall3     <= '0';
                  executeNew <= '1';
               end if;
            end if;
            
            if (execute_unstallFPUForward = '1') then
               stall3     <= '0';
               executeNew <= '1';
            end if;
            
            -- TLB unstall            
            if (TLB_dataUnStall = '1') then
               executeMemAddress     <= TLB_dataAddrOutLookup;
               executeNew            <= '1';
               if (exception = '0') then
                  if (executeMemReadEnable = '1') then
                     executeStallFromMEM <= '1';
                  else
                     stall3              <= '0';
                  end if;
               else
                  stall3                <= '0';
                  executeMemReadEnable  <= '0';
                  executeMemWriteEnable <= '0';
                  executeICacheEnable   <= '0';
                  executeDCacheEnable   <= '0';
               end if;
               if (TLB_dataUseCacheLookup = '1' and DATACACHEON_intern = '1') then
                  executeMemUseCache <= DATACACHETLBON_intern;
               else
                  executeMemUseCache <= '0';
               end if;
            end if;
            

            if (stall = 0) then
            
               executeNew              <= '0';
               perf_ex_ld              <= '0';  -- perf-only
               executeICacheEnable     <= '0';
               executeDCacheEnable     <= '0';
               executeSetLL            <= '0';
               
               resultData              <= resultDataMuxed64;    
               resultTarget            <= decodeTarget;
                  
               executeMem64Bit         <= decodeMem64Bit;
               executeMemWriteData     <= EXEMemWriteData;             
               executeMemWriteMask     <= EXEMemWriteMask;
               executeMemReadLastData  <= value2;           
               executeMergeFwd         <= '0';

               executeLLfromTLB        <= EXETLBDataAccess;
               if (EXETLBDataAccess = '1') then
                  executeMemAddress <= TLB_dataAddrOutFound;
               elsif (region_full32 = '1') then
                  executeMemAddress <= calcMemAddr(31 downto 0);
               else
                  executeMemAddress <= "000" & calcMemAddr(28 downto 0);
               end if;
               
               executeCOP0WriteValue   <= EXECOP0WriteValue; 

               executeBranchdelaySlot  <= EXEBranchdelaySlot;                
            
               if (exception = '1') then                          
                  stall3                        <= '0';
                  executeNew                    <= '0';
                  executeIgnoreNext             <= '0';
                     
                  resultWriteEnable             <= '0';
                  executeMemReadEnable          <= '0';
                  executeMemWriteEnable         <= '0';
                  executeCOP0WriteEnable        <= '0';
               end if;
                  
               if (decodeNew = '1' and (exception = '0' or exceptionAllowDelay = '1')) then     
               
                  executeIgnoreNext             <= EXEIgnoreNext;
                  exceptionAllowDelay           <= '0';
                   
                  if (executeIgnoreNext = '1') then
                  
                     resultWriteEnable      <= '0';
                     executeCOP0WriteEnable <= '0';
                     executeCOP0ReadEnable  <= '0';
                     executeICacheEnable    <= '0';
                     executeDCacheEnable    <= '0';
                     executeMemReadEnable   <= '0';
                     executeMemWriteEnable  <= '0';
                  
                  else

                     executeNew                    <= '1';
                     executeMergeFwd               <= decodeMergeFwd;

-- synthesis translate_off
                     executeMergeBehind            <= executeNew and executeMemReadEnable;
                     pcOld2                        <= pcOld1;
                     opcode2                       <= opcode1;
-- synthesis translate_on
                            
                     -- from calculation
                     if (decodeTarget = 0 or exceptionNew3 = '1') then
                        resultWriteEnable <= '0';
                     else
                        resultWriteEnable <= decodeResultWriteEnable;
                     end if;
                       
                     executeMemWriteEnable <= '0';
                     if (EXEExceptionMem = '0') then
                        if (decodeMemWriteEnable = '1') then
                           executeMemWriteEnable <= '1';
                        elsif (decodeMemWriteLL = '1') then
                           executeMemWriteEnable <= llBit;
                        end if;
                     end if;
                        
                     executeLoadType               <= decodeLoadType;   
                     executeMemReadEnable          <= decodeMemReadEnable and (not EXEExceptionMem); 
   
                     execute_ERET                  <= decodeERET;
                     executeCOP0WriteEnable        <= decodeCOP0WriteEnable;     
                     executeCOP0ReadEnable         <= decodeCOP0ReadEnable;      
                     executeCOP0Register           <= decodeCOP0Register;
                     
                     executeCOP1ReadEnable         <= decodeCOP1ReadEnable;
                     executeCOP1Target             <= decodeSource2;
                     
                     executeCOP2WriteEnable        <= decodeCOP2WriteEnable;     
                     executeCOP2ReadEnable         <= decodeCOP2ReadEnable; 
                     
                     executeCOP64                  <= decodeCOP64;

                     executeSetLL                  <= decodeSetLL;

                     if (decodeExcType = EXCTYPE_PC and value1(1 downto 0) > 0) then
                        exceptionAllowDelay <= '1';
                     end if;

                     if (decodeERET = '1') then
                        llBit <= '0';
                     elsif (EXEExceptionMem = '0') then
                        if (decodeResetLL = '1') then
                           llBit <= '0';
                        elsif (decodeSetLL = '1') then
                           llBit <= '1';
                        end if;
                     end if;

                     executeMemUseCache <= '0';
                     if (EXETLBDataAccess = '1') then
                        if (TLB_dataUseCacheFound = '1' and DATACACHEON_intern = '1') then
                           executeMemUseCache <= DATACACHETLBON_intern;
                        end if;
                     else
                        if (region_cached = '1' and DATACACHEON_intern = '1') then
                           executeMemUseCache <= '1';
                        end if;
                     end if;

                     executeICacheEnable           <= decodeCacheEnable;
                     executeDCacheEnable           <= decodeCacheEnable;
                     executeCacheCommand           <= decodeSource2;
                     
                     if (DATACACHEON_intern = '0' or (DATACACHETLBON_intern = '0' and EXETLBDataAccess = '1')) then
                        executeDCacheEnable <= '0';
                     end if;
                     
                     execute_TLBR                  <= decodeTLBR; 
                     execute_TLBWI                 <= decodeTLBWI;
                     execute_TLBWR                 <= decodeTLBWR;
                     execute_TLBP                  <= decodeTLBP; 
                     
                     -- new mul/div
                     if (decodecalcMULT = '1') then
                        hilocalc <= HILOCALC_MULT;
                        mulsign  <= '1';
                        mul1     <= std_logic_vector(resize(signed(value1(31 downto 0)), 64));
                        mul2     <= std_logic_vector(resize(signed(value2(31 downto 0)), 64));
                        hiloWait <= 4;
                        stall3   <= '1';
                     end if;
                     
                     if (decodecalcMULTU = '1') then
                        hilocalc <= HILOCALC_MULTU;
                        mulsign  <= '0';
                        mul1     <= x"00000000" & std_logic_vector(value1(31 downto 0));
                        mul2     <= x"00000000" & std_logic_vector(value2(31 downto 0));
                        hiloWait <= 4;
                        stall3   <= '1';
                     end if;
                     
                     if (decodecalcDMULT = '1') then
                        hilocalc <= HILOCALC_DMULT;
                        mulsign  <= '1';
                        mul1     <= std_logic_vector(value1);
                        mul2     <= std_logic_vector(value2);
                        hiloWait <= 7;
                        stall3   <= '1';
                     end if;
                     
                     if (decodecalcDMULTU = '1') then
                        hilocalc <= HILOCALC_DMULTU;
                        mulsign  <= '0';
                        mul1     <= std_logic_vector(value1);
                        mul2     <= std_logic_vector(value2);
                        hiloWait <= 7;
                        stall3   <= '1';
                     end if;
                     
                     if (decodeFPUMULS = '1') then
                        mulsign  <= '0';
                        mul1 <= 40x"0" & '0' & std_logic_vector(decodeFPUValue1(22 downto 0));
                        mul2 <= 40x"0" & '0' & std_logic_vector(decodeFPUValue2(22 downto 0));
                        if (decodeFPUValue1(30 downto 23) > 0) then mul1(23) <= '1'; end if;
                        if (decodeFPUValue2(30 downto 23) > 0) then mul2(23) <= '1'; end if;
                     end if;
                     
                     if (decodeFPUMULD = '1') then
                        mulsign  <= '0';
                        mul1 <= 11x"0" & '0' & std_logic_vector(decodeFPUValue1(51 downto 0));
                        mul2 <= 11x"0" & '0' & std_logic_vector(decodeFPUValue2(51 downto 0));
                        if (decodeFPUValue1(62 downto 52) > 0) then mul1(52) <= '1'; end if;
                        if (decodeFPUValue2(62 downto 52) > 0) then mul2(52) <= '1'; end if;
                     end if;
                     
                     if (decodecalcDIV = '1') then
                        DIVis32     <= '1';
                        hiloWait    <= 36;
                        stall3      <= '1';
                        DIVdividend <= resize(signed(value1(31 downto 0)), 65);
                        DIVdivisor  <= resize(signed(value2(31 downto 0)), 65);
                        hilocalc    <= HILOCALC_DIV;
                        DIVstart    <= '1';
                     end if;
                     
                      if (decodecalcDDIV = '1') then
                        DIVis32     <= '0';
                        hiloWait    <= 68;
                        stall3      <= '1';
                        DIVdividend <= resize(signed(value1), 65);
                        DIVdivisor  <= resize(signed(value2), 65);
                        hilocalc    <= HILOCALC_DDIV;
                        DIVstart    <= '1';
                     end if;
                     
                     if (decodecalcDIVU = '1') then
                        DIVis32     <= '1';
                        hiloWait    <= 36;
                        stall3      <= '1';
                        DIVdividend <= '0' & x"00000000" & signed(value1(31 downto 0));
                        DIVdivisor  <= '0' & x"00000000" & signed(value2(31 downto 0));
                        hilocalc    <= HILOCALC_DIVU;
                        DIVstart    <= '1';
                     end if;
                     
                     if (decodecalcDDIVU = '1') then
                        DIVis32     <= '0';
                        hiloWait    <= 68;
                        stall3      <= '1';
                        DIVdividend <= '0' & signed(value1);
                        DIVdivisor  <= '0' & signed(value2);
                        hilocalc    <= HILOCALC_DDIVU;
                        DIVstart    <= '1';
                     end if;
                     
                     if (decodehiUpdate = '1') then hi <= value1; end if;
                     if (decodeloUpdate = '1') then lo <= value1; end if;
                     
                     if ((EXEExceptionMem = '0' and decodeMemReadEnable = '1' and load_use = '1') or decodeCOP0ReadEnable = '1' or decodeCOP2ReadEnable = '1') then
                        stall3              <= '1';
                        executeStallFromMEM <= '1';
                     end if;
                     
                     if (FPU_command_ena = '1' and FPU_command_done = '0') then
                        stall3 <= '1';
                     end if;
                     
                     if (decFPUForwardUse = '1') then
                        stall3 <= '1';
                        if (FPU_command_done = '1' or FPU_command_ena = '0') then
                           execute_unstallFPUForward <= '1';
                        end if;
                     end if;
                        
                     -- The TLB stall term belongs here, as the last
                     -- assignment inside this nest. It is hoisted to the end of
                     -- the process instead; see below.

                  end if;

               end if;


            end if;

            -- Hoisted TLB stall.
            --
            -- stall3 is a critical endpoint in the CPU domain, and the last
            -- thing to arrive is TLB_dataStall, which sits behind the
            -- address adder and the mini-TLB CAM. Written inside the nest above,
            -- this term would reach stall3's D input through two logic levels,
            -- because synthesis has to interleave it with the enclosing
            -- set/clear priority cone. Hoisted to the end of the process it is
            -- one OR against everything else, and everything else settles well
            -- before it does.
            --
            -- No gate is needed, and that is not an approximation. Inside the
            -- nest this term fires only within "stall = 0", "decodeNew = '1'
            -- and (exception = '0' or exceptionAllowDelay = '1')" and
            -- "executeIgnoreNext = '0'", but
            -- TLB_dataStall is TLB_dataReq and not mini_hit, and TLB_dataReq is
            -- EXETLBDataAccess, which is already '0' unless exception = '0',
            -- stall = 0, executeIgnoreNext = '0' and decodeNew = '1'. Every
            -- enclosing condition is therefore implied by the term itself, so
            -- the hoisted form fires on exactly the same cycles.
            --
            -- executeStallFromMEM comes with it and stays correct at the end.
            -- The two earlier writes it must not disturb are the load-delay
            -- block's clear, which requires stall3 = '1', and the TLB unstall's
            -- set, which requires TLB_dataUnStall. Both imply stall /= 0, which
            -- TLB_dataStall excludes, so neither can coincide with this one.
            if (TLB_dataStall = '1') then
               stall3              <= '1';
               executeStallFromMEM <= '0';
            end if;

         end if;

      end if;
   end process;
   
   
--##############################################################
--############################### stage 4
--##############################################################

   cache_commandEnableD <= executeDCacheEnable when (stall = 0) else '0';

   icpu_datacache : entity work.cpu_datacache
   generic map
   (
      LITTLE_ENDIAN => LITTLE_ENDIAN,
      SKIP_FILL     => DCACHE_SKIP_FILL,
      FB_PARTIAL    => DCACHE_FB_PARTIAL,
      WB_EARLY      => DCACHE_WB_EARLY,
      LOAD_INTERLOCK => LOAD_INTERLOCK,
      STORE_BUFFER  => DCACHE_STORE_BUFFER,
      SB_FORWARD    => DCACHE_SB_FORWARD,
      EARLY_RESTART => DCACHE_EARLY_RESTART,
      RA_ANSWER     => DCACHE_RA_ANSWER,
      CWF_FB        => DCACHE_CWF_FB,
      FILL_FIRST    => DCACHE_FILL_FIRST,
      FILL_AT_MISS  => DCACHE_FILL_AT_MISS,
      RA_CROSS_PAGE => DCACHE_RA_CROSS_PAGE,
      RA_CHAIN      => (RA_CHAIN /= 0),
      READ_AHEAD    => DCACHE_READ_AHEAD
   )
   port map
   (
      clk1x             => clk1x,
      clk93             => clk93,
      reset_1x          => reset_1x,
      reset_93          => reset_93,
      ce_93             => ce_93,
      stall             => stall,
      stall4            => stall4,
      fifo_block        => writefifo_block,
      
      slow_in           => DATACACHESLOW,
      force_wb_in       => DATACACHEFORCEWEB,
      write_through_in  => DATACACHEWRITETHROUGH,
      
      ram_request       => datacache_request_raw,
      ram_reqAddr       => datacache_reqAddr,
      ram_active        => dc_active,
      ram_grant         => dc_grant,
      ram_done          => datacache_fill_done,
      fill_last_q       => datacache_fill_last,
      wb_hold           => datacache_wb_hold,
      ddr3_DOUT         => dc_dout,
      ddr3_DOUT_READY   => dc_ready,
      
      writeback_ena     => datacache_wb_ena,  
      writeback_addr    => datacache_wb_addr, 
      writeback_data    => datacache_wb_data,
      writeback_mask    => datacache_wb_mask,
      writeback_bytes   => datacache_wb_bytes,

      tag_addr          => EXECacheAddr,
      next_load         => datacache_next_load,
      
      read_ena          => datacache_readena,
      RW_addr           => datacache_addr,
      RW_64             => executeMem64Bit,
      RW_fb             => executeMemFB,
      read_busy         => datacache_readbusy,
      read_done         => datacache_readdone,
      read_data         => datacache_data_out,
      
      write_ena         => datacache_writeena,
      write_be          => executeMemWriteMask,
      write_data        => std_logic_vector(executeMemWriteData),
      write_done        => datacache_writedone,
      
      CacheCommandEna   => cache_commandEnableD,
      CacheCommand      => executeCacheCommand,
      CachecommandStall => datacache_CmdStall,
      CachecommandDone  => datacache_CmdDone,    
      
      TagLo_Valid       => TagLo_Valid,
      TagLo_Dirty       => TagLo_Dirty,
      TagLo_Addr        => TagLo_Addr, 
      
      writeTagEna       => writeDatacacheTagEna,      
      writeTagValue     => writeDatacacheTagValue,

      clear_busy        => datacache_clear_busy,
      debug_state       => datacache_debug_state,
      perf_miss         => datacache_perf_miss,
      perf_miss_low     => datacache_perf_miss_low,
      perf_fill_wait    => datacache_perf_fill_wait,
      perf_fill_data    => open,
      perf_fill_hold    => open,
      perf_writeback    => open,
      perf_stride_hit   => datacache_perf_stride_hit,
      perf_way_slow     => open,
      perf_wb_line      => datacache_perf_wb_line,
      perf_fill_store   => datacache_perf_fill_store,
      perf_fill_skip    => datacache_perf_fill_skip,
      perf_fill_absent  => datacache_perf_fill_absent,
      perf_delta_hit    => open,
      ra_request        => datacache_ra_request,
      ra_reqAddr        => datacache_ra_addr,
      ra_reqStream      => datacache_ra_stream,
      ra_done           => datacache_ra_done,
      ra_data           => datacache_ra_data,
      ra_store          => datacache_ra_store,
      ra_store_addr     => unsigned(writefifo_Din(95 downto 64)),
      ra_wr             => datacache_ra_wr,
      ra_chain_ok       => datacache_ra_chain_ok,
      ra_chain_addr     => datacache_ra_chain_addr,
      ra_chain_sdram    => datacache_ra_chain_sdram,
      ra_chain_taken    => datacache_ra_chain_taken,
      perf_ra_issue     => open,
      perf_ra_used      => open,
      tail_q_ok         => fast_tail_q_ok,
      SS_reset          => SS_reset
   );

   stall4Masked <= stall(4 downto 3) & (stall(2) and (not executeStallFromMEM)) & stall(1 downto 0);

   -- THE DIRECT FILL PATH. A data-cache demand fill goes to ki_sdram_burst's
   -- second port instead of the write FIFO when nothing of the CPU's is
   -- anywhere in the bridge's path - the write FIFO and its issue register,
   -- the mailbox, clk1x's transaction, the response FIFO, the write-back
   -- staging queue, the scheduler's latched requests - and the bridge holds
   -- and runs nothing of the CPU's (fast_ok). Then no write of the CPU's can
   -- be on its way to SDRAM beside the fill, and no other request can reach
   -- the controller before this one is taken: the CPU's next one has the
   -- whole bridge path to cross first. Lines outside SDRAM RAM - the
   -- framebuffer pages, the boot ROM - keep the bridge, as does every other
   -- request.
   --
   -- The one exception is a line written back into the framebuffer: it goes
   -- to the on-chip RAM alone, so it may be clk1x's transaction
   -- (mem_line_fb), waiting in the bridge or being written there. A miss
   -- whose victim is a framebuffer line then takes the path while its victim
   -- is still on its way.
   --
   -- The read-ahead's line fetch goes the same way under the same rule
   -- (fast_ra_go), when no demand miss is asking. A store to its line from
   -- the request until the line lands makes the copy stale in the cache
   -- (ra_store), whichever way the line came; one that entered the write
   -- path before the request is ahead of it, which the rule keeps true.
   --
   -- So does an uncached 64-bit load of SDRAM RAM, qword-aligned, as a qword
   -- read (fast_unc_go), when no demand miss is asking; it waits for every
   -- store ahead of it like the rest. Narrower loads, I/O, the boot ROM and
   -- the framebuffer keep the bridge.
   --
   -- With DCACHE_EARLY_RESTART a load miss is answered before its line has
   -- landed, and the CPU may miss again while it lands. That demand fill
   -- leaves at once, a second direct read behind the first (fast_go_q), when
   -- the one outstanding is a demand fill whose first beat has come - so the
   -- controller has taken it, and a second toggle cannot be taken for the
   -- first - and nothing of the CPU's is in the bridge's path. The controller
   -- takes the second once the first has drained, and ki_fast_fill opens its
   -- window once the first's has closed, so the two come back in order and
   -- the first's completion is the first done toggle. Otherwise the data
   -- cache holds the request until the line has landed.
   --
   -- With RA_CHAIN the read-ahead of the line after the one the data cache
   -- waits for in FILLRA_WAIT leaves as that one completes, without an ask
   -- (fast_chain_term): the cache arms it while it waits (ra_chain_ok, with
   -- the line in ra_chain_addr), learns of its launch on the next edge
   -- (ra_chain_taken), and stages it as in flight when it leaves FILLRA_WAIT,
   -- asking for nothing. One that cannot leave then is not sent at all: the
   -- cache asks for it as the copy starts, as without RA_CHAIN.
   fast_line       <= datacache_reqAddr(31 downto 5) & "00000";
   fast_line_ok    <= is_sdram_line(fast_line);
   fast_ra_line    <= (datacache_ra_chain_addr(31 downto 5) & "00000") when (fast_chain_term = '1') else
                      (datacache_ra_addr(31 downto 5) & "00000");
   -- The ask's line. The armed line after was tested as it was armed
   -- (datacache_ra_chain_sdram), so a chained launch is not tested again
   -- (asserted), and its select stays off this compare.
   fast_ra_line_ok <= is_sdram_line(datacache_ra_addr(31 downto 5) & "00000");
   -- The line after the one the data cache is filling, for its arm: the
   -- direct port reads only SDRAM RAM.
   datacache_ra_chain_sdram <= is_sdram_line((datacache_reqAddr(31 downto 5) + 1) & "00000");
   fast_busy       <= '1' when (fast_out /= 0) else '0';
   fast_path_quiet <= '1' when (writefifo_Empty = '1' and writefifo_issue_pending = '0' and
                                write_cdc_busy_93 = '0' and
                                (memstate = MEMSTATE_IDLE or mem_line_fb = '1') and
                                resp_fifo_empty = '1' and response_cdc_pending_93 = '0' and
                                response_cdc_deliver_93 = '0' and
                                datacache_request_latched = '0' and mem1_request_latched = '0' and
                                datacache_wb_fifo_count = 0 and wb_line_issued = '0' and
                                datacache_wb_ena = '0') else '0';
   fast_path_clear <= fast_ok and (not fast_busy) and fast_path_quiet;
   fast_q_clear    <= '1' when (FAST_ON and DCACHE_EARLY_RESTART and fast_out = 1 and
                                fast_is_ra_r = '0' and fast_is_unc_r = '0' and
                                fast_first_seen = '1' and fast_ok = '1' and
                                fast_path_quiet = '1') else '0';
   fast_tail_q_ok  <= fast_q_clear and fast_line_ok;
   fast_go_q       <= '1' when (datacache_request_raw = '1' and fast_tail_q_ok = '1') else '0';
   fast_go         <= '1' when (FAST_ON and datacache_request_raw = '1' and
                                fast_line_ok = '1' and fast_path_clear = '1') else '0';
   -- RA_LAUNCH_EARLY: also from the cache's ask, in the cycle after the edge
   -- that registered it and datacache_ra_addr together, unless a load leaves
   -- from stage 3 on this edge; then it waits in pending as before. One ask is
   -- never pending beside another: the cache has one read-ahead in flight.
   -- RA_CHAIN: also the cache's armed line after, without an ask
   -- (fast_chain_term).
   fast_ra_go      <= '1' when (FAST_ON and DCRA_ON and
                                (((datacache_ra_pending = '1' or
                                   (RA_LAUNCH_EARLY and datacache_ra_request = '1' and
                                    fast_s3_go = '0')) and fast_path_clear = '1' and
                                  fast_ra_line_ok = '1') or
                                 fast_chain_term = '1') and
                                datacache_request_raw = '0' and fast_unc_go = '0') else '0';
   -- RA_CHAIN: the armed line after leaves as the read-ahead the cache waits
   -- for completes. 1: in the cycle its datacache_ra_done is high, under the
   -- usual rule - that completion took fast_out down on the edge that
   -- registered it. 2: in the cycle the direct read-ahead outstanding comes
   -- back (fast_ra_land), on the edge that registers its completion, which
   -- takes fast_out down as this launch takes it up; nothing else of the
   -- CPU's may be in the bridge's path, as for any direct read. Never in a
   -- reset, never beside a load leaving from stage 3, nor beside an ask,
   -- which the cache makes only with no read-ahead in flight (asserted).
   fast_ra_land    <= '1' when (fast_ra_ret = '1' or
                                (fast_done_tog /= fast_done_seen and fast_is_ra_r = '1')) else '0';
   fast_chain_term <= '1' when (FAST_ON and DCRA_ON and RA_CHAIN /= 0 and reset_93 = '0' and
                                datacache_ra_chain_ok = '1' and fast_s3_go = '0' and
                                ((RA_CHAIN = 1 and datacache_ra_done = '1' and fast_path_clear = '1') or
                                 (RA_CHAIN = 2 and fast_ra_land = '1' and fast_out = 1 and
                                  fast_ok = '1' and fast_path_quiet = '1'))) else '0';
   fast_chain_go   <= fast_ra_go and fast_chain_term;
   fast_unc_ok     <= '1' when (mem4_req64 = '1' and mem4_address(2 downto 0) = "000" and
                                is_sdram_line(mem4_address(31 downto 5) & "00000") = '1') else '0';
   fast_unc_go     <= '1' when (FAST_ON and mem4_request = '1' and mem4_rnw = '1' and
                                writefifo_mem4_ready = '1' and fast_unc_ok = '1' and
                                datacache_request_raw = '0' and fast_path_clear = '1') else '0';
   fast_unc_ret    <= '1' when (FAST_ON and fast_unc_valid = '1' and fast_is_unc_r = '1') else '0';
   -- RA_CTL_RETURN: a direct read-ahead's qwords on fast_ra_valid, the
   -- fourth its completion.
   fast_ra_take    <= '1' when (FAST_ON and DCRA_ON and RA_CTL_RETURN and fast_ra_valid = '1' and
                                fast_is_ra_r = '1') else '0';
   fast_ra_ret     <= '1' when (fast_ra_take = '1' and fast_ra_q = 3) else '0';
   fast_ret        <= '1' when (fast_done_tog /= fast_done_seen or fast_unc_ret = '1' or
                                fast_ra_ret = '1') else '0';

   -- UNC_LAUNCH_S3. An uncached load in stage 4 completes in a cycle with
   -- mem_finished_read. If the instruction waiting in stage 3 is an uncached
   -- 64-bit load of SDRAM RAM, qword-aligned, it goes to the direct port on
   -- that edge, under fast_unc_go's rule: nothing of the CPU's in the
   -- bridge's path, so every store ahead of it has been written. The edge
   -- releases stage 4 and nothing else stalls, so stage 4 presents the load
   -- on the next (asserted); in that cycle the bridge's load branch stands
   -- aside (fast_s3_launched), and fast_unc_go cannot fire, the read being
   -- outstanding. Its completion releases stage 4 as fast_unc_go's does.
   fast_s3_go      <= '1' when (FAST_ON and UNC_LAUNCH_S3 and
                                mem_finished_read = '1' and stall4 = '1' and
                                writeback_UseCache = '0' and
                                executeNew = '1' and executeMemReadEnable = '1' and
                                executeMemUseCache = '0' and executeMem64Bit = '1' and
                                executeLoadType = LOADTYPE_QWORD and
                                executeMemAddress(2 downto 0) = "000" and
                                is_sdram_line(executeMemAddress(31 downto 5) & "00000") = '1' and
                                stall1 = '0' and stall2 = '0' and stall3 = '0' and
                                fast_out = 0 and fast_ok = '1' and fast_path_quiet = '1' and
                                datacache_request_raw = '0' and datacache_ra_pending = '0' and
                                read_fifoStall = '0' and writeback_fifoStall = '0') else '0';

   -- A direct uncached load's qword, at its one beat.
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (FAST_ON and fast_is_unc_r = '1' and fast_window = '1' and fast_beat = '1') then
            fast_unc_q_1x <= fast_qword;
         end if;
      end if;
   end process;

-- synthesis translate_off
   process (clk93)
      variable reset_d : std_logic := '1';
      variable n_go    : integer;
   begin
      if rising_edge(clk93) then
         -- One direct request at most leaves on an edge.
         n_go := 0;
         if (fast_go = '1')     then n_go := n_go + 1; end if;
         if (fast_go_q = '1')   then n_go := n_go + 1; end if;
         if (fast_ra_go = '1')  then n_go := n_go + 1; end if;
         if (fast_unc_go = '1') then n_go := n_go + 1; end if;
         if (fast_s3_go = '1')  then n_go := n_go + 1; end if;
         assert n_go <= 1
            report "two direct requests on one edge"
            severity failure;
         -- RA_LAUNCH_EARLY: no read-ahead is asked for while another waits
         -- to be issued, so a launch beside an ask is the ask's own, and
         -- leaving pending clear for it drops nothing.
         assert not (RA_LAUNCH_EARLY and reset_93 = '0' and
                     datacache_ra_request = '1' and datacache_ra_pending = '1')
            report "a read-ahead asked for while another waited to be issued"
            severity failure;
         -- RA_CHAIN: a chained launch is never beside an ask or one waiting
         -- to be issued, so the line it takes is the only one asked for.
         assert not (reset_93 = '0' and fast_chain_term = '1' and
                     (datacache_ra_request = '1' or datacache_ra_pending = '1'))
            report "a chained read-ahead beside an ask"
            severity failure;
         -- RA_CHAIN: the armed line after is SDRAM RAM, as it was tested on
         -- arming; fast_ra_go does not test it again.
         assert not (fast_chain_term = '1' and
                     is_sdram_line(datacache_ra_chain_addr(31 downto 5) & "00000") = '0')
            report "a chained read-ahead of a line the direct port cannot read"
            severity failure;
         -- RA_CTL_RETURN: a qword on fast_ra_valid is the direct read-ahead
         -- outstanding's, never a bridge read-ahead's beside it; its fourth
         -- is the only completion on its edge.
         assert not (fast_ra_valid = '1' and
                     (not (FAST_ON and DCRA_ON and RA_CTL_RETURN) or
                      fast_is_ra_r = '0' or fast_out = 0))
            report "a read-ahead qword came back with no direct read-ahead outstanding"
            severity failure;
         assert not (fast_ra_take = '1' and resp_take = '1' and resp_fifo_dout(105) = '1')
            report "a direct read-ahead qword came back beside a bridge read-ahead's completion"
            severity failure;
         assert not (fast_ra_ret = '1' and
                     (fast_done_tog /= fast_done_seen or fast_unc_ret = '1'))
            report "a direct read-ahead line came back beside another completion"
            severity failure;
         -- A bridge read-ahead's completion beside it touches neither.
         assert not (fast_done_tog /= fast_done_seen and fast_is_unc_r = '1' and
                     (fast_ra_ret = '1' or
                      response_cdc_pending_93 = '1' or response_cdc_deliver_93 = '1' or
                      (resp_fifo_empty = '0' and resp_fifo_dout(105) = '0')))
            report "a direct uncached load completed beside another completion"
            severity failure;
         assert not (fast_unc_ret = '1' and
                     (fast_done_tog /= fast_done_seen or fast_ra_ret = '1' or fast_out /= 1 or
                      response_cdc_pending_93 = '1' or response_cdc_deliver_93 = '1' or
                      (resp_fifo_empty = '0' and resp_fifo_dout(105) = '0')))
            report "a direct uncached qword came back beside another completion"
            severity failure;
         -- A load launched from stage 3 is the one stage 4 presents next.
         assert not (fast_s3_launched = '1' and reset_93 = '0' and
                     not (stall4Masked = 0 and executeNew = '1' and
                          mem4_request = '1' and mem4_rnw = '1' and
                          mem4_address(31 downto 3) = fast_line_r(31 downto 3)))
            report "a load launched from stage 3 was not presented on the next edge"
            severity failure;
         -- Every direct read in flight when a reset came has finished, and
         -- been counted, by its end.
         assert not (reset_d = '1' and reset_93 = '0' and fast_out /= 0)
            report "a direct read was still outstanding when the reset ended"
            severity failure;
         reset_d := reset_93;
      end if;
   end process;
-- synthesis translate_on
   datacache_request <= datacache_request_raw and not fast_go and not fast_go_q;
   fast_req_tog    <= fast_tog_r;
   fast_req_line   <= std_logic_vector(fast_line_r);
   fast_req_stream <= fast_stream_r;

   -- The data cache takes a direct demand fill through its usual fill port,
   -- the window open from the request until the fourth beat. A direct
   -- read-ahead's window is not the cache's: its beats go to line_fill_1x;
   -- nor an uncached load's, whose one beat is fast_unc_q_1x.
   fast_window_dc <= fast_window and not fast_is_ra_r and not fast_is_unc_r;
   dc_active <= datacache_active or fast_window_dc;
   dc_grant  <= fast_first when (fast_window_dc = '1') else rdram_granted2X;
   dc_dout   <= fast_qword when (fast_window_dc = '1') else ddr3_DOUT;
   dc_ready  <= fast_beat  when (fast_window_dc = '1') else ddr3_DOUT_READY;

   -- The instruction in stage 3 is a load, so the data cache's RAM read this
   -- cycle is its own; the store buffer drains only in a cycle when it is not.
   datacache_next_load <= decodeNew and decodeMemReadEnable;

-- synthesis translate_off
   -- executeStallFromMEM is a bubble's mark: set with stall3, cleared in the
   -- bubble cycle itself. Set with stage 3 running, a bubble was released
   -- before it happened - the instruction behind a load ran without its value.
   process (clk93)
   begin
      if (rising_edge(clk93)) then
         if (reset_93 = '0' and ce_93 = '1' and executeStallFromMEM = '1' and stall3 = '0') then
            report "cpu: a load's bubble was released before its own answer (executeStallFromMEM set, stall3 clear)"
               severity failure;
         end if;
      end if;
   end process;
-- synthesis translate_on

   -- LOAD_INTERLOCK: whether a load in stage 3 must stall the instruction
   -- behind it for a cycle - the load-delay bubble. That instruction is in
   -- stage 2 now (decSource1/2, the compares executeForwardValue1/2 register)
   -- and decodeTarget is the load's rt. An FPU load keeps its bubble, as
   -- does any load if stage 2 holds nothing and its bits happen to match:
   -- that costs only the cycle every load pays without LOAD_INTERLOCK.
   -- Without the bubble the data cache sees ce_fetch high in the load's IDLE
   -- cycle; see its "LOADS WITHOUT THE BUBBLE".
   load_use <= '1' when (not LOAD_INTERLOCK or decodeCOP1ReadEnable = '1' or
                         (decSource1 > 0 and decSource1 = decodeTarget) or
                         (decSource2 > 0 and decSource2 = decodeTarget and
                          dec_reads_rt = '1' and merge_bypass = '0')) else '0';

   -- LOAD_RT_EXACT: whether the instruction in stage 2 reads its rt field as
   -- a general register. These do not: REGIMM and J/JAL, where the field is
   -- a function or part of the target; the immediate ALU ops through LUI,
   -- DADDI and DADDIU, and the plain and linked loads, which write rt;
   -- CACHE, where it is the operation; and the FPU loads and stores, where
   -- it names an FPU register (an FPU load ahead keeps its bubble anyway,
   -- through decodeCOP1ReadEnable). Everything else keeps the compare: the
   -- stores, the branches, the SPECIAL ops, the coprocessor moves and the
   -- merging loads (whose own bypass is merge_bypass).
   dec_reads_rt <= '0' when (LOAD_RT_EXACT and
                             (opcodeCacheMuxed(31 downto 26) = "000001" or   -- REGIMM
                              opcodeCacheMuxed(31 downto 26) = "000010" or   -- J
                              opcodeCacheMuxed(31 downto 26) = "000011" or   -- JAL
                              opcodeCacheMuxed(31 downto 29) = "001"    or   -- ADDI .. LUI
                              opcodeCacheMuxed(31 downto 26) = "011000" or   -- DADDI
                              opcodeCacheMuxed(31 downto 26) = "011001" or   -- DADDIU
                              opcodeCacheMuxed(31 downto 26) = "100000" or   -- LB
                              opcodeCacheMuxed(31 downto 26) = "100001" or   -- LH
                              opcodeCacheMuxed(31 downto 26) = "100011" or   -- LW
                              opcodeCacheMuxed(31 downto 26) = "100100" or   -- LBU
                              opcodeCacheMuxed(31 downto 26) = "100101" or   -- LHU
                              opcodeCacheMuxed(31 downto 26) = "100111" or   -- LWU
                              opcodeCacheMuxed(31 downto 26) = "101111" or   -- CACHE
                              opcodeCacheMuxed(31 downto 26) = "110000" or   -- LL
                              opcodeCacheMuxed(31 downto 26) = "110001" or   -- LWC1
                              opcodeCacheMuxed(31 downto 26) = "110100" or   -- LLD
                              opcodeCacheMuxed(31 downto 26) = "110101" or   -- LDC1
                              opcodeCacheMuxed(31 downto 26) = "110111" or   -- LD
                              opcodeCacheMuxed(31 downto 26) = "111001" or   -- SWC1
                              opcodeCacheMuxed(31 downto 26) = "111101"))    -- SDC1
                   else '1';

   -- LOAD_MERGE_BYPASS. The R4600 manual, describing each of LWL, LWR, LDL and
   -- LDR: "The contents of general register rt are internally bypassed within
   -- the processor so that no NOP is needed between an immediately preceding
   -- load instruction which specifies register rt and a following LDL (or
   -- LDR) instruction which also specifies register rt." The merge needs the
   -- old rt only in the data stage, when the load ahead has just produced it,
   -- so the pair issues back to back - the unaligned ldl/ldr doubleword that
   -- makes up most of KI2's renderer's load bubbles.
   --
   -- Here the follower skips the bubble and so reads rt in stage 3 before the
   -- load's value exists. It does not use that: in stage 4 the load is one
   -- stage ahead, its merged result in writebackData, and nothing else can
   -- have passed between them - so the follower merges into writebackData
   -- instead (read4_oldData), and keeps it for a merge after a miss
   -- (writebackReadLastData). A base register equal to the loaded one is a
   -- real dependency, and keeps the bubble; so does an FPU load ahead.
   merge_bypass <= '1' when (LOAD_INTERLOCK and LOAD_MERGE_BYPASS and
                             decodeNew = '1' and decodeMemReadEnable = '1' and
                             decodeCOP1ReadEnable = '0' and EXEExceptionMem = '0' and
                             decodeTarget /= 0 and
                             (opcodeCacheMuxed(31 downto 26) = "100010" or   -- LWL
                              opcodeCacheMuxed(31 downto 26) = "100110" or   -- LWR
                              opcodeCacheMuxed(31 downto 26) = "011010" or   -- LDL
                              opcodeCacheMuxed(31 downto 26) = "011011") and -- LDR
                             decSource2 = decodeTarget and
                             decSource1 /= decodeTarget) else '0';
   
   process (all)
      variable skipmem : std_logic;
   begin
   
      stallNew4            <= stall4;
      perf_uc_narrow       <= '0';

      mem4_request         <= '0';
      mem4_req64           <= executeMem64Bit;
      mem4_address         <= executeMemAddress;
      mem4_rnw             <= '1';
      mem4_dataWrite       <= std_logic_vector(executeMemWriteData);
      mem4_writeMask       <= executeMemWriteMask;
      
      datacache_writeena   <= '0';
      datacache_readena    <= '0';
      
      datacache_addr   <= executeMemAddress;
      if (executeMemReadEnable = '1') then
         if (executeLoadType = LOADTYPE_LEFT or executeLoadType = LOADTYPE_RIGHT) then 
            datacache_addr(1 downto 0) <= "00";
         end if;
         if (executeLoadType = LOADTYPE_LEFT64 or executeLoadType = LOADTYPE_RIGHT64) then 
            datacache_addr(2 downto 0) <= "000";
         end if;
      end if;
      
      -- ############
      -- Load/Store
      -- ############
      
      if (stall4Masked = 0 and executeNew = '1') then
      
         if (executeMemWriteEnable = '1') then
            skipmem := '0';
         
            if (executeMemUseCache = '1') then
               datacache_writeena <= '1';
               skipmem            := '1';
               if (DATACACHEWRITETHROUGH = '1') then
                  mem4_request <= '1';
                  if (writefifo_mem4_ready = '0') then
                     stallNew4 <= '1';
                  end if;
               end if;
               if (datacache_writedone = '0') then
                  stallNew4      <= '1';
               end if;
            end if;
            
            if (skipmem = '0') then
               mem4_request   <= '1';
               if (writefifo_mem4_ready = '0') then
                  stallNew4      <= '1';
               end if;
               -- NS, perf only: an uncached store to SDRAM that leaves bytes
               -- of the words it covers unwritten. Counted where the FIFO
               -- takes it, so a store re-offered while blocked counts once.
               -- The region is stage 3's, which is this access's own.
               if (writefifo_mem4_ready = '1' and perf_exec_region = "00" and
                   ((executeMem64Bit = '1' and executeMemWriteMask /= x"FF") or
                    (executeMem64Bit = '0' and
                     executeMemWriteMask(3 downto 0) /= "1111"))) then
                  perf_uc_narrow <= '1';
               end if;
            end if;

            mem4_rnw       <= '0';
            if (executeMem64Bit = '1') then
               mem4_address(2 downto 0) <= "000";
            else
               mem4_address(1 downto 0) <= "00";
            end if;
         
         end if;
         
         if (executeMemReadEnable = '1') then
            skipmem := '0';
            
            if (executeMemUseCache = '1') then
               datacache_readena  <= '1';
               skipmem            := '1';
               if (datacache_readdone = '0') then
                  stallNew4      <= '1';
               end if;
            end if;

            if (skipmem = '0') then
               mem4_request   <= '1';
               stallNew4      <= '1';
            end if;

            if (executeLoadType = LOADTYPE_LEFT or executeLoadType = LOADTYPE_RIGHT) then
               mem4_address(1 downto 0) <= "00";
            end if;
            if (executeLoadType = LOADTYPE_LEFT64 or executeLoadType = LOADTYPE_RIGHT64) then 
               mem4_address(2 downto 0) <= "000";
            end if;
         
         end if;
         
      end if;

      if (read_fifoStall = '1' and writefifo_mem4_ready = '1') then
         mem4_request <= '1';
         mem4_rnw     <= '1';
         -- Same latching as the store replay below, for the same reason: it
         -- is the identical construct - re-offering from executeMemAddress
         -- after stage 3 has moved on - so it would read from whatever address
         -- happened to be in the register rather than the one that was
         -- blocked.
         mem4_address <= read_fifoStall_address;
         mem4_req64   <= read_fifoStall_req64;
      end if;

      -- A blocked store was not accepted into the FIFO. Replay it once the
      -- arbiter is ready, then let the clocked stage retire it on that edge.
      if (writeback_fifoStall = '1' and writefifo_mem4_ready = '1') then
         mem4_request   <= '1';
         mem4_rnw       <= '0';
         -- From the LATCHED copy. Replaying from executeMem* would re-offer
         -- the store with whatever stage 3 had advanced to, which in the
         -- game's ATA loop is the next iteration's LOAD: the ATA write would
         -- be lost and a stray halfword written into main RAM.
         mem4_address   <= fifoStall_address;
         mem4_dataWrite <= fifoStall_dataWrite;
         mem4_writeMask <= fifoStall_writeMask;
         mem4_req64     <= fifoStall_req64;
         if (fifoStall_useCache = '1') then
            datacache_writeena <= '1';
         end if;
      end if;
      
   end process;
   
   read4_uncachedRot <=
      "00"                   when (read4_useLoadType = LOADTYPE_LEFT    or
                                   read4_useLoadType = LOADTYPE_RIGHT   or
                                   read4_useLoadType = LOADTYPE_LEFT64  or
                                   read4_useLoadType = LOADTYPE_RIGHT64 or
                                   read4_useLoadType = LOADTYPE_QWORD)  else
      read4_Addr(1 downto 0);

   -- The response mailbox registers the raw bus word before completion is
   -- asserted. Rotate that stable CPU-domain copy; a second mailbox stage
   -- registers the rotated value before the completion pulse reaches users.

   read4_uncachedData <=
      unsigned(mem_finished_dataRead(63 downto 32)) &
      (x"000000" & unsigned(mem_finished_dataRead(31 downto 24)))
                                     when (read4_uncachedRot = "11") else
      unsigned(mem_finished_dataRead(63 downto 32)) &
      (x"0000" & unsigned(mem_finished_dataRead(31 downto 16)))
                                     when (read4_uncachedRot = "10") else
      unsigned(mem_finished_dataRead(63 downto 32)) &
      (x"00" & unsigned(mem_finished_dataRead(31 downto 8)))
                                     when (read4_uncachedRot = "01") else
      unsigned(mem_finished_dataRead);

   read4_dataReadData   <= unsigned(datacache_data_out) when (writeback_UseCache = '1' or datacache_readena = '1') else unsigned(mem_finished_dataRot);
   read4_dataReadRot64  <= bus_to_cpu64(std_logic_vector(read4_dataReadData));
   read4_dataReadRot32  <= bus_to_cpu32(std_logic_vector(read4_dataReadData(31 downto 0)));
   
   read4_Addr         <= writebackReadAddress         when (stall4 = '1') else executeMemAddress;
   read4_oldData      <= writebackReadLastData        when (stall4 = '1') else
                         writebackData                when (executeMergeFwd = '1') else
                         executeMemReadLastData;
   read4_cop1_readEna <= writeback_COP1_ReadEnable    when (stall4 = '1') else executeCOP1ReadEnable;
   read4_cop1_target  <= cop1_stage4_target           when (stall4 = '1') else executeCOP1Target;
   read4_useLoadType  <= writebackLoadType            when (stall4 = '1') else executeLoadType;       
   read4_useTarget    <= writebackTarget              when (stall4 = '1') else resultTarget;
   
   process (clk93)
   begin
      if (rising_edge(clk93)) then
      
         DATACACHEON_intern    <= DATACACHEON;
         DATACACHETLBON_intern <= DATACACHETLBON;
      
         if (reset_93 = '1') then
         
            stall4                           <= '0';
            read_fifoStall                   <= '0';
            writebackNew                     <= '0';
            writebackStallFromMEM            <= '0';                  
            writebackWriteEnable             <= '0';
            writebackMemWrite                <= '0';
            perf_st4_read                    <= '0';
            writeback_fifoStall              <= '0';
            cop1_stage4_writeEnable          <= '0';
            COP2Latch                        <= (others => '0');
            
         elsif (ce_93 = '1') then
         
            stall4                  <= stallNew4;    
            
            cop1_stage4_writeEnable <= '0';

            if (stall4Masked = 0) then
            
               writebackNew   <= '0';
               perf_wb_ld     <= perf_ex_ld;  -- perf-only: the slot's tag moves with it
               
               writebackForwardValue1 <= '0';
               writebackForwardValue2 <= '0';
            
               if (executeNew = '1') then
               
                  writebackStallFromMEM        <= executeStallFromMEM;
               
-- synthesis translate_off
                  pcOld3                       <= pcOld2;
                  opcode3                      <= opcode2;
                  hi_1                         <= hi;
                  lo_1                         <= lo;
-- synthesis translate_on
               
                  writebackTarget              <= resultTarget;
                  writebackData                <= resultData;
                  -- A merge behind a load keeps the load's result for a merge
                  -- after a miss: writebackData is still that load's here.
                  if (executeMergeFwd = '1') then
                     writebackReadLastData     <= writebackData;
                  else
                     writebackReadLastData     <= executeMemReadLastData;
                  end if;

                  writebackWriteEnable         <= resultWriteEnable;
                  writeback_UseCache           <= datacache_readena or datacache_writeena or executeDCacheEnable;
                  writebackMemWrite            <= executeMemWriteEnable;
                  -- Perf-only, for the uncached split in debug_perf_events.
                  perf_st4_read                <= executeMemReadEnable;
                  perf_st4_region              <= perf_exec_region;

                  writeback_COP1_ReadEnable    <= executeCOP1ReadEnable;
                  cop1_stage4_target           <= executeCOP1Target;
                  
                  writeback_fifoStall          <= '0';
                  
                  -- check if last command must be forwarded
                  if (resultWriteEnable = '1') then
                     if (decSource1 > 0 and resultTarget = decSource1) then writebackForwardValue1 <= '1'; end if;
                     if (decSource2 > 0 and resultTarget = decSource2) then writebackForwardValue2 <= '1'; end if;
                  end if;
                  
                  -- A load that took its bubble: the instruction behind it
                  -- waited in stage 3 and reads it now.
                  if (executeMemReadEnable = '1' and executeCOP1ReadEnable = '0' and
                      (not LOAD_INTERLOCK or executeStallFromMEM = '1')) then
                     if (decodeSource1 > 0 and resultTarget = decodeSource1) then writebackForwardValue1 <= '1'; end if;
                     if (decodeSource2 > 0 and resultTarget = decodeSource2) then writebackForwardValue2 <= '1'; end if;
                  end if;
                  -- One that did not: the instruction behind it did not read
                  -- it and goes on to stage 4 with it; the one after comes up
                  -- from stage 2 now, as behind any other result.
                  if (LOAD_INTERLOCK and executeMemReadEnable = '1' and
                      executeCOP1ReadEnable = '0' and executeStallFromMEM = '0') then
                     if (decSource1 > 0 and resultTarget = decSource1) then writebackForwardValue1 <= '1'; end if;
                     if (decSource2 > 0 and resultTarget = decSource2) then writebackForwardValue2 <= '1'; end if;
                  end if;
                  
                  if (executeMemReadEnable = '1' and
                      executeMemUseCache = '0' and
                      mem4_request = '1' and
                      writefifo_mem4_ready = '0' and fast_s3_launched = '0') then
                     read_fifoStall         <= '1';
                     read_fifoStall_address <= mem4_address;
                     read_fifoStall_req64   <= mem4_req64;
                  end if;

                  if (executeMemWriteEnable = '1') then


                     if (mem4_request = '1' and writefifo_mem4_ready = '0') then
                        writeback_fifoStall <= '1';
                        -- mem4_* here are this store's own combinational
                        -- values, already address-masked by the issue path.
                        fifoStall_address   <= mem4_address;
                        fifoStall_dataWrite <= mem4_dataWrite;
                        fifoStall_writeMask <= mem4_writeMask;
                        fifoStall_req64     <= mem4_req64;
                        fifoStall_useCache  <= executeMemUseCache;
                     else
                        writebackNew        <= '1';
                     end if;
                  
                  elsif (executeMemReadEnable = '1') then
                  
                     writebackLoadType       <= executeLoadType;
                     writebackReadAddress    <= executeMemAddress;

                  else

                     writebackNew         <= '1';
                     
                  end if;
                  
                  if (executeCOP0ReadEnable = '1') then
                     if (resultTarget > 0) then
                        writebackWriteEnable <= '1';
                     end if;
                     
                     if (executeCOP64 = '1') then
                        writebackData <= COP0ReadValue;
                     else
                        writebackData <= unsigned(resize(signed(COP0ReadValue(31 downto 0)), 64));
                     end if;
                  end if;
                  
                  if (executeCOP2ReadEnable = '1') then
                     if (resultTarget > 0) then
                        writebackWriteEnable <= '1';
                     end if;
                     
                     if (executeCOP64 = '1') then
                        writebackData <= COP2Latch;
                     else
                        writebackData <= unsigned(resize(signed(COP2Latch(31 downto 0)), 64));
                     end if;
                  end if;
                  
                  if (executeCOP2WriteEnable = '1') then
                     COP2Latch <= executeMemReadLastData;
                  end if;

                  if (datacache_CmdStall = '1') then
                     stall4 <= '1';
                  end if;
                  
                  if (execute_TLBP = '1') then
                     stall4 <= '1';
                  end if;

               end if;
               
            end if; -- stall4Masked
            
            if (writeback_fifoStall = '1' and
                not (writefifo_mem4_ready = '1' and mem4_request = '1') and
                (datacache_CmdDone = '1' or TLBDone = '1' or
                 datacache_writedone = '1' or datacache_readdone = '1' or
                 (writeback_UseCache = '0' and mem_finished_read = '1') or
                 (writebackMemWrite = '1' and writeback_UseCache = '1' and
                  DATACACHEWRITETHROUGH = '1' and
                  datacache_debug_state = "00000"))) then
            end if;

            if (datacache_CmdDone = '1') then
               stall4        <= '0';
               writebackNew  <= '1';
            end if;
            
            if (TLBDone = '1') then
               stall4        <= '0';
               writebackNew  <= '1';
            end if;
            
            -- The replayed load has been taken by the FIFO. Drop the retry
            -- flag but leave stall4 alone: the load is now genuinely in
            -- flight and mem_finished_read releases it.
            if (read_fifoStall = '1' and writefifo_mem4_ready = '1') then
               read_fifoStall <= '0';
            end if;

            if (writeback_fifoStall = '1' and
                writefifo_mem4_ready = '1' and mem4_request = '1') then
               stall4              <= '0';
               writebackNew        <= '1';
               writeback_fifoStall <= '0';
            end if;
            
            if (datacache_writedone = '1') then
               stall4        <= '0';
               writebackNew  <= '1';
            end if;

            -- A write-through cache store can be accepted by the CPU FIFO
            -- before the cache's one-cycle write_done indication is sampled.
            -- Once that accepted store's cache side is idle, release the
            -- retained stage-4 entry rather than waiting forever for the
            -- already-missed pulse.
            if (stall4 = '1' and writebackMemWrite = '1' and
                writeback_UseCache = '1' and DATACACHEWRITETHROUGH = '1' and
                writeback_fifoStall = '0' and datacache_debug_state = "00000") then
               stall4       <= '0';
               writebackNew <= '1';
            end if;
            
            if ((writeback_UseCache = '0' and mem_finished_read = '1') or datacache_readdone = '1') then
            
               stall4             <= '0';
               writebackNew       <= '1';
               
               if (read4_cop1_readEna = '1') then
                  cop1_stage4_writeEnable <= '1';
                  if (fpuRegMode = '0') then
                     cop1_stage4_target(0) <= '0';
                  end if;
               end if;
               
               if (read4_useTarget > 0 and read4_cop1_readEna = '0') then
                  writebackWriteEnable <= '1';
               end if;
               
            end if; -- mem_finished_read
            
            if ((writeback_UseCache = '0' and mem_finished_read = '1') or datacache_readena = '1' or datacache_readbusy = '1') then
               
               cop1_stage4_data <= bus_to_cpu64(std_logic_vector(read4_dataReadData));
               
               cop1_stage4_writeMask   <= "11";
               if (fpuRegMode = '1') then
                  if (read4_useLoadType = LOADTYPE_DWORD) then
                     cop1_stage4_data(31 downto 0) <= bus_to_cpu32(std_logic_vector(read4_dataReadData(31 downto 0)));
                     cop1_stage4_writeMask         <= "01";
                  end if;
               else
                  if (read4_useLoadType = LOADTYPE_DWORD) then
                     if (read4_cop1_target(0) = '1') then
                        cop1_stage4_data(63 downto 32) <= bus_to_cpu32(std_logic_vector(read4_dataReadData(31 downto 0)));
                        cop1_stage4_writeMask          <= "10";
                     else
                        cop1_stage4_data(31 downto 0) <= bus_to_cpu32(std_logic_vector(read4_dataReadData(31 downto 0)));
                        cop1_stage4_writeMask         <= "01";
                     end if;
                  end if;
               end if;
               
               case (read4_useLoadType) is
                  
                  when LOADTYPE_SBYTE => writebackData <= unsigned(resize(signed(read4_dataReadData(7 downto 0)), 64));
                  when LOADTYPE_SWORD => writebackData <= unsigned(resize(signed(bus_to_cpu16(std_logic_vector(read4_dataReadData(15 downto 0)))), 64));
                   when LOADTYPE_LEFT =>
                      writebackData <= unsigned(resize(signed(merge_left32(read4_dataReadRot32,
                                                                          read4_oldData(31 downto 0),
                                                                          read4_Addr(1 downto 0))), 64));
                        
                  when LOADTYPE_DWORD  => writebackData <= unsigned(resize(signed(bus_to_cpu32(std_logic_vector(read4_dataReadData(31 downto 0)))), 64));
                  when LOADTYPE_DWORDU => writebackData <= x"00000000" & bus_to_cpu32(std_logic_vector(read4_dataReadData(31 downto 0)));
                  when LOADTYPE_BYTE  => writebackData <= x"00000000" & x"000000" & read4_dataReadData(7 downto 0);
                  when LOADTYPE_WORD  => writebackData <= x"00000000" & x"0000" & bus_to_cpu16(std_logic_vector(read4_dataReadData(15 downto 0)));
                   when LOADTYPE_RIGHT =>
                      writebackData <= unsigned(resize(signed(merge_right32(read4_dataReadRot32,
                                                                           read4_oldData(31 downto 0),
                                                                           read4_Addr(1 downto 0))), 64));
                     
                  when LOADTYPE_QWORD => writebackData <= bus_to_cpu64(std_logic_vector(read4_dataReadData));
                  
                   when LOADTYPE_LEFT64 =>
                      writebackData <= merge_left64(read4_dataReadRot64, read4_oldData,
                                                    read4_Addr(2 downto 0));
                  
                   when LOADTYPE_RIGHT64 =>
                      writebackData <= merge_right64(read4_dataReadRot64, read4_oldData,
                                                     read4_Addr(2 downto 0));
                     
               end case; 
               
            end if; -- mem_read

         end if; -- ce
         

      end if;
   end process;
   
   
--##############################################################
--############################### stage 5
--##############################################################
   process (clk93)
      variable store_byte     : std_logic_vector(7 downto 0);
      variable write_data_slv : std_logic_vector(63 downto 0);
      variable store_word     : std_logic_vector(31 downto 0);
   begin
      if (rising_edge(clk93)) then
      
-- synthesis translate_off
         cpu_done <= '0';
-- synthesis translate_on
         
         --debugTmr <= debugTmr + 1;

         if (reset_93 = '1') then
            debug_retired_count <= (others => '0');
            debug_retire_pc_register <= (others => '0');
            debug_retire_opcode_register <= (others => '0');
            
            --debugCnt             <= (others => '0');
            --debugSum             <= (others => '0');
            --debugTmr             <= (others => '0');
         
         elsif (ce_93 = '1') then

            if (stall4Masked = 0 and writebackNew = '1') then
               debug_retired_count <= debug_retired_count + 1;
            
-- synthesis translate_off
               debug_retire_pc_register <= std_logic_vector(PCold3(31 downto 0));
               debug_retire_opcode_register <= std_logic_vector(opcode3);
               pcOld4               <= pcOld3;
               opcode4              <= opcode3;
               hi_2                 <= hi_1;
               lo_2                 <= lo_1;
-- synthesis translate_on
               
               -- export
               if (writebackWriteEnable = '1') then 
                  if (writebackTarget > 0) then
-- synthesis translate_off
                     regs(to_integer(writebackTarget)) <= writebackData;
-- synthesis translate_on
                     --debugSum <= debugSum + writebackData(31 downto 0);
                  end if;
               end if;
               --debugCnt          <= debugCnt + 1;
-- synthesis translate_off

               cpu_done          <= '1';
               cpu_export.pc     <= pcOld4;
               cpu_export.opcode <= opcode4;
               cpu_export.hi     <= hi_2;
               cpu_export.lo     <= lo_2;
               for i in 0 to 31 loop
                  cpu_export.regs(i)    <= regs(i);
                  cpu_export.FPUregs(i) <= FPUregs(i);
               end loop;
               cop0_export_1       <= cop0_export;
               cpu_export.cop0regs <= cop0_export_1;
               
               csr_export_1        <= csr_export;
               csr_export_2        <= csr_export_1;
               cpu_export.csr      <= 7x"0" & csr_export_2;
               
-- synthesis translate_on
               --debugwrite <= '0';
               --if (debugCnt(31) = '1' and debugSum(31) = '1' and debugTmr(31) = '1' and writebackTarget = 0) then
               --   debugwrite <= '1';
               --end if;
               
            end if;
             
         end if;
         
         -- export
-- synthesis translate_off
         if (ss_regs_load = '1') then
            regs(to_integer(ss_regs_addr)) <= unsigned(ss_regs_data);
         end if;          
         if (ss_FPUregs_load = '1') then
            FPUregs(to_integer(ss_FPUregs_addr)) <= unsigned(ss_FPUregs_data);
         end if; 
         
         if (FPUregs_wren_a(0) = '1') then
            FPUregs(to_integer(unsigned(FPUregs_address_a)))(31 downto 0) <= unsigned(FPUregs_data_a(31 downto 0));
         end if;        
         
         if (FPUregs_wren_a(1) = '1') then
            FPUregs(to_integer(unsigned(FPUregs_address_a)))(63 downto 32) <= unsigned(FPUregs_data_a(63 downto 32));
         end if;
-- synthesis translate_on
         
      end if;
   end process;

--##############################################################
--############################### submodules
--##############################################################
   
   
   icop0 : entity work.cpu_cop0
   generic map
   (
      LITTLE_ENDIAN => LITTLE_ENDIAN,
      ADDR32_ONLY   => ADDR32_ONLY
   )
   port map
   (
      clk93                   => clk93,
      ce                      => ce_93,   
      stall                   => stall,
      stall4Masked            => stall4Masked,
      executeNew              => executeNew,
      reset                   => reset_93,
      preNMI                  => preNMI,
      cpuPaused               => cpuPaused,
      
      RANDOMMISS              => RANDOMMISS,
      DISABLE_BOOTCOUNT       => DISABLE_BOOTCOUNT,
      DISABLE_DTLBMINI        => DISABLE_DTLBMINI, 
      ALECK64                 => ALECK64,
            
      error_exception         => error_exception,
      error_TLB               => error_TLB,
      
      irqRequest              => irqRequest,
      irqTrigger              => irqTrigger,
      decode_irq              => decode_irq,

-- synthesis translate_off
      cop0_export             => cop0_export,
-- synthesis translate_on

      eret                    => execute_ERET,
      exception3              => exceptionNew3,
      exceptionNewPC          => exceptionNewPC,
      exceptionPCStore        => value1,
      exceptionFPU            => exceptionFPU,
      exceptionCode_1         => "0000", -- todo
      exceptionCode_3         => exceptionCode_3,
      exception_COP           => exception_COP,
      isDelaySlot             => executeBranchdelaySlot,
      chainedDelaySlot        => chainedDelaySlot,
      nextDelaySlot           => EXECOPBranchDelaySlot,
      pcOld1                  => PCold1,
            
      eretPC                  => eretPC,
      exceptionPC             => exceptionPC,
      debug_cause             => cop0_debug_cause,
      debug_epc               => cop0_debug_epc,
      exception               => exception,   
      exceptionStage1         => exceptionStage1,   
            
      COP0_enable             => COP0_enable,
      COP1_enable             => COP1_enable,
      COP2_enable             => COP2_enable,
      fpuRegMode              => fpuRegMode,
      privilegeMode           => privilegeMode,
      kusegUnmapped           => kusegUnmapped,
      bit64region             => bit64region,
      
      writeEnable             => executeCOP0WriteEnable,
      regIndex                => executeCOP0Register,
      writeValue              => executeCOP0WriteValue,
      readValue               => COP0ReadValue,
      
      executeSetLL            => executeSetLL,
      executeLLfromTLB        => executeLLfromTLB,
      executeLLAddr           => executeMemAddress,
      
      TagLo_Valid             => TagLo_Valid,
      TagLo_Dirty             => TagLo_Dirty,
      TagLo_Addr              => TagLo_Addr, 
      
      writeDatacacheTagEna    => writeDatacacheTagEna,      
      writeDatacacheTagValue  => writeDatacacheTagValue,
            
      TLBR                    => execute_TLBR,  
      TLBWI                   => execute_TLBWI, 
      TLBWR                   => execute_TLBWR, 
      TLBP                    => execute_TLBP,  
      TLBDone                 => TLBDone,
            
      TLB_instrReq            => TLB_instrReq,
      TLB_ss_load             => TLB_ss_load,
      TLB_instrAddrIn         => FetchAddr,
      TLB_instrUseCache       => TLB_instrUseCache,
      TLB_instrStall          => TLB_instrStall,
      TLB_instrUnStall        => TLB_instrUnStall,
      TLB_instrAddrOutFound   => TLB_instrAddrOutFound,
      TLB_instrAddrOutLookup  => TLB_instrAddrOutLookup,
      
      TLB_dataReq             => EXETLBDataAccess,   
      TLB_dataIsWrite         => decodeMemWriteEnable or decodeMemWriteLL,   
      TLB_dataAddrIn          => calcMemAddr,
      TLB_dataUseCacheFound   => TLB_dataUseCacheFound,
      TLB_dataUseCacheLookup  => TLB_dataUseCacheLookup,
      TLB_dataStall           => TLB_dataStall,
      TLB_dataUnStall         => TLB_dataUnStall,
      TLB_dataAddrOutFound    => TLB_dataAddrOutFound,
      TLB_dataAddrOutLookup   => TLB_dataAddrOutLookup,
            
      SS_reset                => SS_reset,    
      loading_savestate       => loading_savestate,    
      SS_DataWrite            => SS_DataWrite,
      SS_Adr                  => SS_Adr,      
      SS_wren_CPU             => SS_wren_CPU, 
      SS_rden_CPU             => SS_rden_CPU 
   );
   
   icpu_mul : entity work.cpu_mul
   port map
   (
      clk       => clk93,
      sign      => mulsign,
      value1_in => mul1,
      value2_in => mul2,
      result    => mulResult
   );
   
   idivider : entity work.divider
   port map
   (
      clk       => clk93,      
      start     => DIVstart,
      is32      => DIVis32,
      done      => open,      
      busy      => open,
      dividend  => DIVdividend, 
      divisor   => DIVdivisor,  
      quotient  => DIVquotient, 
      remainder => DIVremainder
   );
   
   icpu_FPU : entity work.cpu_FPU
   generic map
   (
      ADD_FAST_NORM     => FPU_ADD_FAST,
      RESULT_FORWARD    => FPU_FORWARD,
      CVT_L_NARROW      => FPU_CVT_L_NARROW
   )
   port map
   (
      clk93             => clk93,         
      reset             => reset_93, 
      error_FPU         => error_FPU,
      
      -- synthesis translate_off
      csr_export        => csr_export,
      -- synthesis translate_on
      
      fpuRegMode        => fpuRegMode,      
                                         
      command_ena       => FPU_command_ena,
      command_code      => opcode1,  
      command_op1       => decodeFPUValue1,  
      command_op2       => decodeFPUValue2,   
      command_done      => FPU_command_done,
      
      transfer_ena      => FPU_TransferEna,
      transfer_code     => decodeSource1(3 downto 0),
      transfer_RD       => decodeRD,
      transfer_value    => value2,
      transfer_data     => FPU_TransferData,
      
      mul_result        => unsigned(mulResult),
      
      exceptionFPU      => exceptionFPU,
      FPU_CF            => FPU_CF,
                                      
      FPUWriteTarget    => FPUWriteTarget,
      FPUWriteData      => FPUWriteData,  
      FPUWriteEnable    => FPUWriteEnable,
      FPUWriteMask      => FPUWriteMask,

      result_fwd        => FPU_fwd_data,
      result_fwd_valid  => FPU_fwd_valid,

      SS_FPU_CF         => ss_in(24)(32),
      SS_CSR            => unsigned(ss_in(24)(24 downto 0))
   );
   
--##############################################################
--############################### savestates
--##############################################################

   SS_idle <= '1';

   process (clk93)
   begin
      if (rising_edge(clk93)) then
      
         ss_regs_load    <= '0';
         ss_FPUregs_load <= '0';
      
         if (SS_reset = '1') then
         
            for i in 0 to 31 loop
               ss_in(i) <= (others => '0');
            end loop;
            
            ss_in(0)  <= x"FFFFFFFFBFC00000"; -- PC
            
            ss_regs_loading <= '1';
            ss_regs_addr    <= (others => '0');
            ss_regs_data    <= (others => '0');
            ss_FPUregs_addr <= (others => '0');
            ss_FPUregs_data <= (others => '0');
            
         elsif (SS_wren_CPU = '1' and SS_Adr < 32) then
            ss_in(to_integer(SS_Adr)) <= SS_DataWrite;
         elsif (SS_wren_CPU = '1' and SS_Adr >= 32 and SS_Adr < 64) then
            ss_regs_load <= '1';
            ss_regs_addr <= SS_Adr(4 downto 0);
            ss_regs_data <= SS_DataWrite;
         elsif (SS_wren_CPU = '1' and SS_Adr >= 96 and SS_Adr < 128) then
            ss_FPUregs_load <= '1';
            ss_FPUregs_addr <= SS_Adr(4 downto 0);
            ss_FPUregs_data <= SS_DataWrite;
         end if;
         
         if (ss_regs_loading = '1') then
            ss_regs_load    <= '1';
            ss_regs_addr    <= ss_regs_addr + 1;            
            ss_FPUregs_load <= '1';
            ss_FPUregs_addr <= ss_regs_addr + 1;
            if (ss_regs_addr = 31) then
               ss_regs_loading <= '0';
            end if;
         end if;
      
         --SS_idle <= '0';
         --if (hiloWait = 0 and blockIRQ = '0' and (irqRequest = '0' or cop0_SR(0) = '0') and mem_done = '0') then
         --   SS_idle <= '1';
         --end if;
      
         --regsSS_rden <= '0';
         --if (SS_rden_CPU = '1' and SS_Adr >= 32 and SS_Adr < 64) then
         --   regsSS_address_b <= std_logic_vector(SS_Adr(4 downto 0));
         --   regsSS_rden      <= '1';
         --end if;
         --
         --if (regsSS_rden = '1') then
         --   SS_DataRead_CPU <= regsSS_q_b;
         --elsif (SS_rden_CPU = '1' and SS_Adr < 31) then
         --   SS_DataRead_CPU <= ss_out(to_integer(SS_Adr));
         --end if;
      
      end if;
   end process;
   
   SS_DataRead_CPU <= (others => '0');
   
--##############################################################
--############################### debug
--##############################################################

   process (clk93)
   begin
      if (rising_edge(clk93)) then
      
         error_stall <= '0';
      
         if (reset_93 = '1') then
         
            debugStallcounter <= (others => '0');
            
-- synthesis translate_off
            stallcountNo      <= 0;
            stallcount1       <= 0;
            stallcount3       <= 0;
            stallcount4       <= 0;
            stallcountDMA     <= 0;
-- synthesis translate_on
      
         elsif (ce_93 = '1') then
         
            if (stall = 0) then
               debugStallcounter <= (others => '0');
            elsif (cpuPaused = '0' and debugStallcounter(12) = '0') then
               debugStallcounter <= debugStallcounter + 1;
            end if;

            if (stall /= 0 and debugStallcounter(12) = '1') then
               error_stall <= '1';
            end if;

            -- Capture the first cycle over the threshold while the pipeline
            -- is still stalled. Do not overwrite it on the recovery cycle.
            
-- synthesis translate_off
            
            if (stallcountNo = 0 and stallcount4 = 0 and stallcount3 = 0 and stallcount1 = 0 and stallcountDMA = 0) then
               stallcountNo <= 0;
            end if;
            
            -- performance counters
            if (stall = 0) then
               stallcountNo <= stallcountNo + 1;
            elsif (stall4 = '1') then
               stallcount4 <= stallcount4 + 1;
            elsif (stall3 = '1') then
               stallcount3 <= stallcount3 + 1;
            elsif (stall1 = '1') then
               stallcount1 <= stallcount1 + 1;
            end if;
            
         else
            
            stallcountDMA <= stallcountDMA + 1;
            
-- synthesis translate_on
            
         end if;
         
      end if;
   end process;
   
   

end architecture;





