#!/usr/bin/env python3
"""
verify_sites.py -- offline check of the J96 page-5 probe signatures against the
19H386 kernelcache, before building/loading the KPF module.

Checks:
  1. the Mach-O LC_UUID matches CC26BE6A-292B-3759-9ED0-290BCF18B090;
  2. the capture signature (ApplePMGR ps-poll) is found exactly once;
  3. the read signature (AGXG4P post-poll) is found exactly once;
  4. prints each site pc and the replaced instruction.

Usage:
  python3 verify_sites.py /path/to/kernelcache.release.iPad5,1_2
"""
import sys, os, struct

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
from kc import KC  # noqa: E402

UUID = bytes([0xcc, 0x26, 0xbe, 0x6a, 0x29, 0x2b, 0x37, 0x59,
              0x9e, 0xd0, 0x29, 0x0b, 0xcf, 0x18, 0xb0, 0x90])

# capture site: `blr x8` at 0xfffffff0066e4294 (ApplePMGR ps-poll)
CAP_SIG = [
    0x531c6f24, 0xf9400288, 0xf944c908, 0xaa1403e0, 0xaa1503e1, 0xaa1703e2,
    0x52801e03, 0x529dc005, 0x72a00045, 0xaa1303e6, 0xd63f0100,
]
CAP_SITE = 10
CAP_EXPECT = 0xfffffff0066e4294
CAP_INSTR = 0xd63f0100  # blr x8

# read site: `mov w0,#0xa` at 0xfffffff006695a44 (AGXG4P post-poll)
RD_SIG = [
    0x52a80008, 0xb9000008, 0x52800228, 0xb9100008,
    0xb9500008, 0x3727ffe8, 0x52800140, 0x9400b3d1,
]
RD_SITE = 6
RD_EXPECT = 0xfffffff006695a44
RD_INSTR = 0x52800140  # mov w0,#0xa


def find_sites(k, sig, site_idx):
    hits = []
    for name, v, vs, f, fs, p in k.segs:
        if name != '__PLK_TEXT_EXEC':
            continue
        words = struct.unpack_from('<%dI' % (fs // 4), k.b, f)
        for i in range(len(words) - len(sig) + 1):
            if all(words[i + j] == sig[j] for j in range(len(sig))):
                hits.append(v + (i + site_idx) * 4)
    return hits


def main():
    k = KC(sys.argv[1])
    b = k.b
    assert struct.unpack_from('<I', b, 0)[0] == 0xfeedfacf
    ncmds = struct.unpack_from('<I', b, 16)[0]
    off = 32
    uuid = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', b, off)
        if cmd == 0x1b:
            uuid = b[off + 8:off + 24]
        off += size

    ok = True
    print('UUID match:', 'OK' if uuid == UUID else 'MISMATCH')
    ok &= uuid == UUID

    cap_hits = find_sites(k, CAP_SIG, CAP_SITE)
    print('capture site hits:', len(cap_hits))
    for h in cap_hits:
        w = struct.unpack_from('<I', b, k.fo(h))[0]
        print('  site 0x%x (0x%08x) %s' % (h & 0xfffffff, w,
              'OK' if h == CAP_EXPECT and w == CAP_INSTR else 'MISMATCH'))
        ok &= h == CAP_EXPECT and w == CAP_INSTR
    ok &= len(cap_hits) == 1

    rd_hits = find_sites(k, RD_SIG, RD_SITE)
    print('read site hits:', len(rd_hits))
    for h in rd_hits:
        w = struct.unpack_from('<I', b, k.fo(h))[0]
        print('  site 0x%x (0x%08x) %s' % (h & 0xfffffff, w,
              'OK' if h == RD_EXPECT and w == RD_INSTR else 'MISMATCH'))
        ok &= h == RD_EXPECT and w == RD_INSTR
    ok &= len(rd_hits) == 1

    print('RESULT:', 'GO' if ok else 'NO-GO')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
