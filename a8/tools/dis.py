import sys, subprocess, os, re; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kc import KC
def dis(k, start, end, tmp):
    fo = k.fo(start); raw = os.path.join(tmp, 'd.bin'); elf = os.path.join(tmp, 'd.o')
    open(raw, 'wb').write(k.b[fo:fo + (end - start)])
    subprocess.check_call(['llvm-objcopy', '-I', 'binary', '-O', 'elf64-littleaarch64', '--rename-section', '.data=.text,code', raw, elf])
    out = subprocess.check_output(['llvm-objdump', '-d', '--no-show-raw-insn', elf]).decode()
    res = []
    for l in out.splitlines():
        m = re.match(r'\s*([0-9a-f]+):\s+(.*)', l)
        if not m or '<_binary' in l.split(':')[0]: continue
        t = re.sub(r'0x([0-9a-f]+) <[^>]*>', lambda x: '0x%x' % (start + int(x.group(1), 16)), m.group(2).replace('\t', ' '))
        res.append((start + int(m.group(1), 16), t))
    return res
if __name__ == '__main__':
    k = KC(sys.argv[1]); a = int(sys.argv[2], 16); b = int(sys.argv[3], 16)
    if a < 0x100000000: a += 0xfffffff000000000; b += 0xfffffff000000000
    for pc, t in dis(k, a, b, sys.argv[4]): print('%07x  %s' % (pc & 0xfffffff, re.sub(r'0xfffffff00', '0x', t)))
