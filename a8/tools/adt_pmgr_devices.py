import sys, struct; sys.path.insert(0, sys.argv[2])
from adt import *
root = parse(open(sys.argv[1],'rb').read())
pm = find(root, '/device-tree/arm-io/pmgr')['props']
io = find(root, '/device-tree/arm-io')['props']
print('arm-io ranges:', show(io['ranges'], 200))
reg = pm['reg']
print('== pmgr reg (child addr -> PA = 0x200000000 + addr)')
regs = []
for i in range(0, len(reg), 16):
    a, s = struct.unpack_from('<QQ', reg, i); regs.append((a, s))
    print('  reg[%2d] PA 0x%09x size 0x%x' % (i//16, 0x200000000 + a, s))
print('== ps-regs (reg idx, offset, mask)')
ps = pm['ps-regs']; psr = []
for i in range(0, len(ps), 12):
    r, o, m = struct.unpack_from('<III', ps, i); psr.append((r, o, m))
    print('  ps-reg[%d] reg %d off 0x%x mask 0x%08x' % (i//12, r, o, m))
print('== devices (48-byte entries)')
d = pm['devices']
for i in range(0, len(d), 48):
    e = d[i:i+48]
    flags, u10, u11, u12 = e[0], e[1], e[2], e[3]
    p0, p1 = struct.unpack_from('<HH', e, 4)
    perf_idx, perf_block, psidx, psreg = e[8], e[9], e[10], e[11]
    u20, = struct.unpack_from('<H', e, 12); pd, cfg16 = e[14], e[15]
    z0, z1 = struct.unpack_from('<II', e, 16)
    u23, did = struct.unpack_from('<HH', e, 24); u3, = struct.unpack_from('<I', e, 28)
    name = e[32:48].split(b'\0')[0].decode('latin1')
    addr = ''
    if psreg < len(psr):
        r, o, m = psr[psreg]; addr = '0x%09x' % (0x200000000 + regs[r][0] + o + psidx*8)
    print('  %2d id 0x%02x %-14s flags %02x u1 %02x %02x %02x parents %04x %04x perf %d/%d psreg %d idx %2d %s u20 %04x pd %d cfg16 %d z %x %x u23 %04x u3 %08x'
          % (i//48, did, name, flags, u10, u11, u12, p0, p1, perf_idx, perf_block, psreg, psidx, addr, u20, pd, cfg16, z0, z1, u23, u3))
