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
  CL ring entry `{2, fw-VA of the AGXChannel block [channel+0x120] (FW vt+0x1a8), arg}` at
  `[FW+0x300]` (ring control `[FW+0x2f8]`, write index +0x10, 8-bit). Then `dmb`, the Fender
  pre-kick, and `MTS_SCHEDULE = 0x12`. The submit path does not fill that block; see below.

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

## Kernel-side submit path, static (17 Nov; READ, single analyst)

iPadOS 15.8.3 kernelcache. Kexts: IOAcceleratorFamily2 (`__TEXT_EXEC 0x664e000–0x667d30c`) and
AGXG4P (`0x667e000–0x66c3370`).

1. **Method table.** IOAcceleratorFamily2 `__DATA_CONST 0x6f2e7b0`, 6 entries. Selector 1 =
   `0x66738b8`, 0 scalars, variable struct.
2. **Selector 1 (`0x66738b8`).** It requires `(size − 8) % 24 == 0` and `(size − 8) / 24 ==
   header[1]`, then calls `0x6674590(queue, struct)`. The struct is a header `{u32 0, u32 count}`
   plus `count` entries `{u32 a, u32 b, u64 tag0, u64 tag1}`. Our capture: `a = 2, b = 1`.
3. **`0x6674590`** locks, then for each entry calls `0x6674994(queue, a, b, tag0, tag1)`, with a
   wait through vt `+0x680` and kdebug points `0x85020080/84`.
4. **`0x6674994`** creates a command-buffer object (device vt `+0x5c8`, kept at
   `[queue+0x608]`), initialises it with `[queue+0x580]` and `tag1` (vt `+0x88`), calls
   **`0x66764a4(queue, a, b)`**, and queues completion events with `tag0` (`0x665c128`). So the
   tags are completion tags, as the capture suggested.
5. **`0x66764a4`** resolves `a` and `b` as **shared-memory IDs** in the queue's namespace
   (`0x6665c58` on `[queue+0x5b8]`; a missing ID gives status 9). It takes each buffer's base and
   length, marks buffer `b` busy (`[+0x70] = 1`), and **walks a segment list in buffer `b`**.
   Each record's word `+0xc` holds bit 31 = last, bit 30 = flag, bits 29:0 = size.
   - **Type 0, segment:** vt `+0x658(queue, a, b)`.
   - **Type 1, range list:** `count` at `+0x8`, `(start, end)` u32 pairs from `+0x10`, each
     checked against buffer `a`'s length, then vt `+0x670(queue, base_a + start, base_a + end)`.
   - **Type 2:** end of list.

   On J96 buffer `b` (ID 1) is the segment-list block seen at CPU `0x105950000`, and buffer `a`
   (ID 2) holds the command data (INFERRED from the captures).
6. **AGX command queue.** The vtable is `0x6f33ee8`; the base IOAccelCommandQueue2 vtable is
   `0x6f2e850`, reached through GOT `0x6f31fb0`. AGXG4P overrides:
   - `+0x668` → `0x66931b8`: wraps the base `0x667554c` in a firmware busy reference
     (FW vt `+0x138(1, [queue+0x8b8])` … `+0x138(0, −1)`);
   - `+0x670` → `0x6693234`, read below.
   - `+0x658` is the base stub `0x6675364`: it stores 0 at `[queue+0x620]` and returns. A type-0
     segment submit does not copy the segment.

   Slots `+0x5c8`, `+0x600`, `+0x680` and `+0x688` are the base's.
7. **`0x6693234` (READ).** It calls the base `+0x670`, which is `ret` at `0x6674d7c`, so the
   `(start, end)` range is dropped on the floor. It then compares `[queue+0x5a0]` with the cached
   copy at `[queue+0x8b8]`. Equal means return. Otherwise it stores the new value at `+0x8b8` and
   sets `[queue+0x8bc]` from `[queue+0x8c0]`, unless `[accel+0xe70]` bit 31 is set and the word at
   `accel+0xfec + index*4` is 0, in which case the index comes from `[accel+0xff4]`. It calls
   `[[accel+0x378] vt+0xe8](&queue+0x5c8)` and tail-calls `0x6693450`.
   `0x6693450` walks three listener lists and calls each object's vt `+0x168(obj, state, index,
   mode)`. The lists are count `+0x908` at `+0x6a8`, count `+0x90c` at `+0x6c8`, and count
   `+0x910` at `+0x6e8`. `mode` is `[queue+0x5a4]` when `[queue+0x5a0] == 1`, and 2 otherwise.
   The listeners are created by `0x6693570` (accel vt `+0x7f8`, then the new object's vt `+0x140`).
   None of this reads the CDM range.
8. **The block at `+0x120` belongs to `AGXChannel`, and it is allocated at init, not at submit.**
   `AGXChannel::init` is `0x668d5f8` (type string at `0x57bb799`; failure text at `0x57bb76d` is
   "failed to prepare AGXChannel"; callers `0x66a9d3c`, `0x66ae610`, `0x66aebdc`). It takes a slab slot from the firmware heap:
   - Heap A: bitmaps `[FW+0x748]` / `[FW+0x750]`, slabs `[FW+0x708]`, stride `[FW+0x760]`,
     per-slab count `[FW+0x720]`. Find-first-set picks the slot. `[channel+0x120]` is the CPU
     mapping of that slot (`slab vt+0x88` plus the offset). `[channel+0x100]` is the slab's other
     mapping (`[slab+0x18]` plus the same offset). `[channel+0xf0]` is the bit index.
   - Heap B: bitmaps `[FW+0x868]` / `[FW+0x870]`, slabs `[FW+0x828]`, stride `[FW+0x880]`,
     count `[FW+0x840]`. The slot's CPU mapping goes to `[channel+0x128]`, and that address plus
     `0x60` to `[channel+0x130]`. The other mapping goes to `[channel+0x108]` and `+0x60` to
     `[channel+0x110]`. `[channel+0xf4]` is its bit index.
   The FW pointer is `[[channel+0x18]+0xdd8]`. That `[channel+0x18]` is the accelerator is
   INFERRED from the init's type string, which takes an `AGXAccelerator *`.
9. **Kick (READ).** `0x66872dc(owner, channel, arg)` loads the FW from `[owner+0xdd8]`, reads
   `[channel+0x20]` and `channel vt+0x180()`, then calls FW vt `+0x150`. That slot is `0x66a33fc`
   (FW vtable `0x6f354f8`). The ring writer `0x669cb30` writes `{2, fw-VA, arg}` where the fw-VA
   is FW vt `+0x1a8` of `[channel+0x120]`. `arg` is the wrapper's third argument. It is not the
   CDM pointer.

10. **Three channel kinds (READ).** `[channel+0x154]` picks a 16-byte entry in the table at
    `0x6f33c70`. The entry's function is the kick. Each factory calls `AGXChannel::init` and then
    sets the type and a FW-relative pointer at `[channel+0x148]`:

    | Type | Factory | `[channel+0x148]` | FW slot | Ring writer | Opcode | `MTS_SCHEDULE` | Ring control |
    |---|---|---|---|---|---|---|---|
    | 0 | `0x66aebc8` | `FW+0x10` | `+0x140` `0x66a304c` | `0x669c81c` | 0 | `0x10` | `[FW+0x2b8]` |
    | 1 | `0x66a9d24` | `FW+0x80` | `+0x148` `0x66a3224` | `0x669c9a4` | 1 | `0x11` | `[FW+0x2d8]` |
    | 2 | `0x66ae5fc` | `FW+0xf0` | `+0x150` `0x66a33fc` | `0x669cb30` | 2 | `0x12` | `[FW+0x2f8]` |

    The kext names `AGX3DChannelG4P_B0` and `AGXTAChannelG4P_B0`. Which type number is which class
    is not tied. Type 2 is the kick already documented (opcode 2, `MTS_SCHEDULE` `0x12`).
11. **What the two blocks contain (READ, reset `0x668dbc4`).** Block A is `[channel+0x120]` (CPU)
    and `[channel+0x100]` (the other mapping). Block B is `[channel+0x128]` and `[channel+0x108]`.
    Reset zeroes both, then writes:
    - Block A `+0x00`: fw-VA of block B. `+0x04`: fw-VA of block B `+0x60`. `+0x08`: fw-VA of
      `[channel+0x138]`, which init stored from its `x7`.
    - Block A `+0x14`: `[channel+0xf8]`, init's `w2` (`uint32_t` after the accelerator argument).
      `+0x18`: `0xffffffff`.
    - Block B `+0x50`: `[channel+0xfc]` (init's `w4` times 9). `+0x00`, `+0x10`, `+0x20`, `+0x30`
      and `+0x40` are 0.
    The firmware ring's second word is the fw-VA of block A, so the firmware finds block B through
    block A's first word. No word written here is the shared-memory CDM pointer.
12. **The ring `arg` (READ).** Submit is `0x6686df8(owner, channel, flag, ptr)`, reached from
    `[[accel+0xd18] vt+0xe8]` at `0x667edb0`, `0x668e4a0` and `0x66bbba8`. The `arg` is the `u32`
    at block B `+0x40`, read through `[channel+0x108]`. Reset stores 0 there, and the command
    builder at `0x667e4e0` samples the same word into `[channel+0x178]`. No other kernel store
    through the channel's block pointers writes `+0x40`, so after reset the live value is the
    firmware's (INFERRED). When `flag`'s first byte is 0 the submit also appends `{arg, ptr}` as
    a 16-byte record on the channel ring at `[channel+0x168]`, and it kicks only when that flag
    is 0 and `[channel+0x158]` is 0. `ptr` is the caller's `[object+0x38]`. It is not buffer `a`.

**Open:** block A points the firmware at block B, not at the CDM stream. The stream still stays
in shared memory. Still unknown: where a submit writes buffer `a`'s address into block B, and
what block B `+0x40` counts. That is the rest of the A8 firmware compute ABI (M4).

## Next

1. Compare the store kernel with the A10 store_marker capture instruction by instruction.
2. Find the store of shared-memory buffer `a` into block B, and what block B `+0x40` counts.
   The ring `arg` is that word. (`k0` is decoded above.)
3. The kernel slide (for the PMGR/Fender read) still needs another source.
