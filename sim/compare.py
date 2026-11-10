import sys
def load(p):
    out=[]
    for l in open(p):
        f=l.split()
        if len(f)>=3 and f[1].lstrip('-').isdigit():
            out.append((f[0],int(f[1]),' '.join(f[2:])))
    return out
mode=sys.argv[1]
if mode=='ac':
    a=load(sys.argv[2]); c=load(sys.argv[3])
    n=min(len(a),len(c))
    for i in range(n):
        if a[i]!=c[i]:
            print('A/C differ at', i, a[i], c[i]); break
    else: print('A/C identical over', n, 'events, last t', a[n-1][1])
else:
    a=load(sys.argv[2]); b=load(sys.argv[3])
    t=int(open(sys.argv[4]).readline())
    a=[x for x in a if x[1]>t]
    # the first frame hash after the load covers a partial frame in B
    fa=[i for i,x in enumerate(a) if x[0]=='F'][:1]
    fb=[i for i,x in enumerate(b) if x[0]=='F'][:1]
    if fa: del a[fa[0]]
    if fb: del b[fb[0]]
    n=min(len(a),len(b))
    bad=0
    for i in range(n):
        if a[i]!=b[i]:
            print('A/B differ at', i, 'A', a[i], 'B', b[i])
            for j in range(max(0,i-5), min(n,i+5)): print('  ', a[j], '|', b[j])
            bad=1; break
    if not bad: print('A/B identical over', n, 'events from t', t, 'to', a[n-1][1] if n else None)
    print('frames compared:', sum(1 for x in b[:n] if x[0]=='F'))
