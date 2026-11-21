#!/usr/bin/env python3
# Compares two savestates word by word and names the part of the state of each difference.
# Inputs: tb state files (first line core time, then 64-bit words in hex) or .sav files with
# -sav file.sav a,b (slots 1-4; -savac with the Arcade Card) (CD: 640 KB slots from 256 KB, 2.6 MB with the Arcade Card).
import sys
TYPES = [("work RAM", 32768), ("VRAM", 65536), ("SAT", 512), ("colour RAM", 1024), ("PSG wave", 256),
         ("Populous RAM", 32768), ("VRAM 2", 65536), ("SAT 2", 512), ("CD backup RAM", 2048),
         ("ADPCM RAM", 131072), ("CD RAM", 262144), ("Arcade Card RAM", 2097152)]

def read_txt(fn, skip_first):
    w = []
    with open(fn) as f:
        lines = f.read().split()
    if skip_first:
        lines = lines[1:]
    return [int(x.replace("X","0").replace("U","0"), 16) for x in lines]

def read_sav(fn, slot, ac):
    data = open(fn, "rb").read()
    base = 0x40000 + slot * (0x2A0000 if ac else 0xA0000)
    d = data[base:]
    size = int.from_bytes(d[4:8], "little")
    n = (size + 2) // 2
    return [int.from_bytes(d[i*8:i*8+8], "little") for i in range(n)]

def regions(cd, ac, internals):
    r = [("header", 1), ("internals", internals)]
    nt = 12 if ac else (11 if cd else 8)
    for name, sz in TYPES[:nt]:
        r.append((name, sz // 8))
    return r

def main():
    a = sys.argv[1:]
    if a[0] in ("-sav", "-savac"):
        ac = a[0] == "-savac"
        sa, sb = [int(x) - 1 for x in a[2].split(",")]
        A = read_sav(a[1], sa, ac); B = read_sav(a[1], sb, ac)
    else:
        A = read_txt(a[0], True); B = read_txt(a[1], False)
    size = A[0] >> 32
    cd = size in (148800, 673088); ac = size == 673088
    internals = 128 if cd else 64
    print("state size", size, "cd" if cd else "", "ac" if ac else "")
    pos = 0; ndiff = 0
    for name, n in regions(cd, ac, internals):
        cnt = 0; first = []
        for i in range(pos, pos + n):
            if i >= len(A) or i >= len(B):
                break
            if name == "header":
                continue
            if A[i] != B[i]:
                cnt += 1
                if len(first) < 40:
                    first.append(i - pos)
        if cnt:
            ndiff += cnt
            print(f"{name}: {cnt} words differ")
            for k in first:
                i = pos + k
                tag = f"reg {k}" if name == "internals" else f"byte 0x{k*8:X}"
                print(f"   {tag}: {A[i]:016X} -> {B[i]:016X}  xor {A[i]^B[i]:016X}")
        pos += n
    print("differences:", ndiff)

main()
