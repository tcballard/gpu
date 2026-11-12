import struct, sys, bisect
class KC:
    def __init__(self, path):
        self.b = open(path,'rb').read(); b = self.b
        assert struct.unpack_from('<I', b, 0)[0] == 0xfeedfacf
        ncmds = struct.unpack_from('<I', b, 16)[0]; off = 32; self.segs = []
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', b, off)
            if cmd == 0x19:
                name = b[off+8:off+24].split(b'\0')[0].decode()
                vmaddr, vmsize, fileoff, filesize, maxprot, initprot = struct.unpack_from('<QQQQii', b, off+24)
                self.segs.append((name, vmaddr, vmsize, fileoff, filesize, initprot))
            off += size
    def va(self, fo):
        for n, v, vs, f, fs, p in self.segs:
            if f <= fo < f + fs: return v + fo - f
    def fo(self, va):
        for n, v, vs, f, fs, p in self.segs:
            if v <= va < v + fs: return f + va - v
    def exec_segs(self):
        return [s for s in self.segs if 'TEXT_EXEC' in s[0]]
    def xrefs(self, targets):
        """ADRP+ADD references to any VA in targets -> list of (pc, target)."""
        import array
        out = []; tset = set(targets); pages = set(t & ~0xfff for t in tset)
        for n, v, vs, f, fs, p in self.exec_segs():
            w = array.array('I'); w.frombytes(self.b[f:f+(fs & ~3)])
            for i, ins in enumerate(w):
                if ins & 0x9f000000 != 0x90000000: continue
                imm = ((ins >> 3) & 0x1ffffc) | ((ins >> 29) & 3)
                if imm & 0x100000: imm -= 0x200000
                pc = v + i*4; page = (pc & ~0xfff) + (imm << 12)
                if page not in pages: continue
                rd = ins & 31
                for j in range(1, 6):
                    if i + j >= len(w): break
                    n2 = w[i+j]
                    if (n2 & 0xffc003e0) == (0x91000000 | (rd << 5)):
                        t = page + ((n2 >> 10) & 0xfff)
                        if t in tset: out.append((pc, t))
                        break
        return out
if __name__ == '__main__':
    k = KC(sys.argv[1])
    for s in k.segs: print('%-18s va 0x%x size 0x%x fileoff 0x%x filesize 0x%x prot %d' % s)
