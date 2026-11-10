library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
library work;
use work.pBus_savestates.all;

entity tb is
	generic (
		MODE      : integer := 0;        -- 0: plain run, 1: save at F_EVENT, 2: load at F_EVENT
		ROMFILE   : string  := "rom/sstest.pce";
		F_EVENT   : integer := 6;
		F_RUN     : integer := 6;        -- frames after the event
		LOGFILE   : string  := "a.log";
		STATEFILE : string  := "state.txt"
	);
end entity;

architecture sim of tb is
	signal clk        : std_logic := '0';
	signal reset      : std_logic := '1';
	signal cold       : std_logic := '1';

	signal ROM_RD, ROM_CLKEN : std_logic;
	signal ROM_A      : std_logic_vector(21 downto 0);
	signal ROM_DO     : std_logic_vector(7 downto 0) := x"FF";
	type rom_t is array(0 to 8191) of std_logic_vector(7 downto 0);
	signal rom        : rom_t;

	signal VIDEO_R, VIDEO_G, VIDEO_B : std_logic_vector(2 downto 0);
	signal VIDEO_CE, VIDEO_CE_FS, VIDEO_VS, VIDEO_HS, VIDEO_HBL, VIDEO_VBL, VIDEO_BW : std_logic;
	signal PSG_SL, PSG_SR, CDDA_SL, CDDA_SR, ADPCM_S : signed(15 downto 0);
	signal JOY_OUT    : std_logic_vector(1 downto 0);

	-- savestates
	signal ss_freeze_req, ss_paused, ss_restore, ss_refetch : std_logic := '0';
	signal bus_din, bus_dout  : std_logic_vector(63 downto 0);
	signal bus_adr  : std_logic_vector(9 downto 0);
	signal bus_wren, bus_rst : std_logic;
	signal mem_addr : std_logic_vector(24 downto 0);
	signal mem_type : unsigned(2 downto 0);
	signal mem_we   : std_logic;
	signal mem_wd, mem_rd : std_logic_vector(7 downto 0);
	signal saving, loading, sleep, busy, load_done : std_logic;
	signal ddr_din, ddr_dout : std_logic_vector(63 downto 0);
	signal ddr_adr  : std_logic_vector(25 downto 0);
	signal ddr_be   : std_logic_vector(7 downto 0);
	signal ddr_rnw, ddr_ena, ddr_done : std_logic := '0';
	signal req_save, req_load : std_logic := '0';
	signal hold     : integer range 0 to 255 := 0;

	type ddr_t is array(0 to 16#7FFF#) of std_logic_vector(63 downto 0);
	shared variable ddr : ddr_t;

	signal frame      : integer := 0;
	signal coretime   : integer := 0;
	signal logging    : boolean := (MODE /= 2);
	signal event_done : boolean := false;
	signal t_event    : integer := 0;
	signal stop_frame : integer := 1000000;
	signal freeze, cpu_ce, cpu_wr_n, cpu_rd_n : std_logic;
	signal cpu_a : std_logic_vector(20 downto 0);
	signal cpu_do, cpu_di : std_logic_vector(7 downto 0);
begin

	clk <= not clk after 5 ns;

	process
		type cfile is file of character;
		file f : cfile open read_mode is ROMFILE;
		variable c : character;
		variable i : integer := 0;
	begin
		while not endfile(f) and i < 8192 loop
			read(f, c);
			rom(i) <= std_logic_vector(to_unsigned(character'pos(c), 8));
			i := i + 1;
		end loop;
		wait for 100 ns;
		wait until rising_edge(clk);
		for n in 0 to 40000 loop
			wait until rising_edge(clk);
		end loop;
		cold <= '0';
		for n in 0 to 100 loop
			wait until rising_edge(clk);
		end loop;
		reset <= '0';
		wait;
	end process;

	process(clk) begin
		if rising_edge(clk) then
			if ROM_CLKEN = '1' and ROM_RD = '1' then
				ROM_DO <= rom(to_integer(unsigned(ROM_A(12 downto 0))));
			end if;
		end if;
	end process;

	dut : entity work.pce_top
	generic map (LITE => 0)
	port map (
		RESET => reset, COLD_RESET => cold, CLK => clk,
		ROM_RD => ROM_RD, ROM_RDY => '1', ROM_A => ROM_A, ROM_DO => ROM_DO, ROM_SZ => x"002", ROM_POP => '0', ROM_CLKEN => ROM_CLKEN,
		BRM_A => open, BRM_DI => open, BRM_DO => x"FF", BRM_WE => open,
		GG_EN => '0', GG_CODE => (others => '0'), GG_RESET => '0', GG_AVAIL => open,
		SP64 => '0', SGX => '0',
		JOY_OUT => JOY_OUT, JOY_IN => "1111",
		CD_EN => '0', CD_RAM_A => open, CD_RAM_DO => open, CD_RAM_DI => x"FF", CD_RAM_RD => open, CD_RAM_WR => open, AC_EN => '0',
		CD_STAT => x"00", CD_MSG => x"00", CD_STAT_GET => '0', CD_COMM => open, CD_COMM_SEND => open,
		CD_DOUT_REQ => '0', CD_DOUT => open, CD_DOUT_SEND => open, CD_REGION => '0', CD_RESET => open,
		CD_DATA => x"00", CD_DATA_WR => '0', CD_AUDIO_WR => '0', CD_SUBCD_WR => '0', CD_DATA_END => open, CD_DM => '0',
		CDDA_SL => CDDA_SL, CDDA_SR => CDDA_SR, ADPCM_S => ADPCM_S, PSG_SL => PSG_SL, PSG_SR => PSG_SR,
		BG_EN => '1', SPR_EN => '1', GRID_EN => "00", CPU_PAUSE_EN => '0',
		BORDER_EN => '1', ReducedVBL => '0',
		VIDEO_R => VIDEO_R, VIDEO_G => VIDEO_G, VIDEO_B => VIDEO_B, VIDEO_BW => VIDEO_BW,
		VIDEO_CE => VIDEO_CE, VIDEO_CE_FS => VIDEO_CE_FS, VIDEO_VS => VIDEO_VS, VIDEO_HS => VIDEO_HS,
		VIDEO_HBL => VIDEO_HBL, VIDEO_VBL => VIDEO_VBL,
		SS_FREEZE_REQ => ss_freeze_req, SS_PAUSED => ss_paused, SS_RESTORE => ss_restore, SS_REFETCH => ss_refetch,
		SS_BUS_Din => bus_din, SS_BUS_Adr => bus_adr, SS_BUS_wren => bus_wren, SS_BUS_rst => bus_rst, SS_BUS_Dout => bus_dout,
		SS_MEM_ACT => saving or loading, SS_MEM_TYPE => std_logic_vector(mem_type), SS_MEM_ADDR => mem_addr(16 downto 0),
		SS_MEM_WE => mem_we, SS_MEM_WD => mem_wd, SS_MEM_RD => mem_rd,
		DBG_FREEZE => freeze, DBG_CPU_CE => cpu_ce, DBG_CPU_WR_N => cpu_wr_n, DBG_CPU_RD_N => cpu_rd_n,
		DBG_CPU_A => cpu_a, DBG_CPU_DO => cpu_do, DBG_CPU_DI => cpu_di
	);

	ss : entity work.savestates
	port map (
		clk => clk, restore => ss_restore, load_done => load_done, increaseSSHeaderCount => '1',
		save => req_save, load => req_load, savestate_address => "11" & x"800000", savestate_busy => busy,
		paused => ss_paused,
		BUS_Din => bus_din, BUS_Adr => bus_adr, BUS_wren => bus_wren, BUS_rst => bus_rst, BUS_Dout => bus_dout,
		loading_savestate => loading, saving_savestate => saving, sleep_savestate => sleep,
		Save_RAMAddr => mem_addr, Save_RAMRdEn => open, Save_RAMWrEn => mem_we, Save_RAMWriteData => mem_wd,
		Save_RAMReadData => mem_rd, Save_RAMType => mem_type,
		bus_out_Din => ddr_din, bus_out_Dout => ddr_dout, bus_out_Adr => ddr_adr, bus_out_rnw => ddr_rnw,
		bus_out_ena => ddr_ena, bus_out_be => ddr_be, bus_out_done => ddr_done
	);


	-- DDR3 model (one slot)
	process(clk)
		variable idx : integer;
		variable w : std_logic_vector(63 downto 0);
	begin
		if rising_edge(clk) then
			ddr_done <= '0';
			if ddr_ena = '1' then
				idx := to_integer(unsigned(ddr_adr) - 16#3800000#) / 2;
				if ddr_rnw = '1' then
					ddr_dout <= ddr(idx);
				else
					w := ddr(idx);
					for b in 0 to 7 loop
						if ddr_be(b) = '1' then w(b*8+7 downto b*8) := ddr_din(b*8+7 downto b*8); end if;
					end loop;
					ddr(idx) := w;
				end if;
				ddr_done <= '1';
			end if;
		end if;
	end process;

	-- same control as in TurboGrafx16.sv
	process(clk) begin
		if rising_edge(clk) then
			ss_refetch <= '0';
			if load_done = '1' then hold <= 200;
			elsif hold /= 0 then hold <= hold - 1; end if;
			if hold = 150 then ss_refetch <= '1'; end if;
		end if;
	end process;
	ss_freeze_req <= '1' when sleep = '1' or hold /= 0 else '0';

	-- frames, core time, event
	process(clk)
		variable vs_old : std_logic := '0';
		variable sleep_old : std_logic := '0';
		variable hold_old : integer := 0;
		file sf : text;
		variable l : line;
		variable v : std_logic_vector(63 downto 0);
		variable t : integer;
	begin
		if rising_edge(clk) then
			req_save <= '0';
			req_load <= '0';
			if freeze = '0' then
				coretime <= coretime + 1;
			end if;
			if VIDEO_VS = '1' and vs_old = '0' then
				frame <= frame + 1;
				if frame + 1 = F_EVENT and not event_done and MODE /= 0 then
					if MODE = 1 then req_save <= '1'; else req_load <= '1'; end if;
					if MODE = 2 then
						file_open(sf, STATEFILE, read_mode);
						readline(sf, l);
						read(l, t);
						t_event <= t;
						for i in 0 to 16#7FFF# loop
							exit when endfile(sf);
							readline(sf, l);
							hread(l, v);
							ddr(i) := v;
						end loop;
						file_close(sf);
					end if;
					event_done <= true;
				end if;
				if frame + 1 = stop_frame then
					report "done at frame " & integer'image(frame + 1) severity note;
					std.env.finish;
				end if;
				if MODE = 0 and frame + 1 = F_EVENT + F_RUN then
					std.env.finish;
				end if;
			end if;
			vs_old := VIDEO_VS;

			if MODE = 1 and sleep = '0' and sleep_old = '1' then
				-- save finished: write the slot and the core time of the freeze
				file_open(sf, STATEFILE, write_mode);
				write(l, t_event);
				writeline(sf, l);
				for i in 0 to 16#4200# loop
					hwrite(l, ddr(i));
					writeline(sf, l);
				end loop;
				file_close(sf);
				stop_frame <= frame + F_RUN;
				report "saved, header " & to_hstring(ddr(0)) severity note;
			end if;
			if MODE = 1 and freeze = '1' and t_event = 0 and event_done then
				t_event <= coretime;
			end if;
			if MODE = 2 and hold = 0 and hold_old /= 0 then
				logging <= true;
				stop_frame <= frame + F_RUN;
				report "loaded" severity note;
			end if;
			if MODE = 2 and sleep = '0' and sleep_old = '1' and load_done = '0' and hold = 0 then
				report "load rejected" severity failure;
			end if;
			if MODE = 2 and ss_restore = '1' then
				coretime <= t_event;
			end if;
			sleep_old := sleep;
			hold_old := hold;
		end if;
	end process;

	-- trace
	process(clk)
		file lf : text open write_mode is LOGFILE;
		variable l : line;
		variable sl, sr : signed(15 downto 0) := (others => '0');
		variable h : unsigned(31 downto 0) := (others => '0');
		variable vs_old : std_logic := '0';
	begin
		if rising_edge(clk) then
			if logging then
				if cpu_ce = '1' and cpu_wr_n = '0' then
					write(l, string'("W ")); write(l, coretime); write(l, string'(" "));
					hwrite(l, "000" & cpu_a); write(l, string'(" ")); hwrite(l, cpu_do); writeline(lf, l);
				end if;
				if cpu_ce = '1' and cpu_rd_n = '0' then
					write(l, string'("R ")); write(l, coretime); write(l, string'(" "));
					hwrite(l, "000" & cpu_a); write(l, string'(" ")); hwrite(l, cpu_di); writeline(lf, l);
				end if;
				if PSG_SL /= sl or PSG_SR /= sr then
					write(l, string'("A ")); write(l, coretime); write(l, string'(" "));
					hwrite(l, std_logic_vector(PSG_SL)); write(l, string'(" ")); hwrite(l, std_logic_vector(PSG_SR)); writeline(lf, l);
				end if;
				if VIDEO_CE_FS = '1' then
					h := (h(26 downto 0) & h(31 downto 27)) xor resize(unsigned(std_logic_vector'(VIDEO_R & VIDEO_G & VIDEO_B)), 32) xor (h(31 downto 16) * x"0007");
				end if;
				if VIDEO_VS = '1' and vs_old = '0' then
					write(l, string'("F ")); write(l, coretime); write(l, string'(" ")); hwrite(l, std_logic_vector(h)); writeline(lf, l);
					h := (others => '0');
				end if;
			end if;
			sl := PSG_SL; sr := PSG_SR;
			vs_old := VIDEO_VS;
		end if;
	end process;

end architecture;
