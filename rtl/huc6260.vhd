library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_TEXTIO.all;
library STD;
use STD.TEXTIO.ALL;
library work;
use work.pBus_savestates.all;

entity huc6260 is
	port (
		CLK 		: in std_logic;
		RESET_N	: in std_logic;

		-- CPU Interface
		A			: in std_logic_vector(2 downto 0);
		CE_N		: in std_logic;
		WR_N		: in std_logic;
		RD_N		: in std_logic;
		DI			: in std_logic_vector(7 downto 0);
		DO 		: out std_logic_vector(7 downto 0);

		-- VDC Interface
		COLNO		: in std_logic_vector(8 downto 0);
		CLKEN		: out std_logic;
		CLKEN_F	: out std_logic;
		HSYNC_F	: out std_logic;
		HSYNC_R	: out std_logic;
		VSYNC_F	: out std_logic;
		VSYNC_R	: out std_logic;
		CLKEN_FS	: out std_logic;
		RVBL		: in std_logic;
		
		GRID_EN	: in std_logic_vector(1 downto 0);
		BORDER_EN: in std_logic;
		BORDER	: in std_logic;
		GRID		: in std_logic_vector(1 downto 0);

		-- NTSC/RGB Video Output
		R			: out std_logic_vector(2 downto 0);
		G			: out std_logic_vector(2 downto 0);
		B			: out std_logic_vector(2 downto 0);
		BW			: out std_logic;

		VS_N		: out std_logic;
		HS_N		: out std_logic;
		HBL		: out std_logic;
		VBL		: out std_logic;

		-- savestates
		FREEZE      : in  std_logic := '0';
		SS_IDLE     : out std_logic;
		SS_RESTORE  : in  std_logic := '0';
		SS_BUS_Din  : in  std_logic_vector(BUS_buswidth-1 downto 0) := (others => '0');
		SS_BUS_Adr  : in  std_logic_vector(BUS_busadr-1 downto 0) := (others => '1');
		SS_BUS_wren : in  std_logic := '0';
		SS_BUS_rst  : in  std_logic := '0';
		SS_BUS_Dout : out std_logic_vector(BUS_buswidth-1 downto 0);
		SS_PAL_SEL  : in  std_logic := '0';
		SS_PAL_A    : in  std_logic_vector(8 downto 0) := (others => '0');
		SS_PAL_D    : in  std_logic_vector(8 downto 0) := (others => '0');
		SS_PAL_WE   : in  std_logic := '0';
		SS_PAL_Q    : out std_logic_vector(8 downto 0)
	);
end huc6260;

architecture rtl of huc6260 is

-- CPU Interface
signal PREV_A	: std_logic_vector(2 downto 0);

type ctrl_t is ( CTRL_IDLE, CTRL_WAIT, CTRL_INCR );
signal CTRL		: ctrl_t;
signal CR		: std_logic_vector(7 downto 0);

-- VCE Registers
signal DOTCLOCK	: std_logic_vector(1 downto 0);

-- CPU Color RAM Interface
signal RAM_A	: std_logic_vector(8 downto 0);
signal RAM_DI	: std_logic_vector(8 downto 0);
signal RAM_WE	: std_logic := '0';
signal RAM_DO	: std_logic_vector(8 downto 0);

-- CPU conflict color latching
signal R_FF	: std_logic_vector(2 downto 0);
signal G_FF	: std_logic_vector(2 downto 0);
signal B_FF	: std_logic_vector(2 downto 0);
signal CE_N_FF : std_logic := '1';

-- Color RAM Output
signal COLOR	: std_logic_vector(8 downto 0);

constant LEFT_BL_CLOCKS	: integer := 456;
constant DISP_CLOCKS	   : integer := 2160;
constant LINE_CLOCKS	   : integer := 2730;
constant HS_CLOCKS		: integer := 192;
constant HS_OFF			: integer := 46;

constant TOTAL_LINES		: integer := 263;  -- 525
constant VS_LINES			: integer := 3; 	 -- pcetech.txt
constant TOP_BL_LINES_E	: integer := 19;   -- pcetech.txt (must include VS_LINES in current implementation)
constant DISP_LINES_E	: integer := 242;	 -- same as in mednafen
signal TOP_BL_LINES		: integer;
signal DISP_LINES			: integer;
signal END_LINE			: integer := TOTAL_LINES;
signal HSYNC_START_POS	: integer;
signal HSYNC_END_POS 	: integer;

signal H_CNT	: std_logic_vector(11 downto 0);
signal V_CNT	: std_logic_vector(9 downto 0);

signal HBL_FF, HBL_FF2	: std_logic;
signal VBL_FF, VBL_FF2	: std_logic;

-- Clock generation
signal CLKEN_CNT	: std_logic_vector(2 downto 0);
signal CLKEN_FS_CNT: std_logic_vector(2 downto 0);
signal CLKEN_FF	: std_logic;
signal CLKEN_FF_F	: std_logic;
signal MULTIRES_FF : std_logic;
signal MULTIRES   : std_logic;

-- savestates
type ss_regs_t is array(0 to 1) of std_logic_vector(63 downto 0);
signal SS_IN, SS_OUT, SS_DO : ss_regs_t;
signal SS_CTRL     : std_logic_vector(1 downto 0);
signal PAL_A_B     : std_logic_vector(8 downto 0);
signal PAL_WE_B    : std_logic;
signal HSYNC_F_R, HSYNC_R_R, VSYNC_F_R, VSYNC_R_R : std_logic;
signal CLKEN_FS_R  : std_logic;
signal VS_N_R, HS_N_R, HBL_R, VBL_R : std_logic;
signal R_R, G_R, B_R : std_logic_vector(2 downto 0);
signal DO_R        : std_logic_vector(7 downto 0);
signal BW_R        : std_logic;

begin

TOP_BL_LINES <= TOP_BL_LINES_E when RVBL = '1' else TOP_BL_LINES_E+4;
DISP_LINES   <= DISP_LINES_E   when RVBL = '1' else DISP_LINES_E-11;
	 
-- Color RAM
ram : entity work.dpram generic map (addr_width => 9, data_width => 9, mem_init_file =>"huc6260_palette_init.mif")
port map(
	clock			=> CLK,

	address_a	=> RAM_A,
	data_a		=> RAM_DI,
	wren_a		=> RAM_WE,
	q_a			=> RAM_DO,
	
	address_b	=> PAL_A_B,
	data_b		=> SS_PAL_D,
	wren_b		=> PAL_WE_B,
	q_b			=> COLOR
);

PAL_A_B  <= SS_PAL_A when SS_PAL_SEL = '1' else COLNO;
PAL_WE_B <= SS_PAL_SEL and SS_PAL_WE;
SS_PAL_Q <= COLOR;

process( CLK )
begin
	if rising_edge( CLK ) then
		if FREEZE = '0' then
		if RESET_N = '0' then
			RAM_A <= (others => '0');
			RAM_DI <= (others => '0');
			RAM_WE <= '0';
			CR <= x"00";
			
			PREV_A <= (others => '0');
			CTRL <= CTRL_IDLE;
		else
			case CTRL is
			
			when CTRL_IDLE =>
				RAM_WE <= '0';
				if CE_N = '0' and WR_N = '0' then
					-- CPU Write
					PREV_A <= A;
					CTRL <= CTRL_WAIT;
					case A is
					when "000" =>
						CR <= DI;
					when "010" =>
						RAM_A(7 downto 0) <= DI;
					when "011" =>
						RAM_A(8) <= DI(0);
					when "100" =>
						RAM_WE <= '1';
						RAM_DI <= RAM_DO(8) & DI;
					when "101" =>
						RAM_WE <= '1';
						RAM_DI <= DI(0) & RAM_DO(7 downto 0);
						CTRL <= CTRL_INCR;
					when others => null;
					end case;
					
				elsif CE_N = '0' and RD_N = '0' then
					-- CPU Read
					PREV_A <= A;
					CTRL <= CTRL_WAIT;
					DO_R <= x"FF";
					case A is
					when "100" =>
						DO_R <= RAM_DO(7 downto 0);
					when "101" =>
						DO_R <= "1111111" & RAM_DO(8);
						CTRL <= CTRL_INCR;
					when others => null;
					end case;
				end if;
			
			when CTRL_INCR =>
				RAM_WE <= '0';
				RAM_A <= RAM_A + 1;
				CTRL <= CTRL_WAIT;
			
			when CTRL_WAIT =>
				RAM_WE <= '0';
				-- Wait for the CPU to "release" the VCE.
				-- I don't know what happens in the case of an address change
				-- however it can be achieved only with addresses read/write cycles,
				-- so it seems unlikely. The case has been handled, though.
				-- HuC6280 Rmw instructions are safe, as there is a "dummy cycle"
				-- between the read cycle and the write cycle.
				CTRL <= CTRL_IDLE;
				if CE_N = '0' and (WR_N = '0' or RD_N = '0') and PREV_A = A then
					CTRL <= CTRL_WAIT;
				end if;
			
			when others => null;
			end case;
		end if;
		end if;
		if SS_RESTORE = '1' then
		RAM_A <= SS_IN(1)(8 downto 0);
		RAM_DI <= SS_IN(1)(17 downto 9);
		RAM_WE <= SS_IN(1)(18);
		DO_R <= SS_IN(1)(26 downto 19);
		CR <= SS_IN(0)(48 downto 41);
		PREV_A <= SS_IN(0)(53 downto 51);
		case SS_IN(0)(50 downto 49) is
			when "01"   => CTRL <= CTRL_WAIT;
			when "10"   => CTRL <= CTRL_INCR;
			when others => CTRL <= CTRL_IDLE;
		end case;
		end if;
	end if;
end process;

-- Video counting, register loading and clock generation
process(CLK, RESET_N)
begin
	if RESET_N = '0' then
		CLKEN_CNT <= (others=>'0');
		H_CNT <= (others=>'0');
		V_CNT <= (others=>'0');
		CLKEN_FF <= '0';
		MULTIRES_FF <= '0';
		BW_R <= '0';
	elsif rising_edge(CLK) then
		if FREEZE = '0' then
		H_CNT <= H_CNT + 1;

		CLKEN_FF <= '0';
		CLKEN_CNT <= CLKEN_CNT + 1;
		if DOTCLOCK = "00" and CLKEN_CNT = "111" and H_CNT < LINE_CLOCKS-2-1 then
			CLKEN_CNT <= (others => '0');
			CLKEN_FF <= '1';
		elsif DOTCLOCK = "01" and CLKEN_CNT = "101" then
			CLKEN_CNT <= (others => '0');
			CLKEN_FF <= '1';				
		elsif DOTCLOCK(1) = '1' and CLKEN_CNT = "011" and H_CNT < LINE_CLOCKS-2-1 then
			CLKEN_CNT <= (others => '0');
			CLKEN_FF <= '1';				
		end if;
		
		if DOTCLOCK = "00" and CLKEN_CNT = "011" then
			CLKEN_FF_F <= '1';
		elsif DOTCLOCK = "01" and CLKEN_CNT = "010" then
			CLKEN_FF_F <= '1';				
		elsif DOTCLOCK(1) = '1' and CLKEN_CNT = "001" then
			CLKEN_FF_F <= '1';				
		end if;

		if H_CNT = LINE_CLOCKS-1 then
			CLKEN_CNT <= (others => '0');
			CLKEN_FF <= '1';				
			H_CNT <= (others => '0');
			V_CNT <= V_CNT + 1;
			if V_CNT >= END_LINE-1 then
				V_CNT <= (others => '0');
				if CR(2) = '1' then			-- artifact bit affects number of lines per field; check at start of field
				  END_LINE <= TOTAL_LINES;
				else
				  END_LINE <= TOTAL_LINES - 1;
				end if;
			end if;
			-- Reload registers
			BW_R <= CR(7);
			DOTCLOCK <= CR(1 downto 0);

			if V_CNT >= TOP_BL_LINES and V_CNT < TOP_BL_LINES + DISP_LINES and DOTCLOCK /= CR(1 downto 0) then 
				MULTIRES_FF <= '1';
			end if;
				
			if V_CNT = TOP_BL_LINES + DISP_LINES then
				MULTIRES <= MULTIRES_FF;
				MULTIRES_FF <= '0';
			end if;
		end if;
		end if;
		if SS_RESTORE = '1' then
		H_CNT <= SS_IN(0)(11 downto 0);
		V_CNT <= SS_IN(0)(21 downto 12);
		END_LINE <= to_integer(unsigned(SS_IN(0)(30 downto 22)));
		CLKEN_CNT <= SS_IN(0)(33 downto 31);
		CLKEN_FF <= SS_IN(0)(34);
		CLKEN_FF_F <= SS_IN(0)(35);
		DOTCLOCK <= SS_IN(0)(37 downto 36);
		BW_R <= SS_IN(0)(38);
		MULTIRES_FF <= SS_IN(0)(39);
		MULTIRES <= SS_IN(0)(40);
		end if;
	end if;
end process;

HSYNC_START_POS <= 8-1 when DOTCLOCK = "00" else 
                   LINE_CLOCKS-6-1 when DOTCLOCK = "01" else 
                   LINE_CLOCKS-26-1;
HSYNC_END_POS   <= 8+464-1 when DOTCLOCK = "00" else 
                   468-6-1 when DOTCLOCK = "01" else 
                   468-26-1;
process( CLK )
begin
	if rising_edge( CLK ) then
		if FREEZE = '0' then
		HSYNC_F_R <= '0';
		HSYNC_R_R <= '0';
		VSYNC_F_R <= '0';
		VSYNC_R_R <= '0';
		if H_CNT = HSYNC_START_POS then HSYNC_F_R <= '1'; end if;
		if H_CNT = HSYNC_START_POS + 1 and DOTCLOCK = "01" then HSYNC_F_R <= '1'; end if;
		if H_CNT = HSYNC_END_POS   then HSYNC_R_R <= '1'; end if;
		if V_CNT = END_LINE-1    and H_CNT = LINE_CLOCKS-1 then VSYNC_F_R <= '1'; end if;
		if V_CNT = VS_LINES-1    and H_CNT = LINE_CLOCKS-1 then VSYNC_R_R <= '1'; end if;
		end if;
		if SS_RESTORE = '1' then
		HSYNC_F_R <= SS_IN(1)(54);
		HSYNC_R_R <= SS_IN(1)(55);
		VSYNC_F_R <= SS_IN(1)(56);
		VSYNC_R_R <= SS_IN(1)(57);
		end if;
	end if;
end process;

process(CLK, RESET_N)
begin
	if RESET_N = '0' then
		CLKEN_FS_CNT <= (others=>'0');
		CLKEN_FS_R <= '0';
	elsif rising_edge(CLK) then
		if FREEZE = '0' then
		CLKEN_FS_R <= '0';
		CLKEN_FS_CNT <= CLKEN_FS_CNT + 1;
		if (MULTIRES = '1' or DOTCLOCK(1) = '1') and CLKEN_FS_CNT = "011" and H_CNT < LINE_CLOCKS-2-1 then
			CLKEN_FS_CNT <= (others => '0');
			CLKEN_FS_R <= '1';				
		elsif DOTCLOCK = "00" and CLKEN_FS_CNT = "111" and H_CNT < LINE_CLOCKS-2-1 then
			CLKEN_FS_CNT <= (others => '0');
			CLKEN_FS_R <= '1';
		elsif DOTCLOCK = "01" and CLKEN_FS_CNT = "101" then
			CLKEN_FS_CNT <= (others => '0');
			CLKEN_FS_R <= '1';				
		end if;

		if H_CNT = LINE_CLOCKS-1 then
			 CLKEN_FS_CNT <= (others => '0');
			 CLKEN_FS_R <= '1';
		end if;
		end if;
		if SS_RESTORE = '1' then
		CLKEN_FS_CNT <= SS_IN(0)(56 downto 54);
		CLKEN_FS_R <= SS_IN(0)(57);
		end if;
	end if;
end process;

-- Sync
process( CLK )
begin
	if rising_edge( CLK ) then
		if FREEZE = '0' then
		if H_CNT = HS_OFF             then HS_N_R <= '0'; end if;
		if H_CNT = HS_OFF + HS_CLOCKS then HS_N_R <= '1'; end if;
		if V_CNT = 0                  then VS_N_R <= '0'; end if;
		if V_CNT = VS_LINES           then VS_N_R <= '1'; end if;
		end if;
		if SS_RESTORE = '1' then
		HS_N_R <= SS_IN(1)(27);
		VS_N_R <= SS_IN(1)(28);
		end if;
	end if;
end process;

-- Blank
process( CLK )
begin
	if rising_edge( CLK ) then
		if FREEZE = '0' then
		if H_CNT = LEFT_BL_CLOCKS               then HBL_FF <= '0'; end if;
		if H_CNT = LEFT_BL_CLOCKS + DISP_CLOCKS then HBL_FF <= '1'; end if;
		if V_CNT = TOP_BL_LINES                 then VBL_FF <= '0'; end if;
		if V_CNT = TOP_BL_LINES + DISP_LINES    then VBL_FF <= '1'; end if;
		end if;
		if SS_RESTORE = '1' then
		HBL_FF <= SS_IN(1)(29);
		VBL_FF <= SS_IN(1)(31);
		end if;
	end if;
end process;

-- Final output
process( CLK )
begin
	if rising_edge( CLK ) then
		if FREEZE = '0' then
		if CLKEN_FF = '1' then

			-- compensate HUC6202 delay
			VBL_FF2 <= VBL_FF;
			HBL_FF2 <= HBL_FF;

			VBL_R <= VBL_FF2;
			HBL_R <= HBL_FF2;

			if BORDER = '1' and BORDER_EN = '0' then
				G_R <= (others => '0');
				R_R <= (others => '0');
				B_R <= (others => '0');
				G_FF <= (others => '0');
				R_FF <= (others => '0');
				B_FF <= (others => '0');
				CE_N_FF  <= '1';

			elsif (CE_N = '0') then
				G_R <= G_FF;
				R_R <= R_FF;
				B_R <= B_FF;
				CE_N_FF <= '0';
			elsif (CE_N_FF = '0') then
				G_R <= G_FF;
				R_R <= R_FF;
				B_R <= B_FF;
				CE_N_FF <= '1';

			elsif (GRID(0) = '1' and GRID_EN(0) = '1') or (GRID(1) = '1' and GRID_EN(1) = '1') then
				G_R <= (others => '1');
				R_R <= (others => '1');
				B_R <= (others => '1');
			else
				G_R <= COLOR(8 downto 6);
				R_R <= COLOR(5 downto 3);
				B_R <= COLOR(2 downto 0);
				G_FF <= COLOR(8 downto 6);
				R_FF <= COLOR(5 downto 3);
				B_FF <= COLOR(2 downto 0);
			end if;
		end if;
		end if;
		if SS_RESTORE = '1' then
		HBL_FF2 <= SS_IN(1)(30);
		VBL_FF2 <= SS_IN(1)(32);
		HBL_R <= SS_IN(1)(33);
		VBL_R <= SS_IN(1)(34);
		R_FF <= SS_IN(1)(37 downto 35);
		G_FF <= SS_IN(1)(40 downto 38);
		B_FF <= SS_IN(1)(43 downto 41);
		CE_N_FF <= SS_IN(1)(44);
		R_R <= SS_IN(1)(47 downto 45);
		G_R <= SS_IN(1)(50 downto 48);
		B_R <= SS_IN(1)(53 downto 51);
		end if;
	end if;
end process;

CLKEN <= CLKEN_FF;
CLKEN_F <= CLKEN_FF_F;

HSYNC_F <= HSYNC_F_R;
HSYNC_R <= HSYNC_R_R;
VSYNC_F <= VSYNC_F_R;
VSYNC_R <= VSYNC_R_R;
CLKEN_FS <= CLKEN_FS_R;
HS_N <= HS_N_R;
VS_N <= VS_N_R;
HBL <= HBL_R;
VBL <= VBL_R;
R <= R_R;
G <= G_R;
B <= B_R;
DO <= DO_R;
BW <= BW_R;

-- savestates
SS_CTRL <= "01" when CTRL = CTRL_WAIT else "10" when CTRL = CTRL_INCR else "00";

SS_OUT(0) <= "000000" & CLKEN_FS_R & CLKEN_FS_CNT & PREV_A & SS_CTRL & CR & MULTIRES & MULTIRES_FF & BW_R & DOTCLOCK &
             CLKEN_FF_F & CLKEN_FF & CLKEN_CNT & std_logic_vector(to_unsigned(END_LINE, 9)) & V_CNT & H_CNT;
SS_OUT(1) <= "000000" & VSYNC_R_R & VSYNC_F_R & HSYNC_R_R & HSYNC_F_R & B_R & G_R & R_R & CE_N_FF & B_FF & G_FF & R_FF &
             VBL_R & HBL_R & VBL_FF2 & VBL_FF & HBL_FF2 & HBL_FF & VS_N_R & HS_N_R & DO_R & RAM_WE & RAM_DI & RAM_A;

gSS: for i in 0 to 1 generate
	iREG : entity work.eReg_SavestateV generic map (24 + i, (others => '0'))
	port map (CLK, SS_BUS_Din, SS_BUS_Adr, SS_BUS_wren, SS_BUS_rst, SS_DO(i), SS_OUT(i), SS_IN(i));
end generate;

SS_BUS_Dout <= SS_DO(0) or SS_DO(1);

SS_IDLE <= not CLKEN_FF and not RAM_WE;

end rtl;
