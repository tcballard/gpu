import os, sys, time, termios, select, base64
src, dst = sys.argv[1], sys.argv[2]
fd = os.open('/dev/ttyACM0', os.O_RDWR | os.O_NOCTTY)
a = termios.tcgetattr(fd); a[3] &= ~(termios.ECHO|termios.ICANON); termios.tcsetattr(fd, termios.TCSANOW, a)
def drain(t=0.3):
    out = b''
    while select.select([fd],[],[],t)[0]: out += os.read(fd, 65536)
    return out
os.write(fd, b'\x03'); time.sleep(0.5); os.write(fd, b'\x03\n'); drain(1.0)
b64 = base64.encodebytes(open(src,'rb').read())
os.write(fd, ("stty -echo; cat > %s.b64; stty echo\n" % dst).encode()); time.sleep(1.0); drain()
lines = b64.splitlines(keepends=True)
for i in range(0, len(lines), 8):
    os.write(fd, b''.join(lines[i:i+8])); time.sleep(0.02)
time.sleep(0.5); os.write(fd, b'\x04'); time.sleep(1.0); drain()
print("sent %d bytes as %d base64 lines" % (os.path.getsize(src), len(lines)))
