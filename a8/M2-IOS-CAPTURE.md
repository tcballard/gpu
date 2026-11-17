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

## Dispatch-layer decode, first pass (16 Nov, k0 = store_marker, pre-commit)

The A10 references are the documented words in OrchardLinux/gpu `a10/COMPUTE.md`. A8 addresses
are GPU VAs.

- **Argument table entry matches the A10.** At GPU-shared region `0x10596c000` `+0x6058` sits
  `{u64 0x1_0029c000 (the output buffer's GPU VA), 0x00010001}`. The A10 entry is
  `{0x204000, 0, 0x10001}`. The region's GPU VA is `0x1_002bc000`.
- **DMA-only PDS data matches the A10.** At region `0x105964000` `+0x40`:
  `{u64 0x1_002c2058 (that entry), u64 0x1_002c2060, 0x10000002, 0x90004001}`. The A10 data is
  `{0x300001000, 0x300001010, 0x10000002, 0x90004001}`: the same layout and control words. The
  same region also holds two more PDS-data-like blocks at `+0x0` and `+0x20`
  (`{0x1_002bc000, 0x1_002bc010, 0x80004002, …}`).
- **PDS program encoding matches the A10.** In the shader heap `0x105698000` `+0x1480`:
  `c2c00002 d3000000 f0024001 fc000002 d3000000`. The A10 has `c2c00002 d3000000 f0000a01
  fc000002 d3000000`, so only the operand word differs. Shorter variants are at `0x1056c8000`
  `+0x100` and `+0x200`.
- **CDM records: not found yet.** The A10 record start `0x2103, 0x800, 0x3f00` does not occur.
  Region `0x105950000` starts with a header-like block `{0x10000, 0x120, 4, …}` and a list of
  GPU VAs (`0x1_002b0000`, `0x1_002bc000`..`0x1_002bc00c`, `0x1_002c2010`) with
  `{offset, 0x28000…, 0x28800005}`-style entries. It may be the command buffer's segment list.

So far the A8 matches the A10 in the USC, PDS and binding layers. The differences are expected
where the firmware ABI is: the command records and how they are queued.

## Dispatch-layer decode, second pass (17 Nov)

**The pipeline heap (region `0x105698000`, 64 KiB) has the A10's layout.** A10 references are from
`a10/COMPUTE.md` ("Native compute PDS sits next to its USC code", third and fourth captures).

| Item | A8 (k0_pre) | A10 |
|---|---|---|
| Empty kernel | USC at heap+0x40; PDS data at +0x100 `{0x40, 0x10}`; PDS code at +0x120 `f4000002 d3000000` | the same offsets and words |
| Store kernel PDS data | +0x1500 `{0x1300 (USC offset), 0x10 (temps), 0x80000000 (DOUTW value), 0}` | `{0x20c0, 0x10, 0x80000000, 0}` |
| Store kernel PDS code | +0x1480 `c2c00002 d3000000 f0024001 fc000002 d3000000` | `c2c00002 d3000000 f0000a01 fc000002 d3000000` |
| DMA-only (binding) PDS | code +0x1400 `f0040000 f4060100 d3000000` (two DOUTDs); data `{src0, src1, 0x10000002, 0x90004001}` | `f0001000 f4001808 d3000000`; the same data layout |

Only operand values differ (offsets, DOUTD/DOUTW operands). The PDS exec base and USC code base are
this heap on both.

**CDM control stream: found (correcting the first reading of this pass).** Unlike the A10, the A8's
stream sits in user-visible GPU memory before commit. It is in region `0x10595c000` (GPU VA
`0x1_002b0000`; CPU-to-GPU delta `0x56ac000`, the same as the output buffer's). At commit the
terminate `0x80000000` is appended at `+0x8c`, and the submit bookkeeping block (`0x105950000`
`+0x98`) gets the pointer `0x1_002b008c` to it, which is how the stream was found. The
region is reused per command buffer.

**Records are 7 words: `k0, k1 (PDS data offset), k2 (PDS code offset), 0, 0, 0, 0x40000000`.**
The A10 uses 8 (a trailing 0), and its notes record that 7-word records failed there, so this
is a real format difference. Offsets are relative to the pipeline heap (the PDS/USC base).

| Record | store_marker (k0) | store_marker2 (k1) | empty_kernel (k2) | Meaning (A10 analogue) |
|---|---|---|---|---|
| 0 | `40008 28042 1400` | `40008 28042 1680` | `4 28042 18c0` | DMA-only PDS: loads the binding (A10 record 0, `k0 4`) |
| 1 | `2106 1500 1480` | `2106 1780 1700` | `2106 19c0 1940` | the kernel (A10 `0x2103, 0x2280, 0x2200`) |
| 2–4 | `40008 1488a 14800`, `4 1418a 14100`, `7 14214 14200` | the same | the same | Metal-internal (A10 records 2–6) |
| end | `0x80000000` at `+0x8c` | the same | the same | terminate, appended at commit |

- Record 1's `k1`/`k2` are exactly the PDS data/code found in the heap (`+0x1500`/`+0x1480` for k0).
- `k0 = 0x2106`, where the A10 has `0x2103` (fence, usc_target, pds_temp 1, unified 2). The low
  bits differ; decode TBD.
- Record 0's `k0` is `0x40008` for kernels that bind a buffer and `4` for the empty kernel
  (INFERRED: `0x40000 | 8` describes the DMA load).
- **Field decode: stock Rogue CDM.** Mesa `src/imagination/csbgen/rogue/cdm.xml`, read from the
  OrchardLinux/mesa fork. The 7 words are KERNEL0, KERNEL1, KERNEL2, KERNEL3–5 and KERNEL8;
  KERNEL6/7 and 9–11 are absent because `indirect_present` and `global_offsets_present` are clear.
  - KERNEL0 `0x2106` = block_type 0 (compute), usc_common 0, usc_unified 2, pds_temp 1, pds_data 1
    (16 bytes, the kernel's PDS constants `{0x1300, 0x10, 0x80000000, 0}`), usc_target 1, fence 0.
    The A10's `0x2103` has pds_data 0 and fence 1.
  - Record 0's `0x40008` = usc_common 1 (one 64-byte chunk, the binding) and pds_data 2 (32 bytes,
    the DMA data). The empty kernel's `0x4` = pds_data 1, no common store.
  - KERNEL1 = data_addr (bits 31:4), sd_type (3:2), usc_common_shared (1). Record 0's `0x28042`
    has usc_common_shared set, as the A10 notes say for theirs.
  - KERNEL2 = code_addr (31:4), one_wg_per_task (0).
  - KERNEL3–5 = workgroup counts minus one (0, 0, 0 = 1×1×1).
  - KERNEL8 `0x40000000` = max_instances 8, workgroup size 1×1×1 (minus one).

  So the A10's 8-word record is an Apple extension of the newer core; **the A8's CDM records are
  plain Rogue, and Mesa's packers describe them.** Addresses are relative to the PDS/USC heap
  base. Record 0's data at `+0x28040` lies outside the 64 KiB pipeline heap, so the PDS data heap
  is larger or separate (INFERRED; base not yet pinned).
- The kernel side then queues the CL work: `0x66a33fc` calls `0x669cb30`, which writes a 20-byte
  CL ring entry `{2, fw-VA of the queue block [queue+0x120] (FW vt+0x1a8), arg}` at `[FW+0x300]`
  (ring control `[FW+0x2f8]`, write index +0x10, 8-bit). Then `dmb`, the Fender pre-kick, and
  `MTS_SCHEDULE = 0x12`. How the queue block references this stream is still open.

## Light-mode capture: the submit call (17 Nov)

GPUCapture.app in light mode (flag file `/var/mobile/gpu-capture-light`; one kernel, two dispatches
in one command buffer). Both completed (`0x1357`). Saved privately in
`~/Projects/j96-omarchy/private/gpu-capture-20261117-light/`.

- **During commit there is exactly one IOConnect call:** connection `0xa113` (the command-queue
  user client, INFERRED), selector 1, a 32-byte struct input, no output, `kr 0`. No traps.
- **The payload is** `{u32 0, u32 1, u32 2, u32 1, u64 0x2_82014ea0, u64 0x2_820171b0}`. The two
  u64 values are userspace heap pointers, so the kernel copies the command-buffer description in
  from process memory. Light mode dumps no memory, so their targets were not saved.
- The likely target is the segment-list-shaped block in shared memory (`0x105950000`:
  `{0x10000, 0x120, count, …}`, which gets its count and the CDM terminate pointer at commit).
  Static next step: AGXG4P / IOAcceleratorFamily's command-queue selector 1
  (`IOAccelCommandQueue2` submit) to the CL ring entry above.

### Pointer dumps of the submit struct (17 Nov, runs 2–3)

The hook now logs at entry (`28b385e`) and dumps what the struct's pointer-looking words point to,
skipping the dyld shared cache. Run 3 (`private/gpu-capture-20261117-light3/`):
`call 000 sync entry conn 0xa21b sel 1 struct_in 32`, struct `{0, 1, 2, 1, u64 0x2_80359410,
u64 0x2_80359620}` (the u64 values are `0x210` apart).

- **The `+0x10` target is an Objective-C object**: nonpointer isa / shared-cache class, retain word
  `0xc3000002`, a heap pointer. One level down there are two pthread mutex signatures
  (`0x4d55545a`, "MUTZ"). No command data.
- **Reading (INFERRED):** the two u64 values are opaque userspace tags (command-buffer objects
  returned with completion), not data the kernel parses. The command data reaches the kernel
  through the shared GPU memory decoded above: the segment-list block (`0x105950000`) and the CDM
  stream (`0x1_002b0000`). The small integers `{0, 1, 2, 1}` are probably a count and
  shared-memory IDs set up by earlier calls.
- So the kernel side to trace is: selector 1 on the command queue, then how it reads the
  segment list from shared memory, then the CL ring entry.

## Next

1. Compare the store kernel with the A10 store_marker capture instruction by instruction.
2. Decode `k0` (`0x2106` against the A10's `0x2103`) and record 0's fields; then follow the CL
   queue block `[queue+0x120]` to the stream address. The light-mode app (flag file
   `/var/mobile/gpu-capture-light`, built 17 Nov) records the IOConnect payloads.
3. The kernel slide (for the PMGR/Fender read) still needs another source.
