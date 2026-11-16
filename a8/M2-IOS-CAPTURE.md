# J96 GPU M2: first iPadOS ground truth (16 Nov 2026)

iPadOS 15.8.3 (19H386), booted rootless with palera1n beta3 (`--cli -l -T -d`). Root shell over the
binpack telnetd (`ios-capture/tsession.py`). Capture data is Apple compiler/driver output: it
stays on the iPad (`/var/mobile/gpu-capture`) and this host, and is not quoted here.

## Results

- **kprobe (map queries only):** `task_for_pid(0)` succeeds, so the kernel task port is available.
  `TASK_DYLD_INFO` is zero. The kernel map from the unslid base shows one 2.5 GiB region at
  `0xfffffff012000000` with protection 0, even with `mach_vm_region_recurse` (depth 0, not a
  submap). So the slide cannot be found from the map. Reading an unmapped address panics (9 and
  16 Nov), so no kernel read was attempted. palera1n's `-d` output does not print the slide.
- **Metal from a telnet process:** the device opens ("Apple A8 GPU"), but `newCommandQueue`
  returns nil. iOS 16 API (`gpuResourceID`) does not exist here; the tool now guards it.
- **Metal from the foreground `GPUCapture.app`** (registered with the binpack's
  `uicache -p /var/tmp/GPUCapture.app`): `newCommandQueue` was nil until the entitlements listed
  AGXG4P's own user clients (`AGXCommandQueue`, `IOAccelCommandQueue2`, `AGXSharedUserClient`,
  contexts and more; commit `ba9b2a4` on `a8-ios-capture`). Then **all three compute command
  buffers completed (status 4)**: `store_marker` wrote `0x1357`, `store_marker2` wrote `0x2468`,
  `empty_kernel` left the buffer alone. There were 41 IOConnectCall* calls. Pre/post dumps of 22
  to 25 GPU-shared regions per kernel (34 MB) are in `/var/mobile/gpu-capture/k{0,1,2}_{pre,post}`
  and `index.txt`.
- **Shader ISA (the plan's M2 go/no-go):** the A10 (G9P) offline-compiled needles match inside a
  driver GPU heap region (tag 100). In `k0_pre/r_00105698000.bin`:
  - At `+0x1300` the store kernel begins with the A10 `store_marker` 8-byte prefix and continues
    for about 0x50 bytes of code, followed by a run of `0x00c0` halfwords and a `0x8000` end word.
  - At `+0x40` the empty kernel matches the A10 `empty_kernel` encoding, followed by `0x00c0`
    padding.

  **This is Apple's USC encoding (the 0xc000 padding / 0x8000 end pattern), apparently the same
  family as the A10's G9P, not stock Rogue.** INFERRED from two kernels and their first bytes;
  a per-instruction comparison against the A10 captures and `applegpu` is next.

## Pulled and compared (16 Nov)

The capture was pulled to the host: tar plus zstd on the iPad (36 MB to 67 KB), then `xxd -p` over
telnet, sha256 `40124395…a1d1` on both sides. It is stored at
`~/Projects/j96-omarchy/private/gpu-capture-20261116/` (private, mode 0700, not in git).

- **USC frame matches the A10.** The A10 `ISA.md` says code is 16-bit granular and ends with `0x8000`
  at the start of a 64-byte block, after `0xc000` padding. On the A8 the store kernel's `0x8000`
  is at `+0x1380`, a 64-byte boundary, after `0xc000` padding. The empty kernel's bytes equal the
  A10 native empty kernel.
- **The dispatch layer does not match word for word.** None of these A10 sequences from
  `COMPUTE.md` occur in any A8 dump:
  - the CDM record start `0x2103, 0x800, 0x3f00`;
  - the PDS program `c2c00002 d3000000 f0000a01 fc000002`;
  - the DMA-only PDS task `f0001000 f4001808 d3000000`.

  The only `0x40000000 0 0x80000000` hits are at unaligned offsets (noise). This fits the A8's
  older firmware/command interface (AGF channels, M0). The shader side may carry over from the A10
  work; the submission/PDS layer needs its own RE, with these dumps as ground truth.

## Next

2. Compare the store kernel with the A10 store_marker capture instruction by instruction.
3. Find the compute dispatch records (the `out*_va` needle hits) and compare them with the A10's
   CDM records.
4. The kernel slide (for the PMGR/Fender read) still needs another source.
