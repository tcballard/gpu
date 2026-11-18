# Next session: J96 GPU bring-up (handoff written 17 Nov 2026)

iPad mini 4 (J96, iPad5,1, A8/T7000). Work lives in `~/Projects/j96-omarchy/gpu/`. It is mirrored
to GitHub `tcballard/gpu`: notes, logs and probe in branch `a8-bringup`, folder `a8/`; iOS tools
in branch `a8-ios-capture`, folder `tools/a8/ios-capture/`. Local clone:
`~/Projects/orchard-gpu-fork`. `gh` needs `-R tcballard/gpu`, because its default is upstream
OrchardLinux/gpu.

**Read first:** `GPU-PLAN.md`, `M0-STATIC-RE.md`, `M1-BRIDGE-FINDINGS.md` and `M2-IOS-CAPTURE.md`,
newest sections last in each.

## Where it stands

| Milestone | State |
|---|---|
| M0 static RE of AGXG4P | done |
| **M1 core ID read under Linux** | **blocked.** The first RGX read freezes the SoC: the GFX PLL (PMGR clock page 5, PA `0x20e005000`) never starts. |
| M2 iPadOS ground truth | largely done |
| M3 onwards, display track D0 | not started |

**M1: ruled out so far.**
- On hardware: ps_gfx, the GFX bridge settings (written and read back), AUTO_ENABLE, Fender GPC 1,
  timing, a Fender clock table, unused-domain shutdown (`pd_ignore_unused` is already set), and
  DWI timing (iPadOS's `+0x4`/`+0x50` written, page 5 unchanged).
- Statically: no iPadOS kernel code writes page 5 or the GFX perf area by literal, and no ApplePMGR
  `+0x988` write on the GFX power-on path is missing from Linux.
- J81 (A8X, OrchardLinux/gpu `a8x/`) agrees: under iPadOS, page 5 `+4` bit 30 is set during the
  state-1 poll, and a bare-PongoOS replay stalls just like Linux.

**M1: still open.** LLB-written PMGR pages (`0x20e010000`–`0x20e0140bc`, `0x20e00f208`–`21c`) and
`0x2300c` have not been compared between Linux and iPadOS. Neither have the two conditional
ApplePMGR functions (`0x66f47a0`, `0x66f2040`). The iPadOS read of page 5 needs the kernel slide:
`kprobe`'s map queries cannot find it, and palera1n does not print it.

**M2, decoded from the captures:**
- The USC shader encoding, the pipeline-heap layout, the PDS programs and data, and the
  argument-table/binding DMA all match the A10.
- The **CDM records are stock Rogue, 7 words** (KERNEL0/1/2/3–5/8, Mesa `cdm.xml`). The A10's 8th
  word is an Apple extension.
- The **submit** is IOAccelCommandQueue2 selector 1: `{0, count}` plus
  `count × {cmdbuf shmem ID, segment-list shmem ID, tag0, tag1}`.
- The segment-list format is decoded. The kernel path is traced down to AGXG4P's command-queue
  overrides: `+0x668` → `0x66931b8`, `+0x670` → `0x6693234`.

## Next steps: the M1 route (agreed 17 Nov)

The static PMGR route is exhausted. The way forward is a **measured diff of register state between
a working iPadOS boot and a Linux boot, at the same point**, so the missing step shows up as a
value instead of a guess.

1. **Test the pre-kernel assumption (one session, read-only, low risk).** Everything assumes both
   boot paths reach their kernel with identical hardware state, because both go through
   checkm8 → PongoOS. That is unverified: J81's notes say their Linux path records no LLB/iBoot
   handoff.
   - Stop palera1n at the PongoOS shell (`-p` early exit, or j96-boot's Pongo stage, plus
     pongoterm). J81 used Pongo's `peek`; check the command's exact form there.
   - Read: PMGR clock pages 0–5 (`0x20e000000`–`0x20e00503c`), the GFX speed table and control words
     (`0x20e01c000`–`0x20e01c3fc`), the LLB-written pages (`0x20e010000`–`0x20e0140bc`,
     `0x20e00f208`–`0x20e00f21c`), `0x20e02300c`, and every power-state register
     (`0x20e020000`–`0x20e021010`).
   - Take the same snapshot early in Linux: a new read-only token in
     `probe/apple-j96-gpubridge.c`, built like `gpu-pmgr-clock-wide`.
   - **They differ** → something between Pongo and Linux undoes setup: that is the lead.
     **They match** → the missing step happens inside the running iPadOS kernel: go to step 2.
2. **Ask the J81 author for their capture tool. Do not build one here.** (Revised later on
   17 Nov.) The capture itself is still the measurement: GPU clock registers at the point
   where AGXG4P powers the GPU, so the working iPadOS values can be compared with Linux.
   A session that day read only the two public repos below. It stopped when the work turned
   to applying a change to the iPadOS kernel at boot. Nothing was built or written, and that
   approach stays closed.
   - The tool is not in the public repo. The write-ups place the payload in their private
     artifacts (`artifacts/live/private/j81-ios-agx-postpower-panic/`). Ask mattonik for it.
   - Write-ups worth sending with that ask, both in the ipad-nixos checkout:
     `research/probes/j81-agx-postpower-panic/README.md` and
     `research/2026-11-16-j81-agx-postpower-page5-result.md`.
   - Once the tool is in hand, dump wide at AGXG4P's state-1 poll (`0x6695a3c`–`0x6695a48`,
     M0 section 3.1): all six clock pages, the speed table and control words, the LLB pages,
     `0x2300c`, all power-state registers, and the clock-mux area around `pmgr+0x10000`.
     Take the identical dump on Linux after GPC 1, before any RGX access, then diff.
   - Panic logs are Apple data. Collect them with
     `bash ~/Projects/j96-pongo-probe-20261030/collect-ios-reports.sh` (normal iPadOS,
     unlocked) and keep them in `private/`.
3. **Cheap static checks alongside:** any kext other than PMGR that touches GPU-related hardware
   before AGXG4P's probe; the memory controller is one example (the sgx node's unexplained `gfx-qos`
   property). Also the two conditional ApplePMGR functions (`0x66f47a0`, `0x66f2040`) and
   AppleT7000PMGR `initDriver`/`setPerfState` (`0x670b000`–`0x670d3e0`).
4. **Do not write guessed values** to page 5, the speed table or any voltage. Without the real
   sequence it is more likely to crash or stress the chip than to fix anything.

If the diff shows a clear difference, M1 could fall within about a week of it. If the states match
at that point, widen the dump to the memory controller, the fabric and the PMU.

## Other work (when M1 is waiting)

- **Static, channel blocks decoded (17 Nov, later):** three kicks, types 0/1/2, opcodes 0/1/2,
  `MTS_SCHEDULE` `0x10`/`0x11`/`0x12`. The ring's second word is the fw-VA of block A
  (`[channel+0x120]`), and block A `+0x00` is the fw-VA of block B. The ring `arg` is block B
  `+0x40`. Detail in `M2-IOS-CAPTURE.md`. Still open: where buffer `a` is written into block B,
  and what `+0x40` counts.
- **M2:** compare the store kernel instruction by instruction with the A10's
  `applegpu_g9p`/`metal-tt` output.

## Tools and data

- **Reference checkouts (17 Nov, read only):**
  `~/Projects/j96-omarchy/downloads/ext-20261117/ipad-nixos/` is mattonik/ipad-nixos `main` at
  `0f42b65` (16 Nov 2026, tracking origin). `…/palera1n-src/` is palera1n `v3.0.0-beta.3` at
  `42d6506` (detached tag checkout). `src/pongo_helper.c` (`send_full_pongo_jailbreak`) is the
  boot command sequence.
- **Kernelcache:** `~/Projects/j96-touch-20261030/downloads/kernel/19H386__iPad5,1/kernelcache.release.iPad5,1_2`.
- **ADT:** `~/Projects/j96-touch-20261030/private/j96-adt-20261030.bin`.
- **Helpers in `gpu/tools/`:** `kc.py` (segments, VA/file offset), `dis.py KC START END TMPDIR`
  (llvm-objdump), `adt.py`, `adt_pmgr_devices.py ADT tools/`. Full-kernel disassembly takes a few
  minutes; redo it in the session scratchpad.
- **Kext ranges (`__TEXT_EXEC`):** IOAcceleratorFamily2 `0x664e000`–`0x667d30c`; AGXG4P
  `0x667e000`–`0x66c3370`; ApplePMGR `0x66d6000`–`0x670aa4c`; AppleT7000PMGR
  `0x670b000`–`0x670d3e0`.
- **Captures (Apple data, never commit):** `~/Projects/j96-omarchy/private/gpu-capture-20261116/`
  (full mode, 3 kernels, pre/post GPU regions) and `gpu-capture-20261117-light{,2,3}/` (the submit
  call and its pointer dumps).
- **iOS tools:** `gpu/ios-capture/build/` holds the CI build of 17 Nov. CI uses the **Intel**
  runner (`macos-15-intel`), because the arm64 runners were cancelled for capacity. Builds run on
  every push to `a8-ios-capture`.
  - `GPUCapture.app` must run as a foreground app: copy it to `/var/tmp/GPUCapture.app`, run
    `/cores/binpack/usr/bin/uicache -p /var/tmp/GPUCapture.app`, and the user taps it. The
    entitlements include AGXG4P's command-queue user clients.
  - Full mode writes to `/var/mobile/gpu-capture`. If `/var/mobile/gpu-capture-light` exists, it
    runs light mode instead (IOConnect payloads plus pointer dumps) into
    `/var/mobile/gpu-capture-light-out`.
  - Pull results by packing on the iPad (`tar` plus `zstd -19`), then `xxd -p` over telnet; see
    the snippet history in `M2-IOS-CAPTURE.md`.
  - `kprobe regions` is safe (map queries only). **Any kernel read of an unmapped address panics
    the iPad.**

## Boot recipes

- **Linux:** `cd ~/Projects/j96-omarchy && ./j96-boot`.
  - Serial console: `/dev/ttyACM0`.
  - Helpers in `gpu/tools/serial/`: `run.py SECS`, `push.py SRC DST` (then `base64 -d`), and
    `stream.py TOKEN SECS LOG`.
  - Before a probe token: `systemctl stop getty@tty1; chvt 1; printf "\033[9;0]" > /dev/tty1`.
    Then unbind `201000000.gpu-probe` from `apple-j96-gpuprobe` and `insmod
    /run/apple-j96-gpubridge.ko`.
  - Each token runs once per load. Afterwards, rmmod, rebind, and `systemctl start getty@tty1`.
- **Jailbroken iPadOS (palera1n):**
  1. Enter DFU by hand: Home + Power for 8 s, release Power, keep holding Home for 8–10 s. The
     screen stays black.
  2. Then: `cd ~/Projects/j96-pongo-probe-20261030 && sudo env -i PATH=/usr/bin:/bin LANG=C
     ./palera1n-beta3 --cli -l -T -d`.
  - Rootless `-l` only. **Never `-f`, `-c` or `-B`**: the storage is repartitioned for Linux.
  - Pitfalls:
    - palera1n v2.4 on PATH does not work on this iPad and switches off auto-boot (fix with
      `sudo palera1n -n`).
    - It needs sudo.
    - Without `--cli`, beta3 opens a TUI.
  - Use `gpu/ios-capture/tsession.py run '...'` / `push` / `kprobe regions`. This is telnet over
    iproxy; rootless 15.x has no `/bin/sh` for SSH.
- **Panic reports** (normal iPadOS, unlocked):
  `bash ~/Projects/j96-pongo-probe-20261030/collect-ios-reports.sh`.

## Rules

- No RGX access under Linux while the clock question is open; it freezes the SoC.
- No AIC SW_SET/CLR writes, and no PMGR perf, voltage or other-domain writes.
- Apple data (dumps, captures, panic logs, firmware) stays in `private/`, never in a repository.
  Notes describe patterns, not dumps.
- Hardware steps only with the user present; a freeze is recovered by a DFU boot.
- Ask before pushing, and before any upstream PR.
  - Orchard's `docs/compatibility.md` is generated from `devices/j96/device.toml`. Propose updates
    when a J96 feature changes state.
  - PR OrchardLinux/orchard#155 (J96 feature states) is open.
  - Orchard's CHANGELOG lines need the user's approval of the exact text.
