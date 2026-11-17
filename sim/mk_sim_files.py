# Builds the simulation copies of the files that GHDL cannot take as they are.
import re, os
here = os.path.dirname(os.path.abspath(__file__))
R = os.path.join(here, '..', 'rtl')
out = []
for n in ['CDDA_FIFO', 'CDSUBC_FIFO', 'SCSI_FIFO']:
    s = open(os.path.join(R, 'cd', n + '.vhd')).read()
    ent = re.search(r'(ENTITY\s+' + n + r'\s+IS.*?END\s+' + n + r'\s*;)', s, re.S | re.I).group(1)
    body = []
    for p in re.findall(r'^\s*(\w+)\s*:\s*OUT\s+(STD_LOGIC_VECTOR\s*\([^)]*\)|STD_LOGIC)', ent, re.M | re.I):
        if 'VECTOR' in p[1].upper(): body.append("\t%s <= (others => '0');" % p[0])
        elif 'empty' in p[0].lower(): body.append("\t%s <= '1';" % p[0])
        else: body.append("\t%s <= '0';" % p[0])
    out.append('library ieee;\nuse ieee.std_logic_1164.all;\n' + ent + '\narchitecture sim of ' + n + ' is\nbegin\n' + '\n'.join(body) + '\nend architecture;\n')
# the SCSI FIFO works, for the CD test
out[2] = '''library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
ENTITY SCSI_FIFO IS
	PORT (aclr : IN STD_LOGIC := '0'; data : IN STD_LOGIC_VECTOR (7 DOWNTO 0); rdclk : IN STD_LOGIC; rdreq : IN STD_LOGIC;
	      wrclk : IN STD_LOGIC; wrreq : IN STD_LOGIC; q : OUT STD_LOGIC_VECTOR (7 DOWNTO 0); rdempty : OUT STD_LOGIC; wrfull : OUT STD_LOGIC);
END SCSI_FIFO;
architecture sim of SCSI_FIFO is
	type mem_t is array(0 to 4095) of std_logic_vector(7 downto 0);
	signal mem : mem_t;
	signal wp, rp : unsigned(11 downto 0) := (others => '0');
	signal cnt : integer range 0 to 4096 := 0;
begin
	process(wrclk, aclr) begin
		if aclr = '1' then
			wp <= (others => '0'); rp <= (others => '0'); cnt <= 0;
		elsif rising_edge(wrclk) then
			if wrreq = '1' and cnt < 4096 then mem(to_integer(wp)) <= data; wp <= wp + 1; end if;
			if rdreq = '1' and cnt > 0 then rp <= rp + 1; end if;
			if (wrreq = '1' and cnt < 4096) and not (rdreq = '1' and cnt > 0) then cnt <= cnt + 1;
			elsif not (wrreq = '1' and cnt < 4096) and (rdreq = '1' and cnt > 0) then cnt <= cnt - 1; end if;
		end if;
	end process;
	q <= mem(to_integer(rp));
	rdempty <= '1' when cnt = 0 else '0';
	wrfull <= '1' when cnt = 4096 else '0';
end architecture;
'''
open(os.path.join(here, 'work', 'fifo_stubs.vhd'), 'w').write('\n'.join(out))

# registers of the CD unit start at 0, as in the FPGA, instead of 'U'
def init_zero(src, dst):
    s = open(src).read()
    def rep(m):
        decl, typ = m.group(1), m.group(2)
        if re.match(r'(?i)std_logic\s*$', typ): return decl + " := '0';"
        if re.match(r'(?i)(std_logic_vector|unsigned|signed)\s*\(', typ): return decl + " := (others => '0');"
        return m.group(0)
    s = re.sub(r'(?im)^(\s*signal\s+[\w\s,]+:\s*([^;:=]+?))\s*;', rep, s)
    open(dst, 'w').write(s)
for n in ['cd/cd.vhd', 'cd/SCSI.vhd', 'cd/MSM5205.vhd']:
    init_zero(os.path.join(R, n), os.path.join(here, 'work', os.path.basename(n).replace('.vhd', '_sim.vhd')))

s = open(os.path.join(R, 'huc6270.vhd')).read()
s = s.replace("(others=>'0'),'0',\"00\",'0','0',\"00\"", "(others=>'0'),'0',\"0000\",'0','0',\"00\"")
s = s.replace('(559 downto 0)', '(1023 downto 0)')
open(os.path.join(here, 'work', 'huc6270_sim.vhd'), 'w').write(s)
