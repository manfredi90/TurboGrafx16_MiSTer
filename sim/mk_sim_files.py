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
open(os.path.join(here, 'work', 'fifo_stubs.vhd'), 'w').write('\n'.join(out))

s = open(os.path.join(R, 'huc6270.vhd')).read()
s = s.replace("(others=>'0'),'0',\"00\",'0','0',\"00\"", "(others=>'0'),'0',\"0000\",'0','0',\"00\"")
s = s.replace('(559 downto 0)', '(1023 downto 0)')
open(os.path.join(here, 'work', 'huc6270_sim.vhd'), 'w').write(s)
