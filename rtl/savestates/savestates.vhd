-- Savestate engine, adapted from the NES_MiSTer core (Robert Peip).
--
-- Slot layout (32-bit words from the slot base):
--   0     : change counter (watched by Main_MiSTer)
--   1     : size in 32-bit words, without these two header words
--   2..   : INTERNALSCOUNT 64-bit registers from the savestate bus
--   then  : the memories of t_savetypes, in table order
--
-- The layout is fixed: new registers take free bus indexes and new
-- memories go after the last one, so older states stay loadable.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pBus_savestates.all;

entity savestates is
   port
   (
      clk                     : in     std_logic;

      restore                 : out    std_logic := '0';
      load_done               : out    std_logic := '0';

      increaseSSHeaderCount   : in     std_logic;
      save                    : in     std_logic;
      load                    : in     std_logic;
      savestate_address       : in     std_logic_vector(25 downto 0);
      savestate_busy          : out    std_logic;

      paused                  : in     std_logic;

      BUS_Din                 : out    std_logic_vector(BUS_buswidth-1 downto 0) := (others => '0');
      BUS_Adr                 : buffer std_logic_vector(BUS_busadr-1 downto 0) := (others => '0');
      BUS_wren                : out    std_logic := '0';
      BUS_rst                 : out    std_logic := '0';
      BUS_Dout                : in     std_logic_vector(BUS_buswidth-1 downto 0) := (others => '0');

      loading_savestate       : out    std_logic := '0';
      saving_savestate        : out    std_logic := '0';
      sleep_savestate         : out    std_logic := '0';

      Save_RAMAddr            : buffer std_logic_vector(24 downto 0) := (others => '0');
      Save_RAMRdEn            : out    std_logic := '0';
      Save_RAMWrEn            : out    std_logic := '0';
      Save_RAMWriteData       : out    std_logic_vector(7 downto 0) := (others => '0');
      Save_RAMReadData        : in     std_logic_vector(7 downto 0);
      Save_RAMType            : out    unsigned(2 downto 0);

      bus_out_Din             : out    std_logic_vector(63 downto 0) := (others => '0');
      bus_out_Dout            : in     std_logic_vector(63 downto 0);
      bus_out_Adr             : buffer std_logic_vector(25 downto 0) := (others => '0');
      bus_out_rnw             : out    std_logic := '0';
      bus_out_ena             : out    std_logic := '0';
      bus_out_be              : out    std_logic_vector(7 downto 0) := (others => '0');
      bus_out_done            : in     std_logic
   );
end entity;

architecture arch of savestates is

   constant MAXSIZEMEM     : integer := 65536;

   constant SETTLECOUNT    : integer := 100;
   constant HEADERCOUNT    : integer := 2;
   constant INTERNALSCOUNT : integer := 64;

   constant SAVETYPESCOUNT : integer := 6;
   signal savetype_counter : integer range 0 to SAVETYPESCOUNT;

   type save_type is record
      OFFSET     : integer range 0 to 16#FFFFFF#;
      SIZE       : integer range 0 to MAXSIZEMEM;
   end record;

   type t_savetypes is array(0 to SAVETYPESCOUNT - 1) of save_type;
   constant savetypes : t_savetypes :=
   (
      (0, 32768),  -- 0: work RAM
      (0, 65536),  -- 1: VRAM
      (0,   512),  -- 2: SAT
      (0,  1024),  -- 3: colour RAM
      (0,   256),  -- 4: PSG waveforms
      (0, 32768)   -- 5: Populous RAM
   );

   -- 32-bit words after the header: registers, then memories
   constant STATESIZE      : integer := INTERNALSCOUNT * 2 + (32768 + 65536 + 512 + 1024 + 256 + 32768) / 4;
   -- smallest size accepted on load: the registers alone
   constant MINSIZE        : integer := INTERNALSCOUNT * 2;
   -- largest size that fits in a slot (256 KB)
   constant MAXSIZE        : integer := 16#10000# - HEADERCOUNT;

   type tstate is
   (
      IDLE,
      SAVE_WAITSETTLE,
      SAVEINTERNALS_WAIT,
      SAVEINTERNALS_WRITE,
      SAVEMEMORY_NEXT,
      SAVEMEMORY_READ,
      SAVEMEMORY_WRITE,
      SAVESIZEAMOUNT,
      LOAD_WAITSETTLE,
      LOAD_HEADERAMOUNTCHECK,
      LOADINTERNALS_READ,
      LOADINTERNALS_WRITE,
      LOADMEMORY_RESET,
      LOADMEMORY_NEXT,
      LOADMEMORY_READ,
      LOADMEMORY_WRITE
   );
   signal state : tstate := IDLE;

   signal count               : integer range 0 to MAXSIZEMEM := 0;
   signal maxcount            : integer range 0 to MAXSIZEMEM;

   signal settle              : integer range 0 to SETTLECOUNT := 0;

   signal bytecounter         : integer range 0 to 7 := 0;
   signal RAMAddrNext         : std_logic_vector(24 downto 0) := (others => '0');
   signal memory_slow         : unsigned(2 downto 0) := (others => '0');

   signal header_amount       : unsigned(31 downto 0) := to_unsigned(1, 32);

begin

   savestate_busy <= '0' when state = IDLE else '1';

   process (clk)
   begin
      if rising_edge(clk) then

         bus_out_ena   <= '0';
         BUS_wren      <= '0';
         BUS_rst       <= '0';
         restore       <= '0';
         load_done     <= '0';

         bus_out_be    <= x"FF";

         memory_slow <= memory_slow + 1;
         if (memory_slow = 6) then
            Save_RAMRdEn  <= '0';
            Save_RAMWrEn  <= '0';
         end if;

         case state is

            when IDLE =>
               savetype_counter <= 0;
               if (save = '1') then
                  state                <= SAVE_WAITSETTLE;
                  settle               <= 0;
                  sleep_savestate      <= '1';
                  header_amount        <= header_amount + 1;
               elsif (load = '1') then
                  state                <= LOAD_WAITSETTLE;
                  settle               <= 0;
                  sleep_savestate      <= '1';
               end if;

            -- #################
            -- SAVE
            -- #################

            when SAVE_WAITSETTLE =>
               if (paused = '0') then
                  settle <= 0;
               elsif (settle < SETTLECOUNT) then
                  settle <= settle + 1;
               else
                  state            <= SAVEINTERNALS_WAIT;
                  bus_out_Adr      <= std_logic_vector(unsigned(savestate_address) + HEADERCOUNT);
                  bus_out_rnw      <= '0';
                  BUS_adr          <= (others => '0');
                  count            <= 1;
                  saving_savestate <= '1';
               end if;

            when SAVEINTERNALS_WAIT =>
               bus_out_Din    <= BUS_Dout;
               bus_out_ena    <= '1';
               state          <= SAVEINTERNALS_WRITE;

            when SAVEINTERNALS_WRITE =>
               if (bus_out_done = '1') then
                  bus_out_Adr <= std_logic_vector(unsigned(bus_out_Adr) + 2);
                  if (count < INTERNALSCOUNT) then
                     state       <= SAVEINTERNALS_WAIT;
                     count       <= count + 1;
                     BUS_adr     <= std_logic_vector(unsigned(BUS_adr) + 1);
                  else
                     state       <= SAVEMEMORY_NEXT;
                     count       <= 8;
                  end if;
               end if;

            when SAVEMEMORY_NEXT =>
               if (savetype_counter < SAVETYPESCOUNT) then
                  state          <= SAVEMEMORY_READ;
                  bytecounter    <= 0;
                  count          <= 8;
                  maxcount       <= savetypes(savetype_counter).SIZE;
                  Save_RAMAddr   <= std_logic_vector(to_unsigned(savetypes(savetype_counter).OFFSET, Save_RAMAddr'length));
                  Save_RAMRdEn   <= '1';
                  memory_slow    <= (others => '0');
                  Save_RAMType   <= to_unsigned(savetype_counter, 3);
               else
                  state          <= SAVESIZEAMOUNT;
                  bus_out_Adr    <= savestate_address;
                  bus_out_Din    <= std_logic_vector(to_unsigned(STATESIZE, 32)) & std_logic_vector(header_amount);
                  bus_out_ena    <= '1';
                  if (increaseSSHeaderCount = '0') then
                     bus_out_be  <= x"F0";
                  end if;
               end if;

            when SAVEMEMORY_READ =>
               if (memory_slow = 7) then
                  bus_out_Din(bytecounter * 8 + 7 downto bytecounter * 8) <= Save_RAMReadData;
                  if (bytecounter < 7) then
                     bytecounter    <= bytecounter + 1;
                     Save_RAMAddr   <= std_logic_vector(unsigned(Save_RAMAddr) + 1);
                     Save_RAMRdEn   <= '1';
                  else
                     state          <= SAVEMEMORY_WRITE;
                     bus_out_ena    <= '1';
                  end if;
               end if;

            when SAVEMEMORY_WRITE =>
               if (bus_out_done = '1') then
                  bus_out_Adr <= std_logic_vector(unsigned(bus_out_Adr) + 2);
                  if (count < maxcount) then
                     state        <= SAVEMEMORY_READ;
                     bytecounter  <= 0;
                     count        <= count + 8;
                     Save_RAMAddr <= std_logic_vector(unsigned(Save_RAMAddr) + 1);
                     Save_RAMRdEn <= '1';
                     memory_slow  <= (others => '0');
                  else
                     savetype_counter <= savetype_counter + 1;
                     state            <= SAVEMEMORY_NEXT;
                  end if;
               end if;

            when SAVESIZEAMOUNT =>
               if (bus_out_done = '1') then
                  state            <= IDLE;
                  saving_savestate <= '0';
                  sleep_savestate  <= '0';
               end if;


            -- #################
            -- LOAD
            -- #################

            when LOAD_WAITSETTLE =>
               if (paused = '0') then
                  settle <= 0;
               elsif (settle < SETTLECOUNT) then
                  settle <= settle + 1;
               else
                  state                <= LOAD_HEADERAMOUNTCHECK;
                  bus_out_Adr          <= savestate_address;
                  bus_out_rnw          <= '1';
                  bus_out_ena          <= '1';
               end if;

            when LOAD_HEADERAMOUNTCHECK =>
               if (bus_out_done = '1') then
                  if (unsigned(bus_out_Dout(63 downto 32)) >= to_unsigned(MINSIZE, 32) and
                      unsigned(bus_out_Dout(63 downto 32)) <= to_unsigned(MAXSIZE, 32)) then
                     header_amount        <= unsigned(bus_out_Dout(31 downto 0));
                     state                <= LOADINTERNALS_READ;
                     bus_out_Adr          <= std_logic_vector(unsigned(savestate_address) + HEADERCOUNT);
                     bus_out_ena          <= '1';
                     BUS_adr              <= (others => '0');
                     count                <= 1;
                     loading_savestate    <= '1';
                  else
                     state                <= IDLE;
                     sleep_savestate      <= '0';
                  end if;
               end if;

            when LOADINTERNALS_READ =>
               if (bus_out_done = '1') then
                  state           <= LOADINTERNALS_WRITE;
                  BUS_Din         <= bus_out_Dout;
                  BUS_wren        <= '1';
               end if;

            when LOADINTERNALS_WRITE =>
               bus_out_Adr <= std_logic_vector(unsigned(bus_out_Adr) + 2);
               if (count < INTERNALSCOUNT) then
                  state          <= LOADINTERNALS_READ;
                  count          <= count + 1;
                  bus_out_ena    <= '1';
                  BUS_adr        <= std_logic_vector(unsigned(BUS_adr) + 1);
               else
                  state          <= LOADMEMORY_RESET;
               end if;

            when LOADMEMORY_RESET =>
               restore   <= '1';
               state     <= LOADMEMORY_NEXT;
               count     <= 8;

            when LOADMEMORY_NEXT =>
               if (memory_slow = 7) then
                  if (savetype_counter < SAVETYPESCOUNT) then
                     state          <= LOADMEMORY_READ;
                     count          <= 8;
                     maxcount       <= savetypes(savetype_counter).SIZE;
                     RAMAddrNext    <= std_logic_vector(to_unsigned(savetypes(savetype_counter).OFFSET, Save_RAMAddr'length));
                     bytecounter    <= 0;
                     bus_out_ena    <= '1';
                     Save_RAMType   <= to_unsigned(savetype_counter, 3);
                  else
                     state             <= IDLE;
                     loading_savestate <= '0';
                     sleep_savestate   <= '0';
                     load_done         <= '1';
                  end if;
               end if;

            when LOADMEMORY_READ =>
               if (bus_out_done = '1') then
                  state             <= LOADMEMORY_WRITE;
               end if;

            when LOADMEMORY_WRITE =>
               if (memory_slow = 7) then
                  RAMAddrNext                    <= std_logic_vector(unsigned(RAMAddrNext) + 1);
                  Save_RAMAddr                   <= RAMAddrNext;
                  Save_RAMWrEn                   <= '1';
                  Save_RAMWriteData              <= bus_out_Dout(bytecounter * 8 + 7 downto bytecounter * 8);
                  memory_slow                    <= (others => '0');
                  if (bytecounter < 7) then
                     bytecounter       <= bytecounter + 1;
                  else
                     bus_out_Adr  <= std_logic_vector(unsigned(bus_out_Adr) + 2);
                     if (count < maxcount) then
                        state          <= LOADMEMORY_READ;
                        count          <= count + 8;
                        bytecounter    <= 0;
                        bus_out_ena    <= '1';
                     else
                        savetype_counter <= savetype_counter + 1;
                        state            <= LOADMEMORY_NEXT;
                     end if;
                  end if;
               end if;

         end case;

      end if;
   end process;

end architecture;
