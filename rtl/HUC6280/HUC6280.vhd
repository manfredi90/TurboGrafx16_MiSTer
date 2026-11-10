library IEEE;
use IEEE.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.HUC6280_PKG.all;
use work.pBus_savestates.all;

entity HUC6280 is
	port( 
		CLK		: in std_logic;
		RST_N		: in std_logic;
		WAIT_N	: in std_logic;
		  
		A			: out std_logic_vector(20 downto 0);
		DI			: in std_logic_vector(7 downto 0);
		DO			: out std_logic_vector(7 downto 0);
		WR_N  	: out std_logic;
		RD_N  	: out std_logic;
		RDY		: in std_logic;
		NMI_N		: in std_logic;  
		IRQ1_N	: in std_logic;
		IRQ2_N	: in std_logic;
		
		CE			: out std_logic;
		CEK_N		: out std_logic;
		CE7_N		: out std_logic;
		CER_N		: out std_logic;
		PRE_RD	: out std_logic; -- for MiSTer sdram/ddram read
		PRE_WR	: out std_logic;
		
		HSM		: out std_logic;
		
		O			: out std_logic_vector(7 downto 0);
		K			: in std_logic_vector(7 downto 0);
		
		VDCNUM	: in std_logic;
		
		AUD_LDATA: out std_logic_vector(23 downto 0);
		AUD_RDATA: out std_logic_vector(23 downto 0);

		-- savestates
		FREEZE      : in  std_logic := '0';
		SS_IDLE     : out std_logic;
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
end HUC6280;

architecture rtl of HUC6280 is

	signal CPU_CE 			: std_logic;
	signal CPU_CER 		: std_logic;
	signal IO_CE 			: std_logic;
	signal EN 				: std_logic;
	
	signal CPU_DI 			: std_logic_vector(7 downto 0);
	signal CPU_DO 			: std_logic_vector(7 downto 0);
	signal CPU_A 			: std_logic_vector(20 downto 0);
	signal CPU_WE_N 		: std_logic;
	signal CPU_CS 			: std_logic;
	signal CPU_MCYCLE		: std_logic;
	signal CPU_IRQ1_N 	: std_logic;
	signal CPU_IRQ2_N 	: std_logic;
	signal CPU_IRQT_N 	: std_logic;
	signal CPU_RDY 		: std_logic;
	
	signal CPU_CLK_CNT 	: unsigned(4 downto 0);
	signal IO_CLK_CNT 	: unsigned(2 downto 0);
	signal VDC_SEL_OLD	: std_logic;
	
	--IO
	signal IO_BUF 			: std_logic_vector(7 downto 0);
	signal RAM_SEL 		: std_logic;
	signal VDC_SEL 		: std_logic;
	signal VCE_SEL 		: std_logic;
	signal IOP_SEL 		: std_logic;
	signal PSG_SEL 		: std_logic;
	signal TMR_SEL 		: std_logic;
	signal INT_SEL 		: std_logic;
	signal IO_SEL 			: std_logic;
	
	signal INT_MASK_PRE	: std_logic_vector(2 downto 0);
	signal INT_MASK 		: std_logic_vector(2 downto 0);
	signal TMR_PRE_CNT 	: unsigned(9 downto 0);
	signal TMR_VALUE 		: std_logic_vector(6 downto 0); 
	signal TMR_LATCH 		: std_logic_vector(6 downto 0);
	signal TMR_EN 			: std_logic;
	signal TMR_RELOAD		: std_logic; 
	signal TMR_IRQ 		: std_logic;
	signal TMR_IRQ_ACK 	: std_logic;

	-- savestates
	type ss_regs_t is array(1 to 5) of std_logic_vector(63 downto 0);
	signal SS_IN, SS_OUT	: ss_regs_t;
	type ss_dout_t is array(0 to 5) of std_logic_vector(63 downto 0);
	signal SS_DO			: ss_dout_t;
	signal WR_N_R, RD_N_R : std_logic;
	signal O_R : std_logic_vector(7 downto 0);

begin

	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			CPU_CLK_CNT <= (others=>'0');
			CPU_CE <= '0';
			CPU_CER <= '0';
			IO_CLK_CNT <= (others=>'0');
			IO_CE <= '0';
		elsif rising_edge(CLK) then
			if FREEZE = '0' then
			CPU_CE <= '0';
			if (CPU_CLK_CNT = 5 and CPU_CS = '1') or (CPU_CLK_CNT = 23 and CPU_CS = '0') then
				if WAIT_N = '1' then
					CPU_CLK_CNT <= (others=>'0');
					CPU_CE <= '1';
				end if; 
			else
				CPU_CLK_CNT <= CPU_CLK_CNT + 1;
			end if; 
			
			CPU_CER <= '0';
			if CPU_CLK_CNT = 1 then
				CPU_CER <= '1';
			end if; 
			
			IO_CE <= '0';
			IO_CLK_CNT <= IO_CLK_CNT + 1;
			if IO_CLK_CNT = 5 then
				IO_CLK_CNT <= (others=>'0');
				IO_CE <= '1';
			end if; 
			end if;
			if SS_RESTORE = '1' then
				CPU_CLK_CNT <= unsigned(SS_IN(5)(4 downto 0));
				IO_CLK_CNT <= unsigned(SS_IN(5)(7 downto 5));
				CPU_CE <= SS_IN(5)(61);
				CPU_CER <= SS_IN(5)(62);
				IO_CE <= SS_IN(5)(63);
			end if;
		end if;
	end process;
	
	CE <= CPU_CE and CPU_RDY;
	
	EN <= CPU_CE and CPU_RDY;
	
	
	CORE : entity work.HUC6280_CPU
	port map (
		CLK 		=> CLK,
		RST_N 	=> RST_N,
		CE 		=> CPU_CE,
		
		A_OUT 	=> CPU_A,
		DI 		=> CPU_DI,
		DO 		=> CPU_DO,
		WE_N 		=> CPU_WE_N,
		RDY 		=> CPU_RDY,
		IRQ1_N 	=> CPU_IRQ1_N,
		IRQ2_N 	=> CPU_IRQ2_N,
		IRQT_N 	=> CPU_IRQT_N,
		NMI_N 	=> NMI_N,
		MCYCLE	=> CPU_MCYCLE,
		CS 		=> CPU_CS,
		VDCNUM   => VDCNUM,

		SS_RESTORE => SS_RESTORE,
		SS_IN1   => SS_IN(1),
		SS_IN2   => SS_IN(2),
		SS_IN3   => SS_IN(3),
		SS_IN4   => SS_IN(4),
		SS_OUT1  => SS_OUT(1),
		SS_OUT2  => SS_OUT(2),
		SS_OUT3  => SS_OUT(3),
		SS_OUT4  => SS_OUT(4)
	);
	
	CPU_IRQ1_N <= IRQ1_N or INT_MASK(1);
	CPU_IRQ2_N <= IRQ2_N or INT_MASK(0);
	CPU_IRQT_N <= not TMR_IRQ or INT_MASK(2);
	
	RAM_SEL <= '1' when CPU_A(20 downto 15) = "111110" else '0'; -- RAM : Page $F8 - $FB
	VDC_SEL <= '1' when CPU_A(20 downto 13) = x"FF" and CPU_A(12 downto 10) = "000" else '0'; -- VDC : $0000 - $03FF
	VCE_SEL <= '1' when CPU_A(20 downto 13) = x"FF" and CPU_A(12 downto 10) = "001" else '0'; -- VCE : $0400 - $07FF
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			WR_N_R <= '1';
			RD_N_R <= '1';
			CPU_RDY <= '1';
			VDC_SEL_OLD <= '0';
		elsif rising_edge(CLK) then
			if FREEZE = '0' then
			if CPU_CER = '1' then
				if CPU_MCYCLE = '1' then
					WR_N_R <= CPU_WE_N;
					RD_N_R <= not CPU_WE_N;
				end if; 
				
				VDC_SEL_OLD <= VDC_SEL or VCE_SEL;
				if (VDC_SEL = '1' or VCE_SEL = '1') and VDC_SEL_OLD = '0' then
					CPU_RDY <= '0';
				end if;
			elsif CPU_CE = '1' then
				if CPU_RDY = '1' then
					WR_N_R <= '1';
					RD_N_R <= '1';
				end if; 
				CPU_RDY <= RDY;
			end if; 
			end if;
			if SS_RESTORE = '1' then
				CPU_RDY <= SS_IN(5)(8);
				WR_N_R <= SS_IN(5)(9);
				RD_N_R <= SS_IN(5)(10);
				VDC_SEL_OLD <= SS_IN(5)(11);
			end if;
		end if;
	end process;
	
	PRE_RD <= CPU_WE_N and CPU_MCYCLE and RST_N;
	PRE_WR <= not CPU_WE_N and CPU_MCYCLE and RST_N;
	
	WR_N <= WR_N_R;
	RD_N <= RD_N_R;
	A <= CPU_A;
	DO <= CPU_DO;
	CER_N <= not RAM_SEL;
	CE7_N <= not VDC_SEL;
	CEK_N <= not VCE_SEL;
	HSM <= CPU_CS;
	
	
	
	--KO port
	IOP_SEL <= '1' when CPU_A(20 downto 13) = x"FF" and CPU_A(12 downto 10) = "100" else '0'; -- IOP : $1000 - $13FF
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			O_R <= (others=>'0');
		elsif rising_edge(CLK) then
			if EN = '1' then
				if IOP_SEL = '1' and CPU_WE_N = '0' then
					O_R <= CPU_DO;
				end if; 
			end if; 
			if SS_RESTORE = '1' then
				O_R <= SS_IN(5)(19 downto 12);
			end if;
		end if;
	end process;
	O <= O_R;
	
	--Interrupts register
	INT_SEL <= '1' when CPU_A(20 downto 13) = x"FF" and CPU_A(12 downto 10) = "101" else '0'; -- INT : $1400 - $17FF
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			INT_MASK_PRE <= (others=>'0');
			TMR_IRQ_ACK <= '0';
		elsif rising_edge(CLK) then
			if FREEZE = '0' then
			TMR_IRQ_ACK <= '0';
			
			if CPU_CE = '1' then
				INT_MASK <= INT_MASK_PRE;	-- Delay interrupt mask usage until 1 cycle after it is updated
			end if;

			if INT_SEL = '1' and CPU_CER = '1' then 
				if CPU_WE_N = '0' then
					case CPU_A(1 downto 0) is
						when "10" =>
							INT_MASK_PRE <= CPU_DO(2 downto 0);
						when "11" =>
							TMR_IRQ_ACK <= '1';
						when others => null;
					end case;
				end if; 
			end if; 
			end if;
			if SS_RESTORE = '1' then
				INT_MASK_PRE <= SS_IN(5)(22 downto 20);
				INT_MASK <= SS_IN(5)(25 downto 23);
				TMR_IRQ_ACK <= '0';
			end if;
		end if;
	end process;


	-- Timer
	TMR_SEL <= '1' when CPU_A(20 downto 13) = x"FF" and CPU_A(12 downto 10) = "011" else '0'; -- TMR : $0C00 - $0FFF
	process( CLK, RST_N )
	begin
		if RST_N = '0' then
			TMR_VALUE <= (others => '0');			
			TMR_PRE_CNT <= (others => '1'); 
			TMR_LATCH <= (others => '0');
			TMR_EN <= '0';
			TMR_RELOAD <= '0'; 
			TMR_IRQ <= '0';
		elsif rising_edge(CLK) then
			if FREEZE = '0' then
			if TMR_SEL = '1' and CPU_WE_N = '0' and CPU_CER = '1' then
				if CPU_A(0) = '0' then
					-- Timer latch
					TMR_LATCH <= CPU_DO(6 downto 0);
				else
					-- Timer enable
					TMR_EN <= CPU_DO(0);
					if TMR_EN = '0' and CPU_DO(0) = '1' then
						TMR_VALUE <= TMR_LATCH;
						TMR_PRE_CNT <= (others => '1'); 
					end if;
				end if;	
			end if; 
			
			if TMR_IRQ_ACK = '1' then
				TMR_IRQ <= '0';
			end if;
			
			if IO_CE = '1' then
				TMR_RELOAD <= '0';
				if TMR_EN = '1' then
					TMR_PRE_CNT <= TMR_PRE_CNT - 1;
					if TMR_PRE_CNT = 0 then
						TMR_VALUE <= std_logic_vector( unsigned(TMR_VALUE) - 1 );
						if TMR_VALUE = "0000000" then
							TMR_RELOAD <= '1';
							TMR_IRQ <= '1';
						end if;
					end if;
				end if; 
				
				if TMR_RELOAD = '1' then
					TMR_VALUE <= TMR_LATCH;
				end if; 
			end if;
			end if;
			if SS_RESTORE = '1' then
				TMR_VALUE <= SS_IN(5)(32 downto 26);
				TMR_PRE_CNT <= unsigned(SS_IN(5)(42 downto 33));
				TMR_LATCH <= SS_IN(5)(49 downto 43);
				TMR_EN <= SS_IN(5)(50);
				TMR_RELOAD <= SS_IN(5)(51);
				TMR_IRQ <= SS_IN(5)(52);
			end if;
		end if;
	end process;
	
	-- PSG
	PSG_SEL <= '1' when CPU_A(20 downto 13) = x"FF" and CPU_A(12 downto 10) = "010" else '0'; -- PSG : $0800 - $0BFF
	PSG : entity work.psg port map (
		CLK		=> CLK,
		CLKEN		=> IO_CE,	-- 7.16 Mhz clock
		RESET_N	=> RST_N,
		
		DI			=> CPU_DO,
		A			=> CPU_A(3 downto 0),
		WE			=> not CPU_WE_N and EN and PSG_SEL,
		
		DAC_LATCH=> '1',
		LDATA		=> AUD_LDATA,
		RDATA		=> AUD_RDATA,

		FREEZE      => FREEZE,
		SS_RESTORE  => SS_RESTORE,
		SS_BUS_Din  => SS_BUS_Din,
		SS_BUS_Adr  => SS_BUS_Adr,
		SS_BUS_wren => SS_BUS_wren,
		SS_BUS_rst  => SS_BUS_rst,
		SS_BUS_Dout => SS_DO(0),
		SS_WAVE_A   => SS_WAVE_A,
		SS_WAVE_D   => SS_WAVE_D,
		SS_WAVE_WE  => SS_WAVE_WE,
		SS_WAVE_Q   => SS_WAVE_Q
	);
		
	IO_SEL <= IOP_SEL or INT_SEL or TMR_SEL or PSG_SEL;
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			IO_BUF <= (others=>'1');
		elsif rising_edge(CLK) then
			if EN = '1' then
				if IO_SEL = '1' then 
					if CPU_WE_N = '0' then
						IO_BUF <= CPU_DO;
					else
						IO_BUF <= CPU_DI;
					end if; 
				end if; 
			end if; 
			if SS_RESTORE = '1' then
				IO_BUF <= SS_IN(5)(60 downto 53);
			end if;
		end if;
	end process;
	
	process(CLK)
	begin
		if rising_edge(CLK) then
			if IO_SEL = '0' then
				CPU_DI <= DI;
			elsif PSG_SEL = '1' then
				CPU_DI <= x"00";
			elsif IOP_SEL = '1' then
				CPU_DI <= K;
			elsif INT_SEL = '1' then
				case CPU_A(1 downto 0) is
					when "10" =>
						CPU_DI <= IO_BUF(7 downto 3) & INT_MASK;
					when "11" =>
						CPU_DI <= IO_BUF(7 downto 3) & TMR_IRQ & not IRQ1_N & not IRQ2_N;
					when others =>
						CPU_DI <= IO_BUF;
				end case;
			elsif TMR_SEL = '1' then
				CPU_DI <= IO_BUF(7) & TMR_VALUE;
			else
				CPU_DI <= IO_BUF;
			end if;
		end if;
	end process;


	-- savestates
	SS_OUT(5) <= IO_CE & CPU_CER & CPU_CE & IO_BUF & TMR_IRQ & TMR_RELOAD & TMR_EN & TMR_LATCH & std_logic_vector(TMR_PRE_CNT) & TMR_VALUE &
	             INT_MASK & INT_MASK_PRE & O_R & VDC_SEL_OLD & RD_N_R & WR_N_R & CPU_RDY & std_logic_vector(IO_CLK_CNT) & std_logic_vector(CPU_CLK_CNT);

	SS_IDLE <= not CPU_CE and not CPU_CER and not TMR_IRQ_ACK;

	gSS: for i in 1 to 5 generate
		iREG : entity work.eReg_SavestateV generic map (i, (others => '0'))
		port map (CLK, SS_BUS_Din, SS_BUS_Adr, SS_BUS_wren, SS_BUS_rst, SS_DO(i), SS_OUT(i), SS_IN(i));
	end generate;

	SS_BUS_Dout <= SS_DO(0) or SS_DO(1) or SS_DO(2) or SS_DO(3) or SS_DO(4) or SS_DO(5);

end rtl;
	