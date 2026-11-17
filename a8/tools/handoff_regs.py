#!/usr/bin/env python3
"""J96 handoff snapshot (M1 route step 1, 17 Nov 2026): one register list, read-only.

The same PMGR words are read at the PongoOS shell (peek) and under Linux (probe token
gpu-pmgr-handoff-snap), and the two logs are compared here.

  handoff_regs.py pongo-cmds          > cmds.txt   # peek lines for pongoterm
  handoff_regs.py parse LOG                         # print addr=value as parsed
  handoff_regs.py diff PONGO_LOG LINUX_LOG          # compare, grouped by region
  handoff_regs.py c-table                           # the C region table (must match the probe)

Order: the regions read before under Linux first, the never-read LLB pages last, so a hang
names a new region. All PA, all 32-bit, no writes.
"""
import re
import sys

PMGR = 0x20e000000

# Every ps register named by the ADT pmgr 'devices' table (unique PAs, 8-byte stride groups).
PS_OFFS = (
    [0x20000, 0x20008, 0x20040]
    + list(range(0x20100, 0x20200, 8))                           # ps-reg[1], 32 regs
    + [0x20200, 0x20208, 0x20210, 0x20218, 0x20220, 0x20230, 0x20238, 0x20240, 0x20248,
       0x20250, 0x20258, 0x20260, 0x20268, 0x20278, 0x20288, 0x20290, 0x20298, 0x202a0,
       0x202a8, 0x202b0, 0x202b8, 0x202c0, 0x202c8, 0x202d0, 0x202d8, 0x202e0, 0x202e8,
       0x202f0]                                                  # ps-reg[2] as used
    + [0x20300, 0x20308, 0x20310, 0x20318, 0x20320]              # ps-reg[3], GFX last
    + [0x20400]                                                  # ps-reg[4], SEP
    + [0x21000, 0x21008, 0x21010]                                # ps-reg[5], VENC
)

# (name, start offset, words, stride). Mirrors j96gb_hs_regions[] in probe/apple-j96-gpubridge.c.
REGIONS = [
    ('page5', 0x5000, 16, 4),
    ('page0', 0x0000, 16, 4),
    ('page1', 0x1000, 16, 4),
    ('page2', 0x2000, 16, 4),
    ('page3', 0x3000, 16, 4),
    ('page4', 0x4000, 16, 4),
    ('gfxperf', 0x1c000, 256, 4),       # slots +0x1c000.., control +0x1c200, +0x1c300
    ('ps', None, len(PS_OFFS), None),   # explicit list above
    ('x2300c', 0x2300c, 1, 4),
    ('f208', 0xf208, 6, 4),             # LLB: six words 0xf208..0xf21c
    ('llb10', 0x10000, 48, 4),          # LLB: 47-word table 0x10000..0x100b8 (+0x100bc)
    ('llb11', 0x11000, 1, 4),           # LLB: bit 31 at the page bases
    ('llb12', 0x12000, 1, 4),
    ('llb13', 0x13000, 1, 4),
    ('llb14', 0x14000, 1, 4),
    ('llb11w', 0x11004, 47, 4),         # rest of +0..+0xbc of pages 0x11000..0x14000: never
    ('llb12w', 0x12004, 47, 4),         # read anywhere, so last
    ('llb13w', 0x13004, 47, 4),
    ('llb14w', 0x14004, 47, 4),
]


def offsets(region):
    name, start, words, stride = region
    if name == 'ps':
        return list(PS_OFFS)
    return [start + i * stride for i in range(words)]


def all_offsets():
    out = []
    for r in REGIONS:
        out += [(r[0], o) for o in offsets(r)]
    return out


def pongo_cmds():
    lines = []
    for name, off in all_offsets():
        lines.append('peek 0x%x' % (PMGR + off))
    return '\n'.join(lines) + '\n'


# Pongo: "0x20e005004: 0 (0 0 0 0)". Linux: "J96GB_HS 20e005004=00000000 ..." (several per line).
PONGO_RE = re.compile(r'0x(20e0[0-9a-f]{5}):\s+([0-9a-f]+)\s+\(')
LINUX_RE = re.compile(r'\b(20e0[0-9a-f]{5})=([0-9a-f]{8})\b')


def parse(path):
    text = open(path, errors='replace').read()
    vals = {}
    is_linux = 'J96GB_HS' in text
    for line in text.splitlines():
        if is_linux and 'J96GB_HS' not in line:
            continue
        for a, v in (LINUX_RE if is_linux else PONGO_RE).findall(line):
            a, v = int(a, 16), int(v, 16)
            if a in vals and vals[a] != v:
                print('warning: %s reads 0x%x twice with different values' % (path, a),
                      file=sys.stderr)
            vals[a] = v
    return vals


def diff(pa, pb):
    a, b = parse(pa), parse(pb)
    want = [PMGR + o for _, o in all_offsets()]
    miss_a = [x for x in want if x not in a]
    miss_b = [x for x in want if x not in b]
    print('Pongo: %d/%d words, Linux: %d/%d words' % (len(want) - len(miss_a), len(want),
                                                      len(want) - len(miss_b), len(want)))
    for tag, miss in (('Pongo', miss_a), ('Linux', miss_b)):
        if miss:
            print('  %s missing from 0x%x (%d words; a hang or a cut log?)' % (tag, miss[0],
                                                                               len(miss)))
    total = 0
    for r in REGIONS:
        rows = []
        for o in offsets(r):
            x = PMGR + o
            if x in a and x in b and a[x] != b[x]:
                rows.append('    +0x%05x  pongo %08x  linux %08x  xor %08x' % (o, a[x], b[x],
                                                                            a[x] ^ b[x]))
        nonzero = sum(1 for o in offsets(r) if a.get(PMGR + o) or b.get(PMGR + o))
        print('%-8s %3d words, %3d non-zero, %3d differ' % (r[0], len(offsets(r)), nonzero,
                                                           len(rows)))
        print('\n'.join(rows)) if rows else None
        total += len(rows)
    print('TOTAL differing words: %d' % total)


def c_table():
    for name, start, words, stride in REGIONS:
        if name == 'ps':
            continue
        print('\t{ "%s", 0x%05x, %d },' % (name, start, words))


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'pongo-cmds':
        sys.stdout.write(pongo_cmds())
    elif cmd == 'parse' and len(sys.argv) == 3:
        for a, v in sorted(parse(sys.argv[2]).items()):
            print('0x%x=%08x' % (a, v))
    elif cmd == 'diff' and len(sys.argv) == 4:
        diff(sys.argv[2], sys.argv[3])
    elif cmd == 'c-table':
        c_table()
    else:
        sys.exit(__doc__)
