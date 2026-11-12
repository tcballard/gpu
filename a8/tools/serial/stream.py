# Start a token in the background on the iPad and stream matching kernel lines to the host
# as they appear, so lines printed before a freeze survive. usage: stream.py TOKEN SECONDS LOGFILE
import os, sys, time, termios, select, re
tok, secs, log = sys.argv[1], float(sys.argv[2]), sys.argv[3]
fd = os.open('/dev/ttyACM0', os.O_RDWR | os.O_NOCTTY)
a = termios.tcgetattr(fd); a[3] &= ~(termios.ECHO|termios.ICANON); termios.tcsetattr(fd, termios.TCSANOW, a)
while select.select([fd],[],[],0.3)[0]: os.read(fd, 65536)
cmd = "sync; dmesg -w | grep --line-buffered J96GB & sleep 1; echo %s > /sys/bus/platform/devices/201000000.gpu-probe/attempt; echo STREAM_RC=$?; sleep 2; kill %%1\n" % tok
os.write(fd, cmd.encode())
end = time.time() + secs; buf = b''; last = time.time()
with open(log, 'ab') as f:
    while time.time() < end:
        if select.select([fd],[],[],0.5)[0]:
            d = os.read(fd, 65536); buf += d; f.write(d); f.flush(); last = time.time()
            if re.search(rb'STREAM_RC=[0-9]', buf):
                time.sleep(3)
                while select.select([fd],[],[],0.5)[0]:
                    d = os.read(fd, 65536); buf += d; f.write(d)
                break
t = buf.decode(errors='replace'); t = re.sub(r'\x1b\][^\x07\x1b]*(\x07|\x1b\\)', '', t); t = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', t).replace('\r', '')
keep = [l for l in t.split('\n') if 'J96GB' in l and 'grep' not in l or 'STREAM_RC' in l and 'echo' not in l]
print('\n'.join(re.sub(r'apple-j96-gpubridge 201000000.gpu-probe: ', '', l) for l in keep))
print('--- seconds since last byte: %.0f' % (time.time() - last))
