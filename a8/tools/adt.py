import struct, sys
def parse(blob):
    pos = 0
    def node():
        nonlocal pos
        nprops, nchild = struct.unpack_from('<II', blob, pos); pos += 8
        props = {}
        for _ in range(nprops):
            label = blob[pos:pos+32].split(b'\0',1)[0].decode('latin1')
            size = struct.unpack_from('<I', blob, pos+32)[0] & 0xffffff
            pos += 36
            props[label] = blob[pos:pos+size]
            pos += (size + 3) & ~3
        kids = [node() for _ in range(nchild)]
        return {'props': props, 'children': kids, 'name': props.get('name', b'?').split(b'\0')[0].decode('latin1')}
    return node()
def walk(n, path=''):
    p = path + '/' + n['name']
    yield p, n
    for c in n['children']:
        yield from walk(c, p)
def find(root, path):
    for p, n in walk(root):
        if p == path: return n
def show(v, maxlen=64):
    if len(v) and all(32 <= b < 127 or b == 0 for b in v) and v.strip(b'\0') and v.endswith(b'\0'):
        return repr(v.rstrip(b'\0').decode())
    if len(v) % 4 == 0 and len(v) <= maxlen:
        return ' '.join('%08x' % x for x in struct.unpack('<%dI' % (len(v)//4), v))
    return v[:maxlen].hex() + (' ...(%d bytes)' % len(v) if len(v) > maxlen else '')
