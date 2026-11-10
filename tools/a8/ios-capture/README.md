# J96 iPadOS capture tools (plan M2)

Ground truth from iPadOS 15.8.3 on the iPad mini 4 (J96, A8), for two questions:

1. **Why the first RGX register read hangs under Linux** on this chip: what Fender (the GPU
   power controller) and the GFX bridges hold under a working iPadOS. Needs kernel memory access. `kprobe` is step 1 only: it
   tests whether a root process can read kernel memory on this jailbreak boot.
2. **The shader ISA**: compiled shaders and job data, captured from the
   tool's own process memory with `gpu-capture` / `GPUCapture.app`.

**Status: written, NOT built and NOT run.** There is no Mac here, so nothing has been compiled
(no iOS SDK on the Linux host). Expect build fixes on the first CI run.

## Files

| File | What | Origin |
|---|---|---|
| `kprobe.c` | Read-only kernel-memory probe: `task_for_pid(0)`, then host special port 4; finds the kernel slide by reading the Mach-O magic; `kprobe read ADDR LEN` hex-dumps kernel virtual memory | new |
| `capture.m`, `iohook.m`, `app.m` | Metal compute/render jobs, then dumps of the process's GPU-shared memory and its IOKit calls | copied unchanged from OrchardLinux/gpu `tools/a10/ios-capture` at the commit in `UPSTREAM-COMMIT` (GPL-2.0-or-later) |
| `entitlements.plist` | The A10 set plus `task_for_pid-allow`, `com.apple.system-task-ports` and the older IOAccel user-client names | adapted |
| `session.py` | Host side: SSH key through palera1n's telnetd, key-only dropbear on the iPad's loopback, then push/run/pull over usbmux | adapted from the A10 `session.py` |
| `build.sh` | Builds all three for `arm64-apple-ios15.0`, strips, signs ad hoc with `ldid` | adapted (the A10 scripts target iOS 16) |
| `../../../.github/workflows/a8-ios-capture.yml` | GitHub Actions workflow (macOS runner, manual trigger) that runs `build.sh` and uploads `build/` | new, modelled on resize-apfs `j96-ios15.yml` |

## Known gaps

- `capture.m` is the A10 tool as is. Its needle scan looks for A10 (G9P) shader code, which
  will not match on the A8; use `--light` (no needle scan; the full scan once panicked the
  A10) and compare regions by hand. Whether the A10's entitlement and foreground findings hold
  on iPadOS 15 / AGXG4P is unverified.
- `kprobe` proves or disproves kernel *virtual* memory reads only. Reading the Fender and
  bridge registers needs a further tool: find AGXG4P's and ApplePMGR's own mappings and read
  through them.
  Whether a device mapping can be read through the kernel task port without a panic is not
  known. That tool is not written; it depends on what `kprobe` shows.
- The Apple Wiki lists palera1n as enabling the kernel task port on iOS 15.0–16.3. Nothing
  found confirms it for rootless 15.8.3 on this device.

## Build (no Mac: CI)

The `J96 iOS capture tools` workflow runs on each push to this branch (or by hand from the
Actions tab). Download its
`j96-ios-capture` artifact. Check `SHA256SUMS`. On a Mac: `sh build.sh`.

## Run (iPad)

- **Rootless only** (`palera1n -l`, the default). Never `-f`, `-c` or `-B`: they create or
  use a fakefs volume in the APFS container, and this iPad's storage is repartitioned for
  Linux.
- Boot with `palera1n -l -T` (root telnetd on port 46), put the CI artifact in `build/`,
  then from the host (`session.py`, adapted from the A10 one; needs `iproxy` and `ssh`):
  ```sh
  ./session.py kprobe               # push build/kprobe and run it; the RESULT line says
                                    # whether kernel memory is readable
  ./session.py shell 'uname -a'     # any root command
  ```
  `gpu-capture` is not ready for iPadOS 15: it calls `gpuAddress` and `gpuResourceID`,
  which need iOS 16.
- `kprobe` never writes kernel memory. Do not point `kprobe read` at a device (MMIO) address.

Apple data (dumps, captured shaders) stays out of any repository.
