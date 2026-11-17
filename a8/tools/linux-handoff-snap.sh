#!/usr/bin/env bash
# M1 route step 1 (17 Nov 2026): the Linux half of the handoff snapshot.
#   gpu/tools/linux-handoff-snap.sh [PRIVATE_SNAP_DIR]
# Run on a fresh J96 Linux boot (./j96-boot), before any other GPU token. Over SSH it copies
# apple-j96-gpubridge.ko to /run, checks its hash, swaps the gpu-probe binding, and runs the
# read-only token gpu-pmgr-handoff-snap once (PMGR reads only, ps_gfx stays off, no RGX). It then
# restores the binding and the console, and saves the dmesg to PRIVATE_SNAP_DIR/linux.log
# (default: the newest private/handoff-snap-*). The log is Apple hardware data: private/ only.
set -euo pipefail
umask 077
GPU=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=$(cd -- "$GPU/.." && pwd)
KO=$GPU/probe/apple-j96-gpubridge.ko
fail() { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }
out=${1:-$(ls -d "$ROOT"/private/handoff-snap-* 2>/dev/null | sort | tail -1)}
[[ -n $out && -d $out && $out == "$ROOT"/private/* ]] || fail 'No private/handoff-snap-* directory.'
[[ ! -e $out/linux.log ]] || fail "$out/linux.log exists; pass a new directory."
ipad() { ssh -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR -i "$ROOT/private/j96_ed25519" root@10.96.0.2 "$@"; }
sum=$(sha256sum "$KO" | cut -d' ' -f1)
ipad 'cat > /run/apple-j96-gpubridge.ko' < "$KO"
[[ $(ipad 'sha256sum /run/apple-j96-gpubridge.ko' | cut -d' ' -f1) == "$sum" ]] || fail 'Module hash differs on the iPad.'
echo "Module copied ($sum). Running the read-only token; watch the iPad screen for J96GB_NEXT lines."
ipad sh -s <<'EOF' | tee "$out/linux-session.txt"
set -e
D=/sys/bus/platform/devices/201000000.gpu-probe
uname -r
lsmod | grep -q '^apple_j96_gpubridge ' && { echo 'STOP: module already loaded (not a fresh boot)'; exit 1; }
systemctl stop getty@tty1 || true
chvt 1 || true
printf '\033[9;0]' > /dev/tty1 || true
echo 201000000.gpu-probe > /sys/bus/platform/drivers/apple-j96-gpuprobe/unbind
insmod /run/apple-j96-gpubridge.ko
cat $D/attempt
sync
echo gpu-pmgr-handoff-snap > $D/attempt && echo 'token returned 0' || echo "token returned $?"
dmesg | grep -E 'J96GB_(BEGIN|STOP|ABORT|REFUSED)'
EOF
ipad 'dmesg' | grep -E 'J96GB_(HS|BEGIN|STOP|NEXT|ABORT|REFUSED|READY)' > "$out/linux.log"
ipad sh -s <<'EOF' || echo 'WARNING: restoring the probe binding or getty failed; check by hand.'
rmmod apple_j96_gpubridge
echo 201000000.gpu-probe > /sys/bus/platform/drivers/apple-j96-gpuprobe/bind
systemctl start getty@tty1
EOF
printf '%s J96GB_HS lines saved: %s/linux.log\n' "$(grep -c J96GB_HS "$out/linux.log")" "$out"
[[ -f $out/pongo.log ]] && python3 -I "$GPU/tools/handoff_regs.py" diff "$out/pongo.log" "$out/linux.log"
