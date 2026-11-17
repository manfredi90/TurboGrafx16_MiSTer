LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;

ENTITY CEGen IS
	PORT
	(
		CLK       : in  STD_LOGIC;
		RST_N     : in  STD_LOGIC;

		IN_CLK    : in  integer;
		OUT_CLK   : in  integer;

		CE        : out STD_LOGIC;

		FREEZE    : in  STD_LOGIC := '0';
		SS_RESTORE: in  STD_LOGIC := '0';
		SS_IN     : in  STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
		SS_OUT    : out STD_LOGIC_VECTOR(31 downto 0)
	);
END CEGen;

ARCHITECTURE SYN OF CEGen IS
	signal SUM  : integer range 0 to 2**30-1;
	signal CE_R : std_logic;
BEGIN
	process( RST_N, CLK )
	variable CLK_SUM : integer;
	begin
		if RST_N = '0' then
			SUM <= 0;
			CE_R <= '0';
		elsif rising_edge(CLK) then
			if FREEZE = '0' then
				CE_R <= '0';
				CLK_SUM := SUM + OUT_CLK;
				if CLK_SUM >= IN_CLK then
					CLK_SUM := CLK_SUM - IN_CLK;
					CE_R <= '1';
				end if;
				SUM <= CLK_SUM;
			end if;
			if SS_RESTORE = '1' then
				SUM <= to_integer(unsigned(SS_IN(29 downto 0)));
				CE_R <= SS_IN(31);
			end if;
		end if;
	end process;

	CE <= CE_R;
	SS_OUT <= CE_R & '0' & std_logic_vector(to_unsigned(SUM, 30));
END SYN;
