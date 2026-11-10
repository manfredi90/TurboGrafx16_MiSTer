library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity altsyncram is
	generic (
		address_aclr_a : string := "NONE"; address_aclr_b : string := "NONE";
		address_reg_b : string := "CLOCK1"; byte_size : natural := 8;
		clock_enable_input_a : string := "NORMAL"; clock_enable_input_b : string := "NORMAL";
		clock_enable_output_a : string := "NORMAL"; clock_enable_output_b : string := "NORMAL";
		indata_reg_b : string := "CLOCK1"; init_file : string := "UNUSED";
		intended_device_family : string := "Cyclone V"; lpm_hint : string := "UNUSED";
		lpm_type : string := "altsyncram"; numwords_a : natural := 0; numwords_b : natural := 0;
		operation_mode : string := "BIDIR_DUAL_PORT"; outdata_aclr_a : string := "NONE";
		outdata_aclr_b : string := "NONE"; outdata_reg_a : string := "UNREGISTERED";
		outdata_reg_b : string := "UNREGISTERED"; power_up_uninitialized : string := "FALSE";
		read_during_write_mode_mixed_ports : string := "DONT_CARE";
		read_during_write_mode_port_a : string := "NEW_DATA_NO_NBE_READ";
		read_during_write_mode_port_b : string := "NEW_DATA_NO_NBE_READ";
		widthad_a : natural; widthad_b : natural := 1; width_a : natural; width_b : natural := 1;
		width_byteena_a : natural := 1; width_byteena_b : natural := 1;
		wrcontrol_wraddress_reg_b : string := "CLOCK1"
	);
	port (
		address_a : in std_logic_vector(widthad_a-1 downto 0);
		address_b : in std_logic_vector(widthad_b-1 downto 0) := (others => '1');
		clock0 : in std_logic := '1'; clock1 : in std_logic := '1';
		clocken0 : in std_logic := '1'; clocken1 : in std_logic := '1';
		data_a : in std_logic_vector(width_a-1 downto 0) := (others => '1');
		data_b : in std_logic_vector(width_b-1 downto 0) := (others => '1');
		wren_a : in std_logic := '0'; wren_b : in std_logic := '0';
		rden_a : in std_logic := '1'; rden_b : in std_logic := '1';
		byteena_a : in std_logic_vector(width_byteena_a-1 downto 0) := (others => '1');
		q_a : out std_logic_vector(width_a-1 downto 0);
		q_b : out std_logic_vector(width_b-1 downto 0)
	);
end entity;
architecture sim of altsyncram is
	type mem_t is array(0 to 2**widthad_a-1) of std_logic_vector(width_a-1 downto 0);
	shared variable mem : mem_t := (others => (others => '0'));
begin
	process(clock0) begin
		if rising_edge(clock0) and clocken0 = '1' then
			if wren_a = '1' then mem(to_integer(unsigned(address_a))) := data_a; end if;
			q_a <= mem(to_integer(unsigned(address_a)));
		end if;
	end process;
	process(clock1) begin
		if rising_edge(clock1) and clocken1 = '1' then
			if wren_b = '1' then mem(to_integer(unsigned(address_b))) := data_b; end if;
			q_b <= mem(to_integer(unsigned(address_b)));
		end if;
	end process;
end architecture;
