#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Drive the palera1n-booted J96 (iPad mini 4, iPadOS 15.8.3) over USB.

Adapted from OrchardLinux/gpu tools/a10/ios-capture/session.py. The iPad must have been
booted with `palera1n -l -T` (rootless, with the binpack's root telnetd on port 46). This
installs an SSH key through that telnetd, starts a key-only dropbear bound to the iPad's
loopback on port 2222 (reached through usbmux only), then runs commands over SSH.

  session.py shell 'uname -a'      # any root command
  session.py kprobe                # push build/kprobe to /var/tmp and run it
  session.py kread ADDR LEN        # kprobe read ADDR LEN (kernel VIRTUAL memory only)
  session.py push FILE [REMOTE]    # copy a file to the iPad (default /var/tmp/NAME, mode 755)
  session.py pull REMOTE_DIR OUT   # tar a directory off the iPad into OUT

Nothing here writes kernel memory or changes the iPad's storage layout. It appends one
public key to /var/root/.ssh/authorized_keys on the iPad; the dropbear it starts lasts until
the iPad reboots.
"""
import os
import pathlib
import socket
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
KEY = HERE / 'build/id_ed25519'
TELNET, SSH = 4646, 4444  # local ports -> device 46 (telnetd), 2222 (our dropbear)
UDID = os.environ.get('UDID')  # required only when several Apple devices are attached


def proxies():
    procs = [subprocess.Popen(['iproxy', *(['-u', UDID] if UDID else []), f'{local}:{remote}'],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
             for local, remote in ((TELNET, 46), (SSH, 2222))]
    time.sleep(1)
    return procs


def telnet(command, wait=2.0):
    """Run one line in the root telnet shell, refusing every option negotiation."""
    s = socket.create_connection(('127.0.0.1', TELNET), timeout=5)
    s.settimeout(0.5)
    out = b''
    end = time.time() + wait
    sent = False
    while time.time() < end:
        try:
            data = s.recv(4096)
        except socket.timeout:
            data = b''
        i = 0
        while i < len(data):
            if data[i] == 255 and i + 2 < len(data) and data[i + 1] in (251, 252, 253, 254):
                reply = 252 if data[i + 1] in (253, 254) else 254  # DO/DONT -> WONT, WILL/WONT -> DONT
                s.sendall(bytes([255, reply, data[i + 2]]))
                i += 3
                continue
            out += data[i:i + 1]
            i += 1
        if not sent and time.time() > end - wait + 0.8:
            s.sendall(command.encode() + b'\r\n')
            sent = True
    s.close()
    return out.decode(errors='replace')


def ssh(*args, **kw):
    return subprocess.run(['ssh', '-p', str(SSH), '-i', str(KEY), '-o', 'StrictHostKeyChecking=no',
                           '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR',
                           '-o', 'IdentitiesOnly=yes', 'root@127.0.0.1', *args], **kw)


def ensure_key():
    if not KEY.exists():
        KEY.parent.mkdir(exist_ok=True)
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(KEY)], check=True)
    if ssh('true', stdin=subprocess.DEVNULL, capture_output=True).returncode == 0:
        return
    pub = (KEY.with_suffix('.pub')).read_text().strip()
    try:
        print(telnet(f"mkdir -p /var/root/.ssh && chmod 700 /var/root/.ssh && echo '{pub}' >> "
                     "/var/root/.ssh/authorized_keys && chmod 600 /var/root/.ssh/authorized_keys && echo KEY-OK"))
    except OSError as e:
        sys.exit(f'No telnetd on the iPad ({e}). Boot it with: palera1n -l -T')
    # Key-only, loopback-only (reached through usbmux); host key generated on demand.
    print(telnet('/cores/binpack/usr/sbin/dropbear -R -s -g -p 127.0.0.1:2222 '
                 '-P /var/run/gpu-dropbear.pid && echo SSHD-OK'))
    time.sleep(1)
    ssh('true', stdin=subprocess.DEVNULL, check=True)


def push(local, remote=None):
    local = pathlib.Path(local)
    remote = remote or f'/var/tmp/{local.name}'
    with open(local, 'rb') as f:
        ssh(f'cat > {remote} && chmod 755 {remote}', stdin=f, check=True)
    return remote


def main(argv):
    if len(argv) < 2 or argv[1] not in ('shell', 'kprobe', 'kread', 'push', 'pull'):
        sys.exit(__doc__)
    procs = proxies()
    try:
        ensure_key()
        cmd = argv[1]
        if cmd == 'shell':
            return ssh(' '.join(argv[2:])).returncode
        if cmd == 'push':
            print(push(*argv[2:4]))
            return 0
        if cmd == 'pull':
            out = pathlib.Path(argv[3])
            out.mkdir(parents=True, exist_ok=True)
            with subprocess.Popen(['tar', '-C', str(out), '-xf', '-'], stdin=subprocess.PIPE) as tar:
                ssh(f'tar -C {argv[2]} -cf - .', stdout=tar.stdin, check=True)
                tar.stdin.close()
            print('Pulled into', out)
            return 0
        tool = push(HERE / 'build/kprobe')
        if cmd == 'kprobe':
            ssh('sw_vers 2>/dev/null; uname -a; id')
            return ssh(tool).returncode
        addr, length = argv[2], argv[3]
        int(addr, 0), int(length, 0)  # numbers only: they go into a root shell command
        return ssh(f'{tool} read {addr} {length}').returncode
    finally:
        for p in procs:
            p.terminate()


if __name__ == '__main__':
    sys.exit(main(sys.argv))
