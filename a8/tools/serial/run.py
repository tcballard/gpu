import os, sys, time, termios, select, re, uuid
fd = os.open('/dev/ttyACM0', os.O_RDWR | os.O_NOCTTY)
a = termios.tcgetattr(fd); a[3] &= ~(termios.ECHO|termios.ICANON); termios.tcsetattr(fd, termios.TCSANOW, a)
while select.select([fd],[],[],0.3)[0]: os.read(fd, 65536)
cmd = sys.stdin.read()
tag = uuid.uuid4().hex[:8]
s, e = 'BEG'+tag, 'END'+tag
line = "B=BEG; E=END; echo ${B}%s; { %s ; } 2>&1 | cat; echo ${E}%s\n" % (tag, cmd.strip().replace('\n','; '), tag)
os.write(fd, line.encode())
end = time.time() + float(sys.argv[1] if len(sys.argv) > 1 else 10)
out = b''
while time.time() < end:
    if select.select([fd],[],[],0.3)[0]:
        out += os.read(fd, 65536)
        if s.encode() in out and e.encode() in out.split(s.encode(),1)[-1]: break
t = out.decode(errors='replace')
t = re.sub(r'\x1b\][^\x07\x1b]*(\x07|\x1b\\)', '', t)
t = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b[78]|\x1bP[^\x1b]*\x1b\\', '', t)
t = t.replace('\r','')
if s in t: t = t.split(s,1)[1]
if e in t: t = t.split(e,1)[0]
sys.stdout.write(re.sub(r'\n\n+', '\n', t).strip()+'\n')
