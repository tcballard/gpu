#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Telnet-only driver for the palera1n-booted J96 (booted with `palera1n -l -T`).

iPadOS 15 rootless has no /bin/sh, so the binpack's dropbear refuses root's login shell and
session.py's SSH path does not work here. This uses only the root telnetd on port 46
(through iproxy): files go over as hex and are rebuilt with the binpack's xxd.

  tsession.py run 'uname -a'          # one root command, output printed
  tsession.py push FILE [REMOTE]      # copy FILE to the iPad (default /var/tmp/NAME, mode 755)
  tsession.py kprobe [ARGS...]        # push build/kprobe and run it
"""
import hashlib
import os
import pathlib
import re
import socket
import subprocess
import sys
import time
import uuid

HERE = pathlib.Path(__file__).resolve().parent
PORT = 4646
UDID = os.environ.get('UDID')


class Telnet:
    def __init__(self):
        self.s = socket.create_connection(('127.0.0.1', PORT), timeout=5)
        self.s.settimeout(0.3)
        self.read(1.5)  # banner and option negotiation

    def read(self, seconds, until=None):
        out = b''
        end = time.time() + seconds
        while time.time() < end:
            try:
                data = self.s.recv(65536)
            except socket.timeout:
                data = b''
            i = 0
            while i < len(data):
                if data[i] == 255 and i + 2 < len(data) and data[i + 1] in (251, 252, 253, 254):
                    reply = 252 if data[i + 1] in (253, 254) else 254
                    self.s.sendall(bytes([255, reply, data[i + 2]]))
                    i += 3
                    continue
                out += data[i:i + 1]
                i += 1
            if until and until in out:
                break
        return out

    def run(self, command, seconds=20):
        """Run one command; return (exit status, output) using unique markers."""
        tag = uuid.uuid4().hex[:10]
        # The markers are split so the echoed command line does not contain them.
        line = f"B=BEG; E=END; echo ${{B}}{tag}; {command}; echo ${{E}}{tag}:$?\r\n"
        self.s.sendall(line.encode())
        text = self.read(seconds, until=f'END{tag}:'.encode()).decode(errors='replace')
        text += self.read(0.5).decode(errors='replace')
        m = re.search(rf'BEG{tag}\r?\n(.*?)END{tag}:(\d+)', text, re.S)
        if not m:
            return None, text
        return int(m.group(2)), m.group(1).replace('\r', '')

    def push(self, local, remote):
        data = pathlib.Path(local).read_bytes()
        self.s.sendall(f"stty -echo; xxd -r -p > {remote}.hex.tmp <<'HEXEOF'\r\n".encode())
        time.sleep(0.5)
        hexed = data.hex()
        # Small, paced writes: the pty drops input when it is fed faster than xxd reads it.
        for i in range(0, len(hexed), 64 * 4):
            chunk = '\r\n'.join(hexed[j:j + 64] for j in range(i, min(i + 64 * 4, len(hexed)), 64))
            self.s.sendall(chunk.encode() + b'\r\n')
            time.sleep(0.02)
            self.read(0.0)
        self.s.sendall(b"HEXEOF\r\nstty echo\r\n")
        self.read(2.0)
        want = hashlib.sha256(data).hexdigest()
        rc, out = self.run(f"/cores/binpack/sbin/sha256 {remote}.hex.tmp")
        if want not in out:
            raise SystemExit(f'push failed: remote sha256 differs ({out.strip()[:200]!r}, want {want})')
        rc, out = self.run(f"mv {remote}.hex.tmp {remote} && chmod 755 {remote}")
        if rc != 0:
            raise SystemExit(f'push failed: {out}')
        return want


def main(argv):
    if len(argv) < 2 or argv[1] not in ('run', 'push', 'kprobe'):
        sys.exit(__doc__)
    proxy = subprocess.Popen(['iproxy', *(['-u', UDID] if UDID else []), f'{PORT}:46'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)
    try:
        try:
            t = Telnet()
        except OSError as e:
            sys.exit(f'No telnetd on the iPad ({e}). Boot it with: palera1n -l -T')
        if argv[1] == 'run':
            rc, out = t.run(' '.join(argv[2:]), seconds=60)
            sys.stdout.write(out)
            return 1 if rc is None else rc
        if argv[1] == 'push':
            local = pathlib.Path(argv[2])
            remote = argv[3] if len(argv) > 3 else f'/var/tmp/{local.name}'
            print(remote, t.push(local, remote))
            return 0
        tool = '/var/tmp/kprobe'
        print('pushed, sha256', t.push(HERE / 'build/kprobe', tool))
        args = ' '.join(argv[2:])
        for a in argv[2:]:
            if not re.fullmatch(r'read|0x[0-9a-fA-F]+|[0-9]+', a):
                sys.exit('kprobe arguments: read ADDR LEN (numbers only)')
        rc, out = t.run(f'{tool} {args} 2>&1', seconds=60)
        sys.stdout.write(out)
        print('exit status:', rc)
        return 1 if rc is None else rc
    finally:
        proxy.terminate()


if __name__ == '__main__':
    sys.exit(main(sys.argv))
