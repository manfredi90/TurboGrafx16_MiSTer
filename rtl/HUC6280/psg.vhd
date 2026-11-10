library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;
library work;
use work.pBus_savestates.all;

entity psg is
	port (
		CLK 	: in std_logic;
		CLKEN	: in std_logic;
		RESET_N	: in std_logic;

		-- CPU Interface
		DI		: in std_logic_vector(7 downto 0);
		A 		: in std_logic_vector(3 downto 0);
		WE		: in std_logic;

		-- DAC Interface
		DAC_LATCH	: in std_logic;
		LDATA		: out std_logic_vector(23 downto 0);
		RDATA		: out std_logic_vector(23 downto 0);

		-- savestates
		FREEZE      : in  std_logic := '0';
		SS_RESTORE  : in  std_logic := '0';
		SS_BUS_Din  : in  std_logic_vector(BUS_buswidth-1 downto 0) := (others => '0');
		SS_BUS_Adr  : in  std_logic_vector(BUS_busadr-1 downto 0) := (others => '1');
		SS_BUS_wren : in  std_logic := '0';
		SS_BUS_rst  : in  std_logic := '0';
		SS_BUS_Dout : out std_logic_vector(BUS_buswidth-1 downto 0);
		SS_WAVE_A   : in  std_logic_vector(7 downto 0) := (others => '0');
		SS_WAVE_D   : in  std_logic_vector(4 downto 0) := (others => '0');
		SS_WAVE_WE  : in  std_logic := '0';
		SS_WAVE_Q   : out std_logic_vector(4 downto 0)
	);
end psg;

architecture rtl of psg is

-- R0 - Channel Selection
signal CHSEL	: integer range 0 to 7;
-- R1 - Main Volume Adjustement
signal LMAL		: std_logic_vector(3 downto 0);
signal RMAL		: std_logic_vector(3 downto 0);

-- R2-R7 - Channel specific registers
type wavedata_t is array(0 to 31) of std_logic_vector(4 downto 0);
type chan_t is
	record
		-- Registers
		FREQ		: std_logic_vector(11 downto 0);
		DDA		: std_logic;
		CHON		: std_logic;
		AL			: std_logic_vector(4 downto 0);
		LAL		: std_logic_vector(3 downto 0);
		RAL		: std_logic_vector(3 downto 0);

		NG_FREQ	: std_logic_vector(4 downto 0);
		NE			: std_logic;

		-- Waveform generator
		WF_DATA	: wavedata_t;
		WF_ADDR	: std_logic_vector(4 downto 0);
		WF_CNT	: std_logic_vector(12 downto 0);

		WF_RES	: std_logic;
		WF_INC	: std_logic;

		-- Noise generator
		LFSR		: std_logic_vector(17 downto 0);
		NG_CNT	: std_logic_vector(11 downto 0);

		-- Outputs
		DA_OUT	: std_logic_vector(4 downto 0);
		WF_OUT	: std_logic_vector(4 downto 0);
		NG_OUT	: std_logic_vector(4 downto 0);
		-- Global output
		GL_OUT	: std_logic_vector(4 downto 0);

		-- LFO
		LFO_FREQ	: std_logic_vector(7 downto 0);
		LFCTL		: std_logic_vector(1 downto 0);
		LFTRG		: std_logic;
		LFO_CNT	: std_logic_vector(7 downto 0);
		LFO_ADD 	: std_logic_vector(11 downto 0);
	end record;
type chanarray_t is array(0 to 5) of chan_t;
signal CH		: chanarray_t;

-- Channels mixing
signal LACC		: std_logic_vector(23 downto 0);
signal RACC		: std_logic_vector(23 downto 0);

signal VT_ADDR	: std_logic_vector(11 downto 0);
signal VT_DATA	: std_logic_vector(23 downto 0);

type mix_t is ( MIX_WAIT, MIX_NEXT, MIX_LREAD, MIX_LNEXT, MIX_RREAD, MIX_RNEXT, MIX_END );
signal MIX		: mix_t;
signal MIX_CNT	: std_logic_vector(2 downto 0);

signal LDATA_FF	: std_logic_vector(23 downto 0);
signal RDATA_FF	: std_logic_vector(23 downto 0);

-- savestates: 8 = globals, 9 + 2*ch = channel registers, 10 + 2*ch = channel counters, 21..23 = mixer
type ss_regs_t is array(0 to 15) of std_logic_vector(63 downto 0);
signal SS_MIX      : std_logic_vector(2 downto 0);
signal SS_IN, SS_OUT, SS_DO : ss_regs_t;
signal SS_WAVE_CH  : integer range 0 to 5;
signal SS_WAVE_OK  : std_logic;
signal SS_WAVE_IDX : integer range 0 to 31;

begin

-- CPU Interface
process( CLK )
begin
	if rising_edge( CLK ) then
		if FREEZE = '0' then

		for i in 0 to 5 loop
			CH(i).WF_RES <= '0';
			CH(i).WF_INC <= '0';
		end loop;

		if RESET_N = '0' then

			CHSEL <= 0;
			LMAL <= (others => '0');
			RMAL <= (others => '0');

			for i in 0 to 5 loop
				CH(i).FREQ <= (others => '0');
				CH(i).DDA <= '0';
				CH(i).CHON <= '0';
				CH(i).LAL <= (others => '0');
				CH(i).RAL <= (others => '0');
				CH(i).NG_FREQ <= (others => '0');
				CH(i).NE <= '0';
				CH(i).DA_OUT <= (others => '0');
				CH(i).LFO_FREQ <= (others => '0');
				CH(i).LFCTL <= "00";
				CH(i).LFTRG <= '0';
			end loop;
		else
			if WE = '1' then
				case A is
				when "0000" =>
					CHSEL <= conv_integer(DI(2 downto 0));

				when "0001" =>
					LMAL <= DI(7 downto 4);
					RMAL <= DI(3 downto 0);

				when "0010" =>
					CH(CHSEL).FREQ(7 downto 0) <= DI;

				when "0011" =>
					CH(CHSEL).FREQ(11 downto 8) <= DI(3 downto 0);

				when "0100" =>
					CH(CHSEL).CHON <= DI(7);
					CH(CHSEL).DDA <= DI(6);
					CH(CHSEL).AL <= DI(4 downto 0);
					if CH(CHSEL).DDA = '1' and DI(6) = '0' then
						CH(CHSEL).WF_RES <= '1';
					end if;

				when "0101" =>
					CH(CHSEL).LAL <= DI(7 downto 4);
					CH(CHSEL).RAL <= DI(3 downto 0);

				when "0110" =>
					if CH(CHSEL).DDA = '0' then
						CH(CHSEL).WF_DATA(conv_integer(CH(CHSEL).WF_ADDR)) <= DI(4 downto 0);
					end if;
					if CH(CHSEL).CHON = '1' then
						CH(CHSEL).DA_OUT <= DI(4 downto 0);
					end if;
					if CH(CHSEL).DDA = '0' and CH(CHSEL).CHON = '0' then
						CH(CHSEL).WF_INC <= '1';
					end if;

				when "0111" =>
					if CHSEL = 4 or CHSEL =5 then
						CH(CHSEL).NE <= DI(7);
						CH(CHSEL).NG_FREQ <= DI(4 downto 0);
					end if;

				when "1000" =>
					CH(1).LFO_FREQ <= DI;

				when "1001" =>
					CH(1).LFCTL <= DI(1 downto 0);
					CH(1).LFTRG <= DI(7);

				when others => null;
				end case;
			end if;
		end if;
		end if;

		if SS_RESTORE = '1' then
			CHSEL <= to_integer(unsigned(SS_IN(0)(2 downto 0)));
			LMAL <= SS_IN(0)(6 downto 3);
			RMAL <= SS_IN(0)(10 downto 7);
			for i in 0 to 5 loop
				CH(i).FREQ     <= SS_IN(1+i*2)(11 downto 0);
				CH(i).DDA      <= SS_IN(1+i*2)(12);
				CH(i).CHON     <= SS_IN(1+i*2)(13);
				CH(i).AL       <= SS_IN(1+i*2)(18 downto 14);
				CH(i).LAL      <= SS_IN(1+i*2)(22 downto 19);
				CH(i).RAL      <= SS_IN(1+i*2)(26 downto 23);
				CH(i).NG_FREQ  <= SS_IN(1+i*2)(31 downto 27);
				CH(i).NE       <= SS_IN(1+i*2)(32);
				CH(i).LFO_FREQ <= SS_IN(1+i*2)(58 downto 51);
				CH(i).LFCTL    <= SS_IN(1+i*2)(60 downto 59);
				CH(i).LFTRG    <= SS_IN(1+i*2)(61);
				CH(i).DA_OUT   <= SS_IN(2+i*2)(34 downto 30);
				CH(i).WF_RES   <= '0';
				CH(i).WF_INC   <= '0';
			end loop;
		end if;

		if SS_WAVE_WE = '1' and SS_WAVE_OK = '1' then
			CH(SS_WAVE_CH).WF_DATA(SS_WAVE_IDX) <= SS_WAVE_D;
		end if;
	end if;
end process;


process( CLK ) begin
	if rising_edge( CLK ) then
		if FREEZE = '0' then
		for i in 0 to 5 loop
			if RESET_N = '0' then
				CH(i).GL_OUT <= (others => '0');
				CH(i).WF_CNT <= (others => '0');
				CH(i).LFSR <= (others => '0');
				CH(i).NG_CNT <= (others => '0');
				CH(i).LFO_CNT <= (others => '0');
			else
				if CH(i).WF_RES = '1' then
					CH(i).WF_ADDR <= (others => '0');
				end if;
				if CH(i).WF_INC = '1' then
					CH(i).WF_ADDR <= CH(i).WF_ADDR + 1;
				end if;

				if CH(i).LFCTL /= "00" then
					CH(i).WF_OUT <= CH(i).WF_DATA(conv_integer(CH(i).WF_ADDR));

					if CH(i).LFTRG = '1' then
						CH(i).WF_ADDR <= (others => '0');
						CH(i).WF_CNT <= (CH(i).FREQ - 1) & "1";
						CH(i).LFO_CNT <= CH(i).LFO_FREQ - 1;
					else
						if CLKEN = '1' then
							CH(i).LFO_CNT <= CH(i).LFO_CNT - 1;
							if CH(i).LFO_CNT = 0 then
								CH(i).LFO_CNT <= CH(i).LFO_FREQ - 1;
								CH(i).WF_CNT <= CH(i).WF_CNT - 1;
								if CH(i).WF_CNT = 0 then
									CH(i).WF_CNT <= (CH(i).FREQ - 1) & "1";
									CH(i).WF_ADDR <= CH(i).WF_ADDR + 1;
								end if;
							end if;
						end if;
					end if;
				elsif CH(i).CHON = '0' then
					CH(i).WF_CNT <= (CH(i).FREQ - 1 + CH(i).LFO_ADD) & "1";
				elsif CH(i).DDA = '0' then
					CH(i).WF_OUT <= CH(i).WF_DATA(conv_integer(CH(i).WF_ADDR));

					if CLKEN = '1' then
						CH(i).WF_CNT <= CH(i).WF_CNT - 1;
						if CH(i).WF_CNT = 0 then
							CH(i).WF_CNT <= (CH(i).FREQ - 1 + CH(i).LFO_ADD) & "1";
							CH(i).WF_ADDR <= CH(i).WF_ADDR + 1;
						end if;
					end if;
				end if;

				if CH(i).NE = '0' then
				if CH(i).NG_FREQ = "11111" then
						CH(i).NG_CNT <= "000000111111";
					else
						CH(i).NG_CNT <= ( not(CH(i).NG_FREQ) - 1) & "1111111";
					end if;
				else
					if CH(i).LFSR(0) = '0' then
						CH(i).NG_OUT <= "00000";
					else
						CH(i).NG_OUT <= "11111";
					end if;

					if CLKEN = '1' then
						CH(i).NG_CNT <= CH(i).NG_CNT - 1;
						if CH(i).NG_CNT = 0 then
							if CH(i).NG_FREQ = "11111" then
								CH(i).NG_CNT <= "000000111111";
							else
								CH(i).NG_CNT <= ( not(CH(i).NG_FREQ) - 1) & "1111111";
							end if;
							if CH(i).LFSR = 0 then
								CH(i).LFSR(0) <= '1';
							else
								CH(i).LFSR <= (CH(i).LFSR(0) xor CH(i).LFSR(1) xor CH(i).LFSR(11) xor CH(i).LFSR(12) xor CH(i).LFSR(17)) & CH(i).LFSR(17 downto 1);
							end if;
						end if;
					end if;
				end if;

				if CH(i).CHON = '0' then
					CH(i).GL_OUT <= "10000";		-- Not zero; this should be midpoint in the range to reduce 'pop' sound
				elsif CH(i).DDA = '1' then
					CH(i).GL_OUT <= CH(i).DA_OUT;
				elsif CH(i).NE = '1' then
					CH(i).GL_OUT <= CH(i).NG_OUT;
				else
					CH(i).GL_OUT <= CH(i).WF_OUT;
				end if;
			end if;
		end loop;
		end if;

		if SS_RESTORE = '1' then
			for i in 0 to 5 loop
				CH(i).WF_ADDR <= SS_IN(1+i*2)(37 downto 33);
				CH(i).WF_CNT  <= SS_IN(1+i*2)(50 downto 38);
				CH(i).LFSR    <= SS_IN(2+i*2)(17 downto 0);
				CH(i).NG_CNT  <= SS_IN(2+i*2)(29 downto 18);
				CH(i).LFO_CNT <= SS_IN(2+i*2)(42 downto 35);
				CH(i).WF_OUT  <= SS_IN(2+i*2)(47 downto 43);
				CH(i).NG_OUT  <= SS_IN(2+i*2)(52 downto 48);
				CH(i).GL_OUT  <= SS_IN(2+i*2)(57 downto 53);
			end loop;
		end if;
	end if;
end process;

process( CLK )
	variable DATA: std_logic_vector(4 downto 0);
begin
	if rising_edge( CLK ) then
		if FREEZE = '1' then
			null;
		elsif RESET_N = '0' then
			for i in 0 to 5 loop
				CH(i).LFO_ADD <= (others => '0');
			end loop;
		else
			DATA := CH(1).WF_DATA(conv_integer(CH(1).WF_ADDR)) xor "1000";
			CH(0).LFO_ADD(11 downto 8) <= DATA(4) & DATA(4) & DATA(4) & DATA(4);
			case CH(1).LFCTL is
			when "01" =>   CH(0).LFO_ADD(7 downto 0) <= DATA(4) & DATA(4) & DATA(4) & DATA;
			when "10" =>   CH(0).LFO_ADD(7 downto 0) <= DATA(4) & DATA & "00";
			when "11" =>   CH(0).LFO_ADD(7 downto 0) <= DATA(3 downto 0) & "0000";
			when others => CH(0).LFO_ADD <= (others => '0');
			end case;
		end if;
		if SS_RESTORE = '1' then
			CH(0).LFO_ADD <= SS_IN(0)(22 downto 11);
		end if;
	end if;
end process;

-- Channels mixing
VT : entity work.dpram generic map (12,24,"HUC6280/voltab.mif")
port map (
	clock		=> CLK,
	address_a=> VT_ADDR,
	q_a		=> VT_DATA
);

process( CLK )
begin
	if rising_edge( CLK ) then
		if FREEZE = '1' then
			null;
		elsif RESET_N = '0' then
			LDATA_FF <= (others => '0');
			RDATA_FF <= (others => '0');
			MIX <= MIX_WAIT;
		else
			case MIX is
			when MIX_WAIT =>
				LACC <= (others => '0');
				RACC <= (others => '0');
				MIX_CNT <= (others => '0');
				VT_ADDR <= (others => '1');
				if DAC_LATCH = '1' then
					MIX <= MIX_NEXT;
				end if;

			when MIX_NEXT =>
				VT_ADDR <= CH(conv_integer(MIX_CNT)).GL_OUT
					& ( "1011101" - CH(conv_integer(MIX_CNT)).AL - (CH(conv_integer(MIX_CNT)).LAL & "1") - (LMAL & "1") );
				MIX <= MIX_LREAD;

			when MIX_LREAD =>
				MIX <= MIX_LNEXT;

			when MIX_LNEXT =>
				LACC <= LACC + VT_DATA;
				VT_ADDR <= CH(conv_integer(MIX_CNT)).GL_OUT
					& ( "1011101" - CH(conv_integer(MIX_CNT)).AL - (CH(conv_integer(MIX_CNT)).RAL & "1") - (RMAL & "1") );
				MIX <= MIX_RREAD;

			when MIX_RREAD =>
				MIX <= MIX_RNEXT;

			when MIX_RNEXT =>
				RACC <= RACC + VT_DATA;
				if MIX_CNT = "101" then
					MIX <= MIX_END;
				else
					MIX_CNT <= MIX_CNT + 1;
					MIX <= MIX_NEXT;
				end if;

			when MIX_END =>
				LDATA_FF <= LACC;
				RDATA_FF <= RACC;
				MIX <= MIX_WAIT;

			when others => null;
			end case;
		end if;
		if SS_RESTORE = '1' then
			case SS_IN(13)(2 downto 0) is
				when "001"  => MIX <= MIX_NEXT;
				when "010"  => MIX <= MIX_LREAD;
				when "011"  => MIX <= MIX_LNEXT;
				when "100"  => MIX <= MIX_RREAD;
				when "101"  => MIX <= MIX_RNEXT;
				when "110"  => MIX <= MIX_END;
				when others => MIX <= MIX_WAIT;
			end case;
			MIX_CNT  <= SS_IN(13)(5 downto 3);
			VT_ADDR  <= SS_IN(13)(17 downto 6);
			LACC     <= SS_IN(13)(41 downto 18);
			RACC     <= SS_IN(14)(23 downto 0);
			LDATA_FF <= SS_IN(14)(47 downto 24);
			RDATA_FF <= SS_IN(15)(23 downto 0);
		end if;
	end if;
end process;

LDATA <= LDATA_FF;
RDATA <= RDATA_FF;

-- savestates
SS_OUT(0) <= (63 downto 23 => '0') & CH(0).LFO_ADD & RMAL & LMAL & std_logic_vector(to_unsigned(CHSEL, 3));

gSS_CH: for i in 0 to 5 generate
	SS_OUT(1+i*2) <= "00" & CH(i).LFTRG & CH(i).LFCTL & CH(i).LFO_FREQ & CH(i).WF_CNT & CH(i).WF_ADDR & CH(i).NE & CH(i).NG_FREQ &
	                 CH(i).RAL & CH(i).LAL & CH(i).AL & CH(i).CHON & CH(i).DDA & CH(i).FREQ;
	SS_OUT(2+i*2) <= "000000" & CH(i).GL_OUT & CH(i).NG_OUT & CH(i).WF_OUT & CH(i).LFO_CNT & CH(i).DA_OUT & CH(i).NG_CNT & CH(i).LFSR;
end generate;

SS_MIX <= "001" when MIX = MIX_NEXT  else "010" when MIX = MIX_LREAD else "011" when MIX = MIX_LNEXT else
          "100" when MIX = MIX_RREAD else "101" when MIX = MIX_RNEXT else "110" when MIX = MIX_END   else "000";
SS_OUT(13) <= (63 downto 42 => '0') & LACC & VT_ADDR & MIX_CNT & SS_MIX;
SS_OUT(14) <= (63 downto 48 => '0') & LDATA_FF & RACC;
SS_OUT(15) <= (63 downto 24 => '0') & RDATA_FF;

gSS: for i in 0 to 15 generate
	iREG : entity work.eReg_SavestateV generic map (8 + i, (others => '0'))
	port map (CLK, SS_BUS_Din, SS_BUS_Adr, SS_BUS_wren, SS_BUS_rst, SS_DO(i), SS_OUT(i), SS_IN(i));
end generate;

process(SS_DO)
	variable v : std_logic_vector(63 downto 0);
begin
	v := (others => '0');
	for i in 0 to 15 loop
		v := v or SS_DO(i);
	end loop;
	SS_BUS_Dout <= v;
end process;

SS_WAVE_OK  <= '1' when unsigned(SS_WAVE_A(7 downto 5)) < 6 else '0';
SS_WAVE_CH  <= to_integer(unsigned(SS_WAVE_A(7 downto 5))) when unsigned(SS_WAVE_A(7 downto 5)) < 6 else 0;
SS_WAVE_IDX <= to_integer(unsigned(SS_WAVE_A(4 downto 0)));

process( CLK ) begin
	if rising_edge( CLK ) then
		if SS_WAVE_OK = '1' then
			SS_WAVE_Q <= CH(SS_WAVE_CH).WF_DATA(SS_WAVE_IDX);
		else
			SS_WAVE_Q <= (others => '0');
		end if;
	end if;
end process;

end rtl;

