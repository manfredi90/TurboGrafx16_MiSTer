# Minimal HuC6280 assembler for the savestate test program (subset of pceas syntax).
import re, sys

IMPL = {'sei':0x78,'cli':0x58,'csh':0xD4,'cld':0xD8,'clc':0x18,'set':0xF4,'sxy':0x02,'sax':0x22,
        'txs':0x9A,'txa':0x8A,'tax':0xAA,'tya':0x98,'inx':0xE8,'iny':0xC8,'pha':0x48,'phx':0xDA,
        'phy':0x5A,'pla':0x68,'plx':0xFA,'ply':0x7A,'rti':0x40,'rts':0x60}
IMM = {'lda':0xA9,'ldx':0xA2,'ldy':0xA0,'adc':0x69,'and':0x29,'ora':0x09,'eor':0x49,'cpx':0xE0,
       'cpy':0xC0,'st0':0x03,'st1':0x13,'st2':0x23,'tam':0x53}
ABS = {'lda':0xAD,'ldx':0xAE,'sta':0x8D,'stx':0x8E,'stz':0x9C,'adc':0x6D,'rol':0x2E,'inc':0xEE,
       'jsr':0x20,'jmp':0x4C}
ABSX = {'lda':0xBD,'sta':0x9D,'stz':0x9E}
REL = {'bmi':0x30,'bne':0xD0,'beq':0xF0,'bcc':0x90,'bra':0x80}
BLK = {'tii':0x73,'tdd':0xC3,'tia':0xE3}
ACC = {'asl':0x0A}

src = open(sys.argv[1]).read().split('\n')
syms = {}

def ev(e, glob, final):
    e = e.strip()
    def tok(t):
        t = t.strip()
        if t.startswith('$'): return int(t[1:], 16)
        if re.fullmatch(r'\d+', t): return int(t)
        name = glob + t if t.startswith('.') else t
        if name in syms: return syms[name]
        if final: raise Exception('undefined ' + name)
        return 0
    parts = re.split(r'([+-])', e)
    v = tok(parts[0])
    for i in range(1, len(parts), 2):
        v = v + tok(parts[i+1]) if parts[i] == '+' else v - tok(parts[i+1])
    return v

def run(final):
    pc = 0; glob = ''; out = {}
    def emit(b):
        nonlocal pc
        out[pc] = b & 0xFF; pc += 1
    for ln in src:
        ln = ln.split(';')[0].rstrip()
        if not ln.strip(): continue
        m = re.match(r'^(\S+?):(.*)$', ln)
        if m and not ln[0].isspace():
            lab = m.group(1)
            if lab.startswith('.'): lab = glob + lab
            else: glob = lab
            syms[lab] = pc
            ln = m.group(2)
            if not ln.strip(): continue
        m = re.match(r'^(\w+)\s*=\s*(.+)$', ln.strip())
        if m:
            syms[m.group(1)] = ev(m.group(2), glob, final); continue
        parts = ln.strip().split(None, 1)
        op = parts[0].lower(); arg = parts[1].strip() if len(parts) > 1 else ''
        if op == '.bank': continue
        if op == '.org': pc = ev(arg, glob, final); continue
        if op == '.db':
            for a in arg.split(','): emit(ev(a, glob, final))
            continue
        if op == '.dw':
            for a in arg.split(','):
                v = ev(a, glob, final); emit(v); emit(v >> 8)
            continue
        if op in IMPL and not arg: emit(IMPL[op]); continue
        if op in ACC and arg.lower() == 'a': emit(ACC[op]); continue
        if op in BLK:
            emit(BLK[op])
            for a in arg.split(','):
                v = ev(a, glob, final); emit(v); emit(v >> 8)
            continue
        if op in REL:
            emit(REL[op]); t = ev(arg, glob, final); d = t - (pc + 1)
            if final and not -128 <= d <= 127: raise Exception('branch range ' + ln)
            emit(d); continue
        if arg.startswith('#'):
            v = ev(arg[1:], glob, final)
            if op == 'tam': v = 1 << v
            emit(IMM[op]); emit(v); continue
        m = re.match(r'^(.+),\s*x$', arg, re.I)
        if m:
            v = ev(m.group(1), glob, final); emit(ABSX[op]); emit(v); emit(v >> 8); continue
        if op in ABS:
            v = ev(arg, glob, final); emit(ABS[op]); emit(v); emit(v >> 8); continue
        raise Exception('unknown: ' + ln)
    return out

run(False); run(False); out = run(True)
rom = bytearray(0x2000)
for a, b in out.items():
    assert 0xE000 <= a <= 0xFFFF, hex(a)
    rom[a - 0xE000] = b
open(sys.argv[2], 'wb').write(rom)
print('code end %04X' % max(a for a in out if a < 0xFFF0))
