import os
here = os.path.dirname(os.path.abspath(__file__))
s=open(os.path.join(here, '..', 'rtl', 'pce_top.vhd')).read()
s=s.replace("""		SS_MEM_RD	: out std_logic_vector(7 downto 0)
	);
end pce_top;""","""		SS_MEM_RD	: out std_logic_vector(7 downto 0);
		DBG_FREEZE : out std_logic; DBG_CPU_CE : out std_logic; DBG_CPU_WR_N : out std_logic; DBG_CPU_RD_N : out std_logic;
		DBG_CPU_A : out std_logic_vector(20 downto 0); DBG_CPU_DO : out std_logic_vector(7 downto 0); DBG_CPU_DI : out std_logic_vector(7 downto 0)
	);
end pce_top;""")
s=s.replace("""PSG_SR <= signed(PCE_SR(23 downto 8));""","""DBG_FREEZE <= FREEZE; DBG_CPU_CE <= CPU_CE; DBG_CPU_WR_N <= CPU_WR_N; DBG_CPU_RD_N <= CPU_RD_N;
DBG_CPU_A <= CPU_A; DBG_CPU_DO <= CPU_DO; DBG_CPU_DI <= GENIE_DI;
PSG_SR <= signed(PCE_SR(23 downto 8));""")
open(os.path.join(here, 'work', 'pce_top_sim.vhd'),'w').write(s)
