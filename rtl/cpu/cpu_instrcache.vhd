library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;   

library mem;
use work.pFunctions.all;

entity cpu_instrcache is
   generic
   (
      LITTLE_ENDIAN : boolean := false
   );
   port 
   (
      clk1x             : in  std_logic;
      clk2x             : in  std_logic;
      -- One reset per domain, as in cpu_instrcache.vhd: the fill path below
      -- runs on clk1x and is released by the clk1x-synchronised reset.
      reset_1x          : in  std_logic;
      reset_2x          : in  std_logic;

      ram_request       : out std_logic := '0';
      ram_active        : in  std_logic := '0';
      ram_grant         : in  std_logic := '0';
      ram_done          : in  std_logic := '0';
      ddr3_DOUT         : in  std_logic_vector(63 downto 0);
      ddr3_DOUT_READY   : in  std_logic;
      
      -- The fetch candidates' indexes and compare addresses, as in
      -- cpu_instrcache.vhd. Bit 13 of an index is not used: a set is
      -- address(12 downto 5).
      read_select       : in  std_logic;
      read_index1       : in  unsigned(13 downto 2);
      read_index2       : in  unsigned(13 downto 2);
      read_addrCompare1 : in  unsigned(31 downto 0);
      read_addrCompare2 : in  unsigned(31 downto 0);
      read_hit          : out std_logic;
      read_data         : out std_logic_vector(31 downto 0) := (others => '0');
      
      fill_request      : in  std_logic;
      fill_addrData     : in  unsigned(31 downto 0);
      fill_addrTag      : in  unsigned(31 downto 0);
      fill_done         : out std_logic := '0';
      
      CacheCommandEna   : in  std_logic;
      CacheCommand      : in  unsigned(4 downto 0);
      CacheCommandAddr  : in  unsigned(31 downto 0);
      
      TagLo_Valid       : in  std_logic;
      TagLo_Addr        : in  unsigned(19 downto 0)
   );
end entity;

architecture arch of cpu_instrcache is

   -- tags: valid & address(31 downto 12), per way, read for each candidate
   type t_tag is array (0 to 1) of std_logic_vector(20 downto 0);
   signal tag_q1           : t_tag;
   signal tag_q2           : t_tag;
   signal tag_wren         : std_logic_vector(1 downto 0) := "00";
   signal tag_address_a    : std_logic_vector(7 downto 0) := (others => '0');
   signal tag_data_a       : std_logic_vector(20 downto 0) := (others => '0');
   signal tag_address_b1   : std_logic_vector(7 downto 0);
   signal tag_address_b2   : std_logic_vector(7 downto 0);

   -- way w hits for candidate 1 or 2
   signal hit1             : std_logic_vector(1 downto 0);
   signal hit2             : std_logic_vector(1 downto 0);
   signal read_hit1        : std_logic;
   signal read_hit2        : std_logic;

   -- the selected candidate's set, the way that hit, and its ways' valid bits
   signal sel_set          : unsigned(7 downto 0);
   signal sel_way          : std_logic;
   signal sel_valid        : std_logic_vector(1 downto 0);

   -- replacement
   type t_lru is array (0 to 255) of std_logic;
   signal lru              : t_lru := (others => '0');
   signal lru_eff          : std_logic;
   signal lru_upd          : std_logic := '0';
   signal lru_upd_set      : unsigned(7 downto 0) := (others => '0');
   signal lru_upd_way      : std_logic := '0';
   signal victim           : std_logic := '0';
   signal fill_way         : std_logic := '0';

   -- data
   signal fill_addrTag_sav : unsigned(12 downto 0) := (others => '0');
   signal fill_grant       : std_logic;
   signal fill_active_1x   : std_logic := '0';
   signal fill_line_1x     : unsigned(7 downto 0) := (others => '0');
   signal fill_beat_1x     : unsigned(1 downto 0) := (others => '0');
   signal cache_ram_addr_a : std_logic_vector(9 downto 0);
   signal cache_wr_a       : std_logic;
   signal cache_wr_way     : std_logic_vector(1 downto 0);

   signal cache_address_b  : std_logic_vector(10 downto 0);
   type t_word is array (0 to 1) of std_logic_vector(31 downto 0);
   signal cache_q_b        : t_word;
   signal rd_way           : std_logic := '0';
   signal rd_word          : std_logic_vector(31 downto 0);

   -- state machine
   type tState is
   (
      IDLE,
      CLEARCACHE,
      FILL
   );
   signal state : tstate := IDLE;
   
   signal fill_latched : std_logic := '0';

begin 

   fill_grant <= ram_grant and ram_active;

   ------------------ tags

   tag_address_b1 <= std_logic_vector(read_index1(12 downto 5));
   tag_address_b2 <= std_logic_vector(read_index2(12 downto 5));

   gway : for w in 0 to 1 generate
   begin

      itagram1 : entity mem.RamMLAB
      generic map
      (
         width      => 21,
         widthad    => 8
      )
      port map
      (
         inclock    => clk2x,
         wren       => tag_wren(w),
         data       => tag_data_a,
         wraddress  => tag_address_a,
         rdaddress  => tag_address_b1,
         q          => tag_q1(w)
      );

      itagram2 : entity mem.RamMLAB
      generic map
      (
         width      => 21,
         widthad    => 8
      )
      port map
      (
         inclock    => clk2x,
         wren       => tag_wren(w),
         data       => tag_data_a,
         wraddress  => tag_address_a,
         rdaddress  => tag_address_b2,
         q          => tag_q2(w)
      );

      hit1(w) <= '1' when (tag_q1(w)(20) = '1' and unsigned(tag_q1(w)(19 downto 0)) = read_addrCompare1(31 downto 12)) else '0';
      hit2(w) <= '1' when (tag_q2(w)(20) = '1' and unsigned(tag_q2(w)(19 downto 0)) = read_addrCompare2(31 downto 12)) else '0';

      sel_valid(w) <= tag_q2(w)(20) when (read_select = '1') else tag_q1(w)(20);

      --------- data, one RAM per way

      icache: entity work.dpram_dif
      generic map
      (
         addr_width_a  => 10,
         data_width_a  => 64,
         addr_width_b  => 11,
         data_width_b  => 32
      )
      port map
      (
         clock_a     => clk1x,
         address_a   => cache_ram_addr_a,
         data_a      => ddr3_DOUT,
         wren_a      => cache_wr_way(w),

         clock_b     => clk2x,
         clken_b     => '1',
         address_b   => cache_address_b,
         data_b      => x"00000000",
         wren_b      => '0',
         q_b         => cache_q_b(w)
      );

   end generate;

   read_hit1 <= hit1(0) or hit1(1);
   read_hit2 <= hit2(0) or hit2(1);
   read_hit  <= read_hit2 when (read_select = '1') else read_hit1;

   sel_set <= read_index2(12 downto 5) when (read_select = '1') else read_index1(12 downto 5);
   sel_way <= hit2(1) when (read_select = '1') else hit1(1);

   ------------------ replacement

   -- The way to replace in the lookup's set, with an update for that set
   -- still on its way to lru taken into account.
   lru_eff <= (not lru_upd_way) when (lru_upd = '1' and lru_upd_set = sel_set) else
              lru(to_integer(sel_set));

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (lru_upd = '1') then
            lru(to_integer(lru_upd_set)) <= not lru_upd_way;
         end if;
      end if;
   end process;

   --------- data

   -- The bridge, or the direct port, returns a fill's beats on clk1x, the line
   -- in order from its first qword. Consumed once each in that domain, as in
   -- cpu_instrcache.vhd, into the way the fill took.
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (reset_1x = '1') then
            fill_active_1x <= '0';
            fill_line_1x   <= (others => '0');
            fill_beat_1x   <= (others => '0');
         elsif (fill_grant = '1') then
            fill_active_1x <= '1';
            fill_line_1x   <= fill_addrTag_sav(12 downto 5);
            fill_beat_1x   <= (others => '0');
            if (ddr3_DOUT_READY = '1') then
               fill_beat_1x <= 2x"1";
            end if;
         elsif (ram_active = '0') then
            -- The transaction this window belongs to is over. ddr3_DOUT_READY
            -- pulses for every 64-bit return the bridge delivers, so a window
            -- left open would write another transaction's data into the line.
            fill_active_1x <= '0';
         elsif (fill_active_1x = '1' and ddr3_DOUT_READY = '1') then
            if (fill_beat_1x = 2x"3") then
               fill_active_1x <= '0';
            else
               fill_beat_1x <= fill_beat_1x + 1;
            end if;
         end if;
      end if;
   end process;

   cache_ram_addr_a <= std_logic_vector(fill_addrTag_sav(12 downto 5) & "00")
                       when (fill_grant = '1') else
                       std_logic_vector(fill_line_1x & fill_beat_1x);
   cache_wr_a       <= (fill_active_1x or fill_grant) and ddr3_DOUT_READY and ram_active;
   -- fill_way holds from the fill's start until its done, which comes after
   -- its last beat.
   cache_wr_way(0)  <= cache_wr_a and not fill_way;
   cache_wr_way(1)  <= cache_wr_a and fill_way;

   cache_address_b <= std_logic_vector(fill_addrTag_sav(12 downto 2)) when (state /= IDLE) else
                      std_logic_vector(read_index2(12 downto 2)) when (read_select = '1') else
                      std_logic_vector(read_index1(12 downto 2));

   rd_word   <= cache_q_b(1) when (rd_way = '1') else cache_q_b(0);
   read_data <= rd_word when LITTLE_ENDIAN else byteswap32(rd_word);

   process (clk2x)
   begin
      if rising_edge(clk2x) then

         tag_wren    <= "00";
         fill_done   <= '0';
         ram_request <= '0';
         lru_upd     <= '0';

         -- The way read_data comes from on the next cycle: the fill's while
         -- one is under way, else the way the lookup hit in.
         if (state /= IDLE) then
            rd_way <= fill_way;
         else
            rd_way <= sel_way;
         end if;

         -- Every lookup works out its victim: an invalid way first, else LRU.
         if (sel_valid(0) = '0') then
            victim <= '0';
         elsif (sel_valid(1) = '0') then
            victim <= '1';
         else
            victim <= lru_eff;
         end if;

         -- A hit makes the other way of its set the one to replace.
         if (state = IDLE and read_hit = '1') then
            lru_upd     <= '1';
            lru_upd_set <= sel_set;
            lru_upd_way <= sel_way;
         end if;

         if (fill_request = '1') then
            fill_latched <= '1';
         end if;

         if (reset_2x = '1') then
            state          <= CLEARCACHE;
            tag_data_a     <= (others => '0');
            tag_address_a  <= (others => '0');
            tag_wren       <= "11";
            fill_latched   <= '0';
            lru_upd        <= '0';
         else

            case(state) is

               when IDLE =>
                  fill_addrTag_sav <= fill_addrTag(12 downto 0);
                  if (CacheCommandEna = '1' and (CacheCommand = 5x"00" or CacheCommand = 5x"10")) then
                     -- Index Invalidate (0x00) clears the way address bit 13
                     -- names; Hit Invalidate (0x10) clears both ways.
                     tag_data_a     <= (others => '0');
                     tag_address_a  <= std_logic_vector(CacheCommandAddr(12 downto 5));
                     if (CacheCommand = 5x"10") then
                        tag_wren    <= "11";
                     elsif (CacheCommandAddr(13) = '1') then
                        tag_wren    <= "10";
                     else
                        tag_wren    <= "01";
                     end if;
                  elsif (CacheCommandEna = '1' and CacheCommand = 5x"08") then
                     -- Index Store Tag: TagLo into the way address bit 13 names.
                     tag_data_a     <= TagLo_Valid & std_logic_vector(TagLo_Addr);
                     tag_address_a  <= std_logic_vector(CacheCommandAddr(12 downto 5));
                     if (CacheCommandAddr(13) = '1') then
                        tag_wren    <= "10";
                     else
                        tag_wren    <= "01";
                     end if;
                  elsif (fill_request = '1' or fill_latched = '1') then
                     state          <= FILL;
                     ram_request    <= '1';
                     fill_latched   <= '0';
                     -- The lookup on the last edge was the missing fetch's
                     -- when its request arrives now.
                     if (fill_request = '1') then
                        fill_way    <= victim;
                     else
                        fill_way    <= '0';
                     end if;
                  end if;

               when CLEARCACHE =>
                  tag_wren       <= "11";
                  if (tag_address_a /= x"FF") then
                     tag_address_a <= std_logic_vector(unsigned(tag_address_a) + 1);
                  else
                     state          <= IDLE;
                  end if;

               when FILL =>
                  if (ram_done = '1') then
                     state          <= IDLE;
                     tag_data_a     <= '1' & std_logic_vector(fill_addrData(31 downto 12));
                     tag_address_a  <= std_logic_vector(fill_addrTag_sav(12 downto 5));
                     if (fill_way = '1') then
                        tag_wren    <= "10";
                     else
                        tag_wren    <= "01";
                     end if;
                     -- The way just filled is the most recently used.
                     lru_upd        <= '1';
                     lru_upd_set    <= fill_addrTag_sav(12 downto 5);
                     lru_upd_way    <= fill_way;
                     fill_done      <= '1';
                  end if;

            end case;

         end if;

      end if;
   end process;

end architecture;
