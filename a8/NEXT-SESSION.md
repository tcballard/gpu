# Next session — J96 GPU bring-up, written 16 Nov 2026 07:40

Read first, in order: `GPU-PLAN.md`, `M0-STATIC-RE.md`, `M1-BRIDGE-FINDINGS.md` (newest sections
last: "PMGR clock snapshots, 12 and 16 Nov"), `m1-clock-wide-20261116.log`, `probe/README.md`,
`ios-capture/README.md` (Status section).

## Where it stands

- **M0 (static RE): done.** The iOS power-on, register windows, IRQs, kick and META boot are known.
- **M1 (core ID read): blocked.** The first RGX read (`RGX+0x20`) freezes the SoC every time.
  These are all ruled out: ps_gfx (works), the GFX bridge settings (written and read back), AUTO_ENABLE
  (does not stick), Fender GPC 1 (reached), timing (nothing changes over 1 s), and a Fender clock table
  (none).
- **Leading hypothesis (INFERRED): the GFX PLL never starts.**
  - PMGR clock page 5 (`pmgr+0x5000`, PA `0x20e005000`) looks like neither the running pages (1, 4)
    nor the idle ones (0, 2, 3): `+0 = 0x1010`, `+4 = 0`.
  - At GPC 1, `+0x1c200` goes `0x80000000 -> 0x80110100` and page 5 `+0x1c` briefly gains bit 27,
    but `+0`/`+4` never change.
  - J81 under iPadOS reads page 5 `+4 = 0x40000000` after the GPC poll.
  - The GFX perf-slot table (`pmgr+0x1c000`) is populated and correct (365/450/550/600 MHz, and
    the voltage codes match the ADT).
- **M2 (iPadOS ground truth): first attempt panicked.**
  - The palera1n boot works (recipe below).
  - The root telnet session works, on Darwin 21.6.0 T7000.
  - The old `kprobe` panicked the iPad on 9 Nov (previously unrecorded) and on 16 Nov. A read of an
    UNMAPPED kernel VA through palera1n's kernel task port is a data abort
    (`panic-full-2026-11-09-230600`: far = `0xfffffff007004000`, the unslid base).
  - So the port is obtainable. The slide changes per boot (`0x1e400000`, `0x1ee00000` seen).
- **Not started:** M3 onwards, display track D0.

## Uncommitted local changes (not on GitHub)

- `probe/apple-j96-gpubridge.c`: new token `gpu-pmgr-clock-wide`. Built:
  `probe/apple-j96-gpubridge.ko`, sha256 `3b9f9aa6…59cbb1`.
- `ios-capture/kprobe.c`: the safe kprobe.
  - `mach_vm_region` checks before any read.
  - `kprobe regions` lists the kernel map and reads nothing.
  - The slide search reads only 2 MiB-aligned region starts.
  - `TASK_DYLD_INFO` is printed.
  - stdout is unbuffered.
  - **Not built (no iOS SDK on this host); never compiled, so expect small fixes.**
  - **Do not run the old `ios-capture/build/kprobe`.** The pre-fix source is at
    `/tmp/claude-1000/-home-tcballard/56bd8a66-06fe-4c4c-b95d-4d3debddbbc0/scratchpad/kprobe.c.orig`,
    which may be gone.
- `ios-capture/README.md`, `probe/README.md`, `M1-BRIDGE-FINDINGS.md`, `m1-clock-wide-20261116.log`.
- The GitHub mirror (`~/Projects/orchard-gpu-fork`, `tcballard/gpu`) has none of this yet.
  - Branch `a8-bringup`, folder `a8/`: docs, logs, probe.
  - Branch `a8-ios-capture`, folder `tools/a8/ios-capture/`: CI builds on push to that path.
  - `gh` needs `-R tcballard/gpu` (its default is upstream OrchardLinux/gpu).
  - Ask the user before pushing.

## Update, 16 Nov evening

- **kprobe fix pushed:** commit `111fac5` on `a8-ios-capture` (kprobe.c + tsession.py), CI run
  43919266598. Download artifact `j96-ios-capture` into `ios-capture/build/` and check
  `SHA256SUMS`. If the build failed, fix the compile errors (never compiled before).
- **Static search done** (`M1-BRIDGE-FINDINGS.md`, last section). No kernel code writes page 5 or
  `+0x1c200` by literal. `pd_ignore_unused` is already set. DWI is used by the backlight, so it is
  largely configured.
- **DWI checked on hardware (16 Nov evening): ruled out.** `+0x50` is 0 on Linux, but writing iPadOS's `+0x4` and `+0x50` does not start page 5 (`m1-dwi-ios-clock-20261116.log`).
- **New static target:** AppleT7000PMGR `initDriver` / `setPerfState`
  (`__TEXT_EXEC 0x670b000-0x670d3e0`).

## Next steps, in order

1. **Rebuild kprobe.** Either copy `ios-capture/kprobe.c` into the fork's `tools/a8/ios-capture/`,
   commit on `a8-ios-capture` and push (user OK needed), then download artifact `j96-ios-capture` and
   check `SHA256SUMS`. Or the user builds on their Mac (full Xcode plus `brew install ldid`, then
   `sh build.sh`; do not copy `build/`, which holds an SSH key).
2. **Static search (no iPad needed).** In the 15.8.3 kernelcache, find what writes `pmgr+0x5000..0x503c`
   (page 5) or `+0x1c200`/`+0x1c300`.
   - Candidates: ApplePMGR start `0x66dc7a4`, untraced `0x66f2040` (has delays) and `0x66f47a0`,
     and any kext mapping pmgr reg[0].
   - Kernelcache: `~/Projects/j96-touch-20261030/downloads/kernel/19H386__iPad5,1/kernelcache.release.iPad5,1_2`.
   - Tools: `tools/kc.py`, `tools/dis.py`.
   - If no writer exists, it is iBoot or hardware, and the iPadOS read (step 3) is the route.
3. **iPadOS session with the new kprobe.**
   - Run `kprobe regions` first. Then plain `kprobe`, only if the regions look sane (the kernel text
     near `0xfffffff007004000 + slide`).
   - Then write a tool that reads page 5 and `+0x1c200` through ApplePMGR's own mapping with the GPU
     active. Never point kprobe at MMIO directly.
   - `gpu-capture --light` for a first shader capture needs no kernel access.
4. Check `mattonik/ipad-nixos` `research/` for updates since 583540b (11 Nov); J81 has the same hang.
5. **Do not write PMGR page 5 by hand** until the sequence and the GFX voltage are known.

## Boot recipes

- **Linux:** `cd ~/Projects/j96-omarchy && ./j96-boot`.
  - Serial: `/dev/ttyACM0`.
  - Helpers in `gpu/tools/serial/`:
    - `run.py SECS` runs stdin as one command.
    - `push.py SRC DST` writes `DST.b64`; then `base64 -d` it.
    - `stream.py TOKEN SECS LOG` runs a probe token and streams its lines.
  - Before a token: `systemctl stop getty@tty1; chvt 1; printf "\033[9;0]" > /dev/tty1`.
  - Then `echo 201000000.gpu-probe > /sys/bus/platform/drivers/apple-j96-gpuprobe/unbind;
    insmod /run/apple-j96-gpubridge.ko`.
  - Each token runs once per module load.
- **iPadOS jailbreak (palera1n):**
  1. Enter DFU by hand: Home + Power for 8 s, release Power, keep Home for 8–10 s; the screen stays
     black. beta3's own DFU timer gets the timing wrong.
  2. Then: `cd ~/Projects/j96-pongo-probe-20261030 && sudo env -i PATH=/usr/bin:/bin LANG=C ./palera1n-beta3 --cli -l -T -d`.
  - Rootless `-l` only. NEVER `-f`, `-c` or `-B`: the storage is repartitioned for Linux.
  - Pitfalls:
    - palera1n v2.4 on PATH does not work on this iPad, and it switches off auto-boot (stuck in
      recovery; fix with `sudo palera1n -n`).
    - Without sudo, palera1n cannot see recovery or DFU.
    - Without `--cli`, beta3 opens a TUI, and under `env -i` the TUI dies for lack of TERM.
  - Once USB shows `05ac:12ab`, use `gpu/ios-capture/tsession.py run '...'` / `push` / `kprobe`.
    It is telnet through iproxy; there is no `/bin/sh` on rootless 15.x, so `session.py`'s SSH fails.
- **Panic and reset reports** (normal iPadOS, unlocked):
  `bash ~/Projects/j96-pongo-probe-20261030/collect-ios-reports.sh`, output in
  `ios-reports-*/panic/`. The 16 Nov panic report had not appeared by 07:25.

## Safety rules (unchanged)

- No RGX access while the clock question is open (it freezes the SoC).
- No AIC SW_SET/CLR writes, no PMGR perf, voltage or other-domain writes.
- Apple data (dumps, panic logs, firmware, shaders) stays out of all repositories.
- Hardware steps only with the user present. A freeze is recovered by DFU boot.
