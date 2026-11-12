import sys, struct; sys.path.insert(0, sys.argv[2])
from adt import *
root = parse(open(sys.argv[1],'rb').read())
pm = find(root, '/device-tree/arm-io/pmgr')['props']
reg = pm['reg']; regs = [struct.unpack_from('<QQ', reg, i) for i in range(0, len(reg), 16)]
bri = struct.unpack('<I', pm['bridge-reg-index'])[0]; nb = struct.unpack('<I', pm['#bridges'])[0]
d = pm['devices']; users = {}
for i in range(0, len(d), 48):
    e = d[i:i+48]; n = struct.unpack_from('<H', e, 24)[0]; name = e[32:48].split(b'\0')[0].decode()
    for b in e[28:28+n]: users.setdefault(b, []).append(name)
print('bridge-reg-index %d, #bridges %d' % (bri, nb))
for b in range(nb):
    a, s = regs[bri + b]; v = pm['bridge-settings-%d' % b]
    pairs = [struct.unpack_from('<II', v, i) for i in range(0, len(v), 8)]
    print('bridge %2d  PA 0x%09x size 0x%x  used by %s  (%d writes)' % (b, 0x200000000 + a, s, users.get(b), len(pairs)))
    if b in (10, 11, 3, 13, 0):
        for o, val in pairs: print('      +0x%05x = 0x%08x' % (o, val))
print('clocks:'); c = pm['clocks']
for i in range(0, len(c), 24): print('  ', c[i:i+8].hex(), c[i+8:i+24].split(b'\0')[0])
print('power-domains:'); c = pm['power-domains']
for i in range(0, len(c), 24): print('  ', c[i:i+8].hex(), c[i+8:i+24].split(b'\0')[0])
