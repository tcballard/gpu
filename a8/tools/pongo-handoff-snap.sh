#!/usr/bin/env bash
# M1 route step 1 (17 Nov 2026): read-only PMGR snapshot at the PongoOS shell.
#   gpu/tools/pongo-handoff-snap.sh
# Needs the iPad sitting at the Pongo shell (USB 05ac:4141), as left by cold-probe.py --boot
# (step 3 of ./j96-boot). Sends only "peek" lines (32-bit reads, list from handoff_regs.py)
# through the hash-pinned, identity-locked pongoterm, then exits; Pongo stays at its shell,
# so dev-image/scripts/boot.sh can continue the same boot into Linux.
# The log is Apple hardware data: it goes to ~/Projects/j96-omarchy/private/ only.
set -euo pipefail
umask 077
GPU=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=$(cd -- "$GPU/.." && pwd)
DEV=$ROOT/dev-image
fail() { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }
[[ $EUID != 0 ]] || fail 'Run as your normal user; pongoterm is started with sudo.'
# shellcheck source=../../dev-image/scripts/identity.sh
source "$DEV/scripts/identity.sh"
(cd "$DEV" && grep ' artifacts/pongoterm$' artifacts/SHA256SUMS | sha256sum -c --quiet -) \
    || fail 'pongoterm hash mismatch.'
apple_devices
[[ ${#APPLE[@]} == 1 ]] || fail 'Connect exactly one Apple device.'
port=${APPLE[0]}
[[ $(<"$port/idProduct") == 4141 ]] || fail 'The iPad is not at the Pongo shell (need 05ac:4141).'
serial=$(<"$port/serial")
parse_identity "$serial" || fail 'Pongo identity is not J96.'
[[ $ID_ECID == D713C286910A6 ]] || fail 'This is not the selected Mini 4.'
out=$(mktemp -d "$ROOT/private/handoff-snap-$(date +%Y%m%d-%H%M%S)-XXXX")
python3 -I "$GPU/tools/handoff_regs.py" pongo-cmds > "$out/pongo-cmds.txt"
printf 'Sending %s peek lines. If the output stops, the last "peek" line names the read that hung;\nthen leave the iPad as it is and tell Claude.\nLog: %s/pongo.log\n' \
    "$(wc -l < "$out/pongo-cmds.txt")" "$out"
sudo env J96_USB_BUS="$(<"$port/busnum")" J96_USB_ADDRESS="$(<"$port/devnum")" \
    J96_USB_SERIAL="$serial" timeout 300 "$DEV/artifacts/pongoterm" \
    < "$out/pongo-cmds.txt" 2>&1 | tee "$out/pongo.log" | grep --line-buffered -E '(0x20e0(05004|1c200|20320|10000|14000):|\[|ERR)' || true
sudo chown -R "$(id -u):$(id -g)" "$out"
got=$(grep -cE '0x20e0[0-9a-f]{5}: ' "$out/pongo.log" || true)
printf '\n%s of %s words read. Log: %s/pongo.log\n' "$got" "$(wc -l < "$out/pongo-cmds.txt")" "$out"
[[ $(<"$port/idProduct") == 4141 ]] && echo 'The iPad is still at the Pongo shell.' || echo 'WARNING: the iPad left Pongo.'
