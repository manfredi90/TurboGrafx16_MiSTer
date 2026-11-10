library ieee;
use ieee.std_logic_1164.all;

entity ARCADE_CARD is
	port(
		CLK     : in  std_logic;
		RST_N   : in  std_logic;
		EN      : in  std_logic;
		WR_N    : in  std_logic;
		RD_N    : in  std_logic;
		A       : in  std_logic_vector(20 downto 0);
		DI      : in  std_logic_vector(7 downto 0);
		DO      : out std_logic_vector(7 downto 0);
		SEL_N   : out std_logic;
		RAM_CS_N: out std_logic;
		RAM_A   : out std_logic_vector(20 downto 0)
	);
end entity;
architecture sim of ARCADE_CARD is
begin
	DO <= x"FF"; SEL_N <= '1'; RAM_CS_N <= '1'; RAM_A <= (others => '0');
end architecture;

library ieee;
use ieee.std_logic_1164.all;
entity CODES is
	generic(
		ADDR_WIDTH  : in integer := 16;
		DATA_WIDTH  : in integer := 8
	);
	port(
		clk         : in  std_logic;
		reset       : in  std_logic;
		enable      : in  std_logic;
		addr_in     : in  std_logic_vector(20 downto 0);
		data_in     : in  std_logic_vector(7 downto 0);
		code        : in  std_logic_vector(128 downto 0);
		available   : out std_logic;
		genie_ovr   : out boolean;
		genie_data  : out std_logic_vector(7 downto 0)
	);
end entity;
architecture sim of CODES is
begin
	available <= '0'; genie_ovr <= false; genie_data <= x"00";
end architecture;
