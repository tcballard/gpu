# J96 GPU M0: power-on, register map, interrupts and META boot (static, iPadOS 15.8.3)

Conventions:
- **pc / address notation.** A pc written as `0x66959c0` stands for kernel VA `0xfffffff0066959c0`; `0x7a4dd42` stands for `0xfffffff007a4dd42`; `0x5b19d44` (ARMPlatform) stands for `0xfffffff005b19d44`.
- **Code locations.** All AGXG4P code is in `__PLK_TEXT_EXEC` of the 15.8.3 kernelcache.
- **READ** means disassembled by the analyst and re-disassembled by an independent verifier.
- **INFERRED** means everything else.
- **"(corrected)"** means a verifier disagreed with the analyst's trace and the verifier's version is used here.
- **"(synthesis)"** means I resolved a conflict between traces, and I explain how each time.
- **Object names.** ACC is the AGXAcceleratorG4P_B0 object. FW is the AGXMetaFirmware object (`[ACC+0xdd8]`). FNDR is the Fender window. RGX is the RGX CR window. `flags` is the ProbeConfig byte `0x7a4dd42`.

---

## 1 Summary

**What is now known, with confidence:**

1. **Window assignment (READ, high).**
   - The sgx node has exactly 2 `reg` entries.
   - The driver chooses windows by how many ranges there are, through a jump table at `0x57b6f68`. With count 2 it sets gpuIdx=0 and fenderIdx=1, and there is no UVWarn or KF window.
   - **reg[0] = RGX CR block at PA 0x201000000. reg[1] = Fender at PA 0x201e00000.**
   - The driver also gives the firmware two AIC pages: 0x20e101000 (timer) and 0x20e104000 (SW-interrupt).
2. **Probe power-on (READ, high).** iOS powers the core on in this order:
   - PMGR clock gate on, then power gate on. Both are ADT id 0x7c (GFX), called through AppleARMIODevice.
   - Fender `+0x10000=0xffff0000`, then `+0x0=0x40000000`.
   - Fender `+0x1000=0x11`, then a spin until bit4 clears. **The spin has no timeout in iOS.**
   - `IODelay(10)`.
   - Only after that does it do the 32-bit reads RGX `+0x20` (CORE_REVISION) and then `+0x18` (CORE_ID).
   - The A10 hint (`+0x1000=0x11`) is correct for A8. No literal-immediate `0x2058` access exists in AGXG4P.
3. **Identity check (READ, high).**
   - The driver accepts CORE_REVISION[23:16]==3 with [15:8] = 0x08 ("B0") or 0x0a ("B1").
   - Core count = CORE_ID[15:8], which must be non-zero.
   - **The "G4P_B0" class accepts both B0 and B1 silicon (corrected from the plan).** The real revision is unknown until M1.
4. **Interrupts (READ, high).**
   - AIC IRQ 134 is the RGX core IRQ. In GPC mode it is used only for an MMU-pending log.
   - IRQs 135–137 are Fender host interrupts, acked at FNDR `+0x14`.
   - IRQ 138 is the firmware-event interrupt, an AIC software interrupt.
   - **The host never writes AIC SW_SET** (within AGXG4P). It writes `0x400` to SW_CLR 0x20e104090 to ack IRQ 138.
   - The firmware is given the SW page, the SW_SET offset `0x10` and the mask `0x400`, so META raises IRQ 138 itself (INFERRED).
5. **Kick (READ, high; corrected).** The host-to-META kick is a 32-bit write to **RGX_CR_MTS_SCHEDULE (`+0xb00`)** of 0x10, 0x11 or 0x12. It is not an AIC SW interrupt; the meta-boot trace said it was, and that was refuted.
6. **META boot (READ with corrections; synthesis, medium-high).**
   - The META LDR loader and boot-config layout follow mainline `pvr_fw_meta.c` closely. The host builds segment-MMU boot args in the mainline `configure_seg_id` shape.
   - The RGX boot writes are: SOFT_RESET ×3, META_BOOT=1, BIF_CAT_BASE0, SLC_CTRL_MISC=0x200001, `0x3808`=1, then SOFT_RESET=0.
   - **On J96, useGPC (`flags` bit1) is set, so these RGX writes are not issued to RGX directly. They are recorded into a Fender "replay program" at FNDR `+0x10000`.** The boot is then triggered by requesting GPC perf state 1.
   - Fender replaying the program on that transition is INFERRED, but it is the only consistent reading.
7. **Perf states (READ for the host side, INFERRED for DVFS).**
   - The host only ever requests GPC state 0 (off) or 1 (365 MHz / 896 mV).
   - The firmware receives max pstate 4 and a 16-entry MHz table.
   - DVFS above state 1 is driven by META through Fender (INFERRED).
   - No host code programs GFX clocks or voltages.
8. **Symbolled reference (READ via GitHub API, not downloaded).** An iOS 10 unified AGX.kext with an `AGXAcceleratorG4P_B0` (`gpu,t7000`) personality exists in userlandkernel/ios-unstripped-kexts (`kexts/10.0/T8010/AGX.kext`, 1,197,636 bytes). This settles plan item 1.6 in favour of "yes".

**Overall:** the M1 probe sequence is fully determined and READ end to end. The remaining risk is in the M3 META-boot details (§8).

---

## 2 Register windows

| Window | PA | ADT size | Host use | Firmware view | Evidence |
|---|---|---|---|---|---|
| sgx reg[0] = **RGX CR** (gpuIdx 0) | 0x201000000 | 0x100000 | VA kept at ACC+0xd10; every RGX_CR access goes through it. Offsets seen go up to ≥0x8000 (USC pipe select in a debug dump, `0x66abf1c`); the "~0x4178 max" from the regmap trace is superseded. | Region "RGXRegs" {gpuPhys, 0x20000}, but the mapping loop skips slot 3, so it is not GPU-mapped (META reaches it natively, INFERRED) | `0x6695748` strh 0x100; `0x6695968` map; `0x6695a74` str [x20,#0xd10]; skip `0x66a1678` ccmp i==3 (READ) |
| sgx reg[1] = **Fender/GPC** (fenderIdx 1) | 0x201e00000 | 0x100000 | Fender object +0x10; offsets 0x0–0x20000, sequencer at 0x10000 | "FenderRegs" {fenderPhys, 0x5000}, GPU-mapped | `0x6695990` map; `0x6699708`→`0x66ad8cc` stp; `0x6683cb4` mov #0x5000 (READ) |
| AIC timer page "AICTimerRegs" | 0x20e101000 (4K pages) | – | none | GPU-mapped. fwinit+0x2ec = in-page offset of 0x20e101020 (0x20 at 4K) | `0x6683cf0`–`cf8` movz/movk (READ). The 4K page size is INFERRED; at 16K the page base would be 0x20e100000 (corrected) |
| AIC SW page "AICSWIntRegs" | 0x20e104000 | – | host writes SW_CLR 0x20e104090 (value 0x400) only | GPU-mapped. fwinit +0x1e0 phys, +0x1e8 fw VA, +0x1ec size, +0x2e4 = 0x10, +0x2e8 = 0x400 | `0x6683648`–`658`; `0x669bc8c`/`bc94`; `0x66a65ac` (READ) |
| PMGR ps_gfx (ADT GFX id 0x7c) | 0x20e020320 (pmgr reg[0] 0x20e000000 + 0x20320) | – | not touched by AGXG4P; reached through AppleARMIODevice, then the PMGR provider | – | gate calls READ. The id 0x7c → ps_gfx mapping is INFERRED (ADT decode: GFX entry ps-regs idx 3 = 0x20300 + 4×8; its parent field is zero) |
| UVWarn / KF | absent | – | uvwarnIdx stays 0xff; region slot 4 is named "Unused" | – | `0x6695910`, `0x6683d48` (READ) |

**Fender register map** (names from the kext's own state dump at `0x66ad8f0`, READ):

| Off | Name | Host use (READ) |
|---|---|---|
| +0x0 | TIMER_SLEEP_CONTROL | Probe and hwInit write 0x40000000. bit29 is checked as "SNOOP" before kicks. bits29+30 both set = "off". (v>>30)==1 = the fallback off-state. The type-6 halt restores a saved value. |
| +0x8 | TIMER_KICK_STATUS | Must read 0 in the isOff check. |
| +0x10 | TIMER_POWER_INT_ENABLE | Interrupt type 0/1/2 sets bit 0/1/2 (OR-set); type 3 writes 0. |
| +0x14 | TIMER_POWER_INT_STATUS | Acked by writing back (v & 7), then a read-back. Written as 7 before every kick. |
| +0x1000 | VCM_PERF_STATE_CONTROL | [3:0] = GPC state; bit4 = transition pending/go. |
| +0x1004 | VCM_PERFORMANCE_NEXT_STATE | Only read, by the dump. |
| +0x10000.. | (unnamed) sequencer program | 32-bit entry = `[off | flags<<16][val]`. 64-bit entry = `[off+4][hi]` then `[off | flags<<16][lo]`. Terminator `0xffff0000`. Seen at `0x66ae2f4`–`0x66ae384`. |
| +0x20000 | VCM_PERF_STATE_OVERRIDE | Written 0 before power-on and power-off. 0x20 with a bit5 ack poll is used only for firmware inspection. |

---

## 3 Power-on and power-off sequences

**Gating (READ, corrected by the verifiers).**
- The whole probe power block runs only if the powered byte `0x7a4dd40`==0 and `flags` bit0 is set. bit0 is the `gpu_acceleration` boot-arg, which defaults to 2, meaning on (`0x66959a4`–`b4`).
- The Fender part also needs `flags` bit2 (startFender) and `0x7a4dd3f`≠0. `0x7a4dd3f` is ACC vt+0xa30 = `0x66ad858`, which returns 1.
- Only steps 3a and 3b below are additionally skipped when has-kf is present (`0x6695a1c` tbnz #3 → `0x6695a34`).
- bit1 (useGPC) = gpu_gpc boot-arg if given, else (no-gpc != 1).
- bit2 = fenderIdx valid && (bit1 || bit3) && bit0 (`0x6695690`–`0x6695880`).
- **J96 values: bit0=1, bit1=1, bit2=1, bit3=0** (the ADT has no no-gpc, has-kf or model-slow).

### 3.1 Probe power-on (`IOService::probe` override `0x66952cc`; READ unless marked)

1. Map RGX (idx 0) and Fender (idx 1) with `mapDeviceMemoryWithIndex` at `0x6695968` and `0x6695990`.
2. PMGR on:
   - a. **Clock gate on:** provider vt+0x568(1, 0) at `0x66959c0`. In AppleARMIODevice (`0x5b19d44`) this indexes the ADT `clock-gates[0]` (0x7c) and forwards to `[dev+0x88]`→vt+0x568.
   - b. **Power gate on:** provider vt+0x570(1, &out, 0) at `0x66959dc`. This goes through `power-gates[0]` (0x7c) via `0x5b19df0`.
   - No delay or poll between a and b on the AGX side. That PMGR itself polls is INFERRED.
3. Fender, if bit2 && dd3f:
   - a. *(only if !has-kf)* `FNDR+0x10000 = 0xffff0000` (empty sequencer program) at `0x6695a20`–`a28`.
   - b. *(only if !has-kf)* `FNDR+0x0 = 0x40000000` at `0x6695a2c`–`a30`.
   - c. `FNDR+0x1000 = 0x11` (request GPC state 1 with the go bit) at `0x6695a34`–`a38`.
   - d. Poll `FNDR+0x1000` until bit4 == 0: `ldr w8,[x0,#0x1000]; tbnz w8,#4` at `0x6695a3c`–`a40`. **No timeout.**
4. `IODelay(10)` (10 µs) at `0x6695a44`–`a48`; the stub `0x66c298c` resolves to `_IODelay`. This runs even when step 3 is skipped.
5. Set the powered byte (dd40=1) at `0x6695a4c`. Then `ACC+0xd10 = RGX VA` at `0x6695a74`.
6. Identity check (ACC vt+0xa38 `0x6696848` → vt+0xa48 `0x66ad86c`):
   - `ldr w9,[x8,#0x20]` (CORE_REVISION), then `ldr w8,[x8,#0x18]` (CORE_ID), at `0x66ad870`/`874`.
   - Checks: `(rev & 0xff0000)==0x30000`; minor 0xa → B1 and 0x8 → B0, anything else fails; cores = id[15:8]; frags = (cores+3)>>2.
   - The match table at `0x57b8260` is {G4P,B1},{G4P,B0}. A match returns score 10000 (`0x6696fc4`).

### 3.2 Runtime power-on and boot (READ unless marked; order from ACC `0x6684274` and `0x6686274`)

1. A GPC state-0 request happens on the firmware-object init path (setGPC(0) at `0x66a15c0`).
2. `FW->setGFXPower(1)` (FW vt+0x228 = `0x66a4964`):
   - It increments the refcount at FW+0xb50, but **the gate calls are not gated by the refcount** (corrected).
   - Clock gate on (vt+0x568), then power gate on (vt+0x570), on the provider at ACC+0x368. That ACC+0x368 is the sgx nub is INFERRED.
   - Then the Fender powered flag (obj+0xc) is set, then enableGPCHostInterrupts(3) writes `FNDR+0x10 = 0`, then ACC+0x12c1 = 1.
3. `FW->hwInit` (vt+0xe0 = `0x66a2e68`):
   - `FNDR+0x10=0`, `FNDR+0x0=0x40000000`, sequencer cursor = 0x10000 (no MMIO).
   - Then it records the META-boot RGX writes into the Fender program (§6).
   - With useGPC it finishes by recording SOFT_RESET=0 and the terminator `0xffff0000` (`0x66a2f70`–`f98`).
4. ACC vt+0x8a8(1): purpose not identified (INFERRED to be a sub-block enable).
5. `FW->boot` (vt+0xc0 = `0x66a25d4`), with useGPC:
   - a. `FNDR+0x20000 = 0`. This is a plain write with no poll (`0x66adf64`–`f80`).
   - b. setGPCPerformanceState(1) (`0x66ab000`):
     - Poll `FNDR+0x1000` bit4 == 0 in `IODelay(10)` steps, up to about 30 s (limit 0x1c9c377), then panic "Unable to change GPC performance state".
     - **Then** a plain write of `0x11`, a read-back, and the state cached at obj+0x8.
     - There is no wait after the write.
   - c. Wait for "META alive" (`0x66a6fec`; §6).
   - Without useGPC, step 5 is instead a direct RGX `SOFT_RESET=0` (`0x66a25f8`–`2610`).

### 3.3 Power-off

**Probe teardown / re-probe** (`0x669539c`–`0x66953e0`; copies at `0x667fc48` and `0x66868f4`; READ):
1. `FNDR+0x1000 = 0x10` (state 0 with the go bit).
2. Spin while `FNDR+0x1000` bit4 is set (unbounded).
3. **Power gate off:** vt+0x570(0,0,0).
4. **Clock gate off:** vt+0x568(0,0).
5. dd40 = 0.

Note the asymmetry: the probe teardown turns the gates off in reverse order (power, then clock), while setGFXPower uses clock then power in both directions (corrected).

**Runtime power-off** (`0x66858ec`–`0x6685930`; READ):
1. ACC vt+0x8a0(0) → FW vt+0x230(0) → interrupt type 3, so `FNDR+0x10 = 0`.
2. `FW->stop` (vt+0xc8 = `0x66a26b4`): `FNDR+0x20000 = 0`, then setGPC(0). That is a pre-poll of bit4 (about 30 s), then a write of `0x10`.
3. ACC vt+0x8a8(0).
4. `FW->setGFXPower(0)`:
   - isOff check (Fender vt+0x98 `0x66ae15c`). Two branches:
     - Full-off: SLEEP_CONTROL bits 29 and 30 both set, then wait up to 30 s for bit4 to clear, then state==0 and KICK_STATUS==0.
     - Fallback: state==0 and (SLEEP_CONTROL>>30)==1.
   - If the check fails and the recovery flag is clear, it panics.
   - Then clock gate off, then power gate off, then the powered flag is cleared.

**Firmware-requested halt** (event type 6 handler `0x66a6154`; body READ, the meaning of "type 6" INFERRED):
1. `FNDR+0x0 = 0x40000000`.
2. Poll RGX `0xa18` & 0x05000000 (about 100 ms).
3. Write MSLVCTRL0 `0xa10` = 0x04800000 / 0x04801000 with MSLVDATAT `0xa08` = 0xfffffffe (disables T0/T1), polling idle after each.
4. RGX `0x1340=1`, BIF_CTRL `0x12a8=8`, SOFT_RESET `0x100=0x08000000`.
5. `FNDR+0x0` = the saved value from fw+0x358 table (`0x66a61b0`–`c4`).
6. `FNDR+0x20000=0`, then setGPC(0).

---

## 4 The M1 read-only probe (exact)

Ground rules:
- Use 32-bit accesses only (`readl`/`writel`). iOS only uses `w`-register accesses here.
- Map as non-posted Device memory: `ioremap_np`, or the bus `nonposted-mmio` property, per Linux Apple-platform practice (INFERRED).
- Map RGX at 0x201000000, 0x1000 bytes, and Fender at 0x201e00000, 0x21000 bytes.
- Do not request IRQs 134–138. Unrequested AIC lines stay masked.
- Do not bind drm/imagination. Its `pvr_gpuid_decode_reg` does a 64-bit read at 0x20.

**Ordered accesses (each step mirrors a READ iOS step unless marked):**

1. **ps_gfx on.**
   - Write the target state "on" to the pmgr pwrstate at 0x20e020320, then poll for the actual state to reach the target. Bound the poll at about 100 ms.
   - This mirrors iOS clock gate then power gate (§3.1 step 2). Treating one Linux ps_gfx "on" as covering both calls is INFERRED.
   - Linux `apple-pmgr-pwrstate` semantics (target [3:0], actual [7:4], 0xf = on) are INFERRED for t7000.
2. *(optional, within iOS envelope)* Read `FNDR+0x1000`. setGPC reads it before writing, and the Fender dump reads every register once powered.
   - If bit4 is set, poll it clear for at most 100 ms.
   - Record `FNDR+0x0`, `+0x8`, `+0x10`, `+0x14`, `+0x1000`, `+0x1004`, `+0x20000`.
3. Write `FNDR+0x10000 = 0xffff0000` (empty program; mirrors `0x6695a28`).
4. Write `FNDR+0x0 = 0x40000000` (mirrors `0x6695a30`).
5. Write `FNDR+0x1000 = 0x11` (mirrors `0x6695a38`).
6. Poll `FNDR+0x1000` until bit4 == 0. iOS has no bound here; **use a bound such as 100 ms** (INFERRED choice; iOS runtime uses about 30 s). Then require `(FNDR+0x1000 & 0xf) == 1`. This check is INFERRED as a sanity test; iOS does not make it here.
7. `udelay(10)` (mirrors `0x6695a48`).
8. Read `RGX+0x20` (CORE_REVISION, 32-bit), **then** `RGX+0x18` (CORE_ID, 32-bit). This is the iOS order (`0x66ad870`/`874`).
9. *(optional, Stage B, outside the iOS envelope)* 32-bit reads of `RGX+0x24` and `RGX+0x1c`. iOS never reads them; its scan of all 115 ACC+0xd10 loads found no 0x1c/0x24/0x28/0x30. They tell us whether mainline's PBVNC path would trigger: it does if `RGX+0x24[31:16] != 0`. Run Stage B on a separate boot only after Stage A has succeeded twice.
10. *(optional)* Re-read the seven Fender registers from step 2.
11. **Power-off** (mirrors probe teardown `0x669539c`–`0x66953e0`):
    - Write `FNDR+0x1000 = 0x10`.
    - Poll bit4 == 0 (bounded at 100 ms) and check `(FNDR+0x1000 & 0xf) == 0`.
    - Then ps_gfx off, and poll the actual state off.

**Expected results:**
- CORE_REVISION[23:16] = 0x03; [15:8] = 0x08 (B0) or 0x0a (B1); designer and maintenance bytes unchecked by iOS.
- CORE_ID[15:8] = cores, non-zero (4 is INFERRED). Mainline's legacy decode would give 3.8.N.C or 3.10.N.C.

**Must NOT touch:**
- **AIC:** SW_SET 0x20e104010 and SW_CLR 0x20e104090, the AIC timer page 0x20e101000, any AIC mask registers.
- **RGX writes of any kind:** SOFT_RESET `0x100`, META_BOOT `0xbf8`, MTS_SCHEDULE `0xb00`, the META slave port `0xa00`–`0xa18`, BIF `0x1200`/`0x12a8`/`0x1340`, SLC `0x3800`/`0x3808`, the USC pipe select `0x8000`.
- **No RGX reads at all** before step 6 has succeeded.
- **Fender:** no writes to `+0x10`, `+0x14`, `+0x1004` or `+0x20000`; no states other than 0x11 and 0x10; no non-empty sequencer program.
- **PMGR:** perf-regs, voltage, or any domain other than ps_gfx.

**Abort conditions:** after any of these, perform no RGX access and log every value read.
- ps_gfx does not reach "on": set the target off and stop.
- Step 2 reads 0xffffffff, or bit4 never clears: power ps_gfx off and stop. Do not write Fender.
- Step 6 times out: **do not write Fender again** (iOS never writes while bit4 is pending). Power ps_gfx off. That this is safe is INFERRED; a reboot is the fallback.
- Step 6 state != 1: do step 11 and stop.
- An SError or bus hang on any access: reboot via checkm8.
- CORE_REVISION major != 3, minor not in {8, 0xa}, or cores == 0: record the values, skip step 9, and do step 11 normally.

---

## 5 Interrupts and the AIC SW registers

**Registration (READ).**
- `configure` reads `interrupts`; count = len/4 = 5.
- The jump table at `0x57b6f50` sets ACC+0xeb8 = 4 (firmware-event index) and +0xeb9 = 1 (core IRQ used), at `0x66835c4`–`c8`.
- One `IOFilterInterruptEventSource` is created per index, with filter vt[0x888] (always returns 1) and action vt[0x890] (`0x6680f50`–`0x6680fd4`).
- The action forwards `getIntIndex() & 0xff` to the FW dispatcher at `0x669de4c`. The name getIntIndex is INFERRED; the slot is READ.

| Index / AIC IRQ | Role on J96 (GPC mode) | Handler (READ) |
|---|---|---|
| 0 / 134 | RGX core IRQ, used only for the MMU-entry-pending check (`RGX+0x1290` bit0, log only). It then returns without draining any rings. | `0x669debc`–`0x669df04`; `0x66acd80` |
| 1–3 / 135–137 | Fender/GPC host interrupts (which type goes to which IRQ is unknown) | Fender vt[0x28] `0x66ab288`: read `+0x14`, write back `v & 7`, read back |
| 4 / 138 | Firmware event (AIC SW interrupt) | ack `0x66a6520`, then drain the FW→host rings (FW+0x338 mod 256; vt 0x3a0; `0x669f88c`; ring at FW+0x350, entries of 0x24 bytes) |
| >4 | invalid | calls `PE_enter_debugger` (corrected; not just a log) |

**Non-GPC mode (corrected).** In non-GPC mode, or when eb9==0, index 0 takes the full firmware-event path. In that mode the ack writes 0 to `RGX+0xac8` (META_SP_MSLVIRQSTATUS), and only when ACC+0x12c1==1. This matches mainline's meta IRQ handling. In the single-record `meta-sw-interrupt` layout the mask is 0x40, i.e. IRQ 134 = interrupts[0], which fits this (INFERRED).

**The AIC SW registers (READ).**
- `meta-sw-interrupt` is 40 bytes: two records {SET 0x20e104010, CLR 0x20e104090, mask 0x40} and {same, mask 0x400}.
- Because len > 0x27, the driver uses record 2 (`0x6683634` cmp w22,#0x27; csel 0x14). The values go to ACC+0x1ba8/+0x1bb0/+0x1bb8.
- The property is mandatory: if it is absent, vt[0x7b8] returns 1 and start fails (`0x6683674`–`688`).
- 0x20e104010 = AIC+0x4010, the SW-generate word covering IRQs 128–159; bit 10 = IRQ 138 (INFERRED arithmetic, consistent with the ADT IRQ list).
- **Host writes:** only `SW_CLR = 0x400`. It goes through a kernel uncached map of the AICSWIntRegs page: `kmap(FW+0xad8)` VA + (CLR − page) + FW+0xb18 (=0), at `0x66a6558`–`0x66a65ac`.
  - This happens in the IRQ-138 handler **before** draining the rings.
  - It needs both `flags` bit1 and vt[0x7b8]≠0.
- **SW_SET:** `+0x1ba8` is referenced only by its stores and by two address computations (page base and in-page offset). AGXG4P imports no `causeInterrupt`. So the AP never writes SW_SET (READ within AGXG4P; other kexts not scanned).
- **Firmware side:** fwinit gets the SW page phys/VA/size, SW_SET offset 0x10 (`+0x2e4`) and mask 0x400 (`+0x2e8`). **That META raises IRQ 138 by writing SW_SET is INFERRED.**

**Kick (READ; corrected the meta-boot trace).**
- 32-bit `RGX+0xb00` (MTS_SCHEDULE):
  - `0x10` for TA, firmware and device-control submits (`0x66a30d0`, `0x66a362c`, `0x66a3914`).
  - `0x11` for 3D (`0x66a32a8`).
  - `0x12` for CL (`0x66a3480`).
- The pre-sequence is: `dmb ish`, then `FNDR+0x14 = 7` (`0x66ae120`), then read the GPC state `FNDR+0x1000 & 0xf`.
- If the state is 0, the driver checks `FNDR+0x0`==0 (warns "uninitialized GPU"), bit29 (SNOOP) and `+0x14` bit1, and warns "MTS_SCHEDULE without SNOOP". It **always** writes MTS_SCHEDULE anyway.
- That a kick wakes the GPC through Fender SNOOP is INFERRED.
- FW slot 0xd0 (`0x66a2964`), which the meta-boot trace called "kickFirmware", is actually a Fender snapshot dump (corrected).

**Linux implication (INFERRED).**
- Request IRQ 138 as the firmware IRQ. In its handler, write 0x400 to AIC+0x4090 first, then drain.
- Map the two AIC pages into the GPU address space for META.
- Never write SW_SET from the AP.
- Ownership of AIC MMIO by `irq-apple-aic` has to be reconciled (§8).

---

## 6 META boot sequence vs mainline

Mainline reference: `pvr_fw_meta.c` (`pvr_meta_fw_process`, `configure_seg_mmu`, `configure_meta_caches`, `pvr_meta_wrapper_init`) and `pvr_fw_startstop.c` (`pvr_fw_start`).

**How I resolved the bit1 conflict (synthesis).** The meta-boot verifier called `flags` bit1 "dbg1, clear on normal boot". The regmap, aic-irq and ids verifiers each READ bit1 as **useGPC = (no-gpc != 1)**, which is set on J96. The fender verifier READ that with bit1 set, the RGX write helpers (FW vt+0x1e0/0x1e8/0x1f0 at `0x66a3ac4`/`b00`/`b3c`) divert into Fender seqWrite/seqWrite64 with flags 0xff. The J96 column below follows that.

| Step | Apple (AGXG4P, J96) | Mainline | Difference |
|---|---|---|---|
| LDR walk | Two-pass (`0x66a1ef8` sizes 4 META regions; `0x66a22a8` dispatch on `type & 0x1f`, jump table `0x57b6f7a`). LOADMEM copies and byte-verifies; ZEROMEM; START_THREADS PC → FW+0xb48 (info only); LOADCORE/LOADMMREG are no-ops; cmd>5 is skipped if COMMENT, else the walk aborts (`0x66a2290`). READ | `process_ldr_command_stream`: LOADMEM / START_THREADS / ZEROMEM / CONFIG; COMMENT skipped; LOADCORE/LOADMMREG → `-EINVAL` | Apple tolerates LOADCORE/MMREG and verifies copies |
| Boot-config base | code VA + 0x200 → FW+0xb40 (`0x66a21b0`). READ | `ROGUE_FW_BOOTLDR_CONF_OFFSET` (0x80 words) | Same |
| JTAG privilege arg | Not seen among the FW+0xb40 users | `META_CR_SYSC_JTAG_THREAD = PRIV_EN` first | Apple omits it (or it comes from image CONFIG data; INFERRED) |
| Segment MMU | **Host-computed**, before the LDR walk. FW slot 0x480 `0x66a6a78` is called for seg 0,1,2,3, and id 2 returns early. Per segment it writes 4 pairs: `0x04850000+16n` = base\|0xF02; +4 = limit; +8 = outaddr lo; +0xC = outaddr hi \| (([[FW+0x220]+0x30c]&0xf)<<8). READ (corrected: the trace said "data-driven") | `configure_seg_mmu` → `configure_seg_id`, FW_DATA segment only | Same encoding; Apple sets 3 segments (0,1,3) |
| CONFIG blocks | type-2 CFG_WRITE (reg,val) pairs copied into the config area (`0x66a23c0`–`3f8`). READ | `meta_ldr_cmd_config` (same) | Same |
| Cache config | No host-computed cache args found | `configure_meta_caches` after the LDR walk | Apple has none (may be in image CONFIG blocks; INFERRED) |
| Terminator | (0,0) then one u32 translated META address (`0x66a24c4`–`24d0`, `0x66a25c4`). READ | (0,0); (core-code addr, size) or (0,0); (0,0) for DMA | Different tail; decode the meaning of the Apple u32 |
| Fender prelude | hwInit: `FNDR+0x10=0`, `FNDR+0x0=0x40000000`, cursor = 0x10000 (`0x66a2e84`–`ea8`). READ | — | Apple only |
| SOFT_RESET #1 | `0x00E7FFFFFFFFFC1D`, 64-bit (`0x66a2ebc`). READ | `MASKFULL 0x00E7FFFFFFFFFC3D`, then a read-back | SYSARB_EN (0x20) is left clear; no read-back |
| SOFT_RESET #2 | `0x00E7FE071FFFFC1D` = #1 ^ RASCALDUSTS, taking Rascal and Dusts **out** of reset (`0x66a2edc`). READ (corrected the label) | `mask ^ RASCALDUSTS_EN`, then a read-back | Same intent; no read-back |
| SOFT_RESET #3 | `0x0000000100000000` (GARTEN only) (`0x66a2f04`). READ | `GARTEN_EN`, then a read-back | Same; no read-back |
| SLC | ACC vt+0x748 `0x66ab4b0`: SLC_CTRL_MISC `0x3800 = 0x00200001` (PVR_HASH1 \| BYPASS_BURST_COMBINER), 64-bit; **then `0x3808 = 1`** (unnamed in mainline). READ (corrected: this is not CAT_BASE1) | `rogue_slc_init`: RMW32 of PSG_HAZARD \| PVR_HASH1 \| quirk bits | Apple has a fixed value plus the extra 0x3808 |
| META_BOOT | `0xbf8 = 1`, 32-bit (`0x66a2f20`). READ. Order: after the SOFT_RESET steps, before CAT_BASE | `META_BOOT = MODE_EN` (64-bit) in `wrapper_init`, after SLC | Different order and width |
| GARTEN wrapper | **No write to 0xb50** anywhere. READ (literal scan) | `MTS_GARTEN_WRAPPER_CONFIG` (META idle ctrl, fence PC base) | Apple omits it |
| AXI ACE | **No 0x38c0 access.** READ (literal scan) | `rogue_axi_ace_list_init` | Apple omits it |
| MMU root | BIF_CAT_BASE**0** (`0x1200`) = *(u64*)[FW+0x3e8] via ACC vt+0x740 `0x66ab48c` (w1=0, shift arg 0). **Index 0 only**; no CAT_BASE1; no 0xe148 access. READ (corrected) | `rogue_bif_init`: BIF_CAT_BASEX(FWPRIV=0) = (pc>>12)<<12 | Same register; whether FW+0x3e8 is pre-shifted is open |
| Delivery | **J96 (useGPC):** every write above is appended to the FNDR+0x10000 program, followed by SOFT_RESET=0 and the terminator `0xffff0000`. Nothing reaches RGX directly. Without useGPC they are direct stores to ACC+0xd10+off. READ; the replay is INFERRED | Direct MMIO | **The biggest Apple delta** |
| Release | J96: `FNDR+0x20000=0` then setGPC(1) (`0x66a2618`–`2640`). Fender replays the program on the state-1 transition (INFERRED). Non-GPC: direct `SOFT_RESET=0` (`0x66a25f8`). | udelay(3); `SOFT_RESET=0` + read-back; udelay(3) | Apple uses the Fender transition, with no udelays |
| Alive | `0x66a6fec`: set FW+0xb36=1; `commandSleep(&FW+0xb35)` via [ACC+0xd18] slot 0x110; deadline = interval [ACC+0xc20] × 1e9 scale, retried up to 10× (`0x66a703c`–`7084`). FW+0xb35 is set by the host event handler `0x66a6154` on **firmware event type 0** (it also stores evt+4 → FW+0xb38, sets FW+0x1c8=1, commandWakeup). READ (corrected: the timeout is not 1 s, and the flag is not firmware-written) | Polls `fwif_sysinit->firmware_started` in shared memory | Apple uses an event-ring message plus IRQ 138 |
| Slave port | Used only in the failure dump (MSLVCTRL1 idle mask 0x05000000, `0x66a27b0`) and in the type-6 halt. READ | Used for the stop path and debug | Similar |
| Kick | MTS_SCHEDULE `0xb00` (§5). READ | `pvr_fw_mts_schedule` → MTS_SCHEDULE | Same register; Apple adds the Fender preamble |

---

## 7 Perf states and safe defaults

**ADT `sgx` values (READ; analyst decode confirmed by the verifier):**
- perf-state-count = 16; gpu-num-perf-states = 4; perf-states-sram is absent.
- perf-states (Hz / mV) by GPC state:

| State | Frequency | Voltage |
|---|---|---|
| 0 | 0 | 600 (off) |
| 1 | 365 MHz | 896 |
| 2 | 450 MHz | 915 |
| 3 | 550 MHz | 950 |
| 4 | 600 MHz | 950 |
| 5–8 | 182.5 / 225 / 275 / 300 MHz | same voltages as 1–4 |
| 9–15 | zero | zero |

**Host behaviour (READ):**
- Only four setGPC call sites exist: `0x66a15c0` (0), `0x66a263c` (1), `0x66a26fc` (0), `0x66a6500` (0).
- The firmware gets:
  - fwinit+0x29c = min(gpu-num-perf-states, `gpu_limit_max_pstates`) = 4.
  - +0x2a0 = 16.
  - **+0x2a4..+0x2e0** = 16 MHz entries. Corrected: the table ends at +0x2e0, not +0x2d0 (`0x669c168`–`c27c`).
- The strings perf-states, perf-states-sram and gpu-num-perf-states occur only in AGXG4P. PMGR perf-domains cover only SOC and CPU.

**INFERRED:**
- META runs DVFS over states 1–4 through Fender. Evidence: the image string `agfPollFenderReg`, and that the host never requests a state above 1.
- The state → clock/voltage mapping lives in Fender/PMGR tables set up by iBoot.
- Entries 5–8 are unexplained; they may be half-rate variants.

**Safe defaults for Linux:**
- M1: request only state 1 (`0x11`) and state 0 (`0x10`). Never write `+0x1004`. Leave `+0x20000` at 0 (iOS sets 0x20 only for inspection).
- M3/M4: give the firmware max pstate **1** (the `gpu_limit_max_pstates` equivalent) until thermals are understood, then raise it to 4 at most.
- No host OPP/DVFS (m1n1 patch 0011 is unnecessary if the firmware owns DVFS; INFERRED).
- Bound every bit4 poll. iOS's runtime bound is 30 s; use much less for probes.

---

## 8 Open questions, ranked

1. **Does Fender replay the FNDR+0x10000 program on the GPC 0→1 transition, and in what order relative to RGX power?** This decides the M3 boot design. Linux could either replicate the program path or turn useGPC off; a gpu_gpc=0-style path writes RGX directly, but untested on hardware. Related: the exact redirect-flag semantics. The fender verifier reports "flag==0 or odd → write; nonzero even → drop", and the flags field is forced to 0xff in entries.
2. **What CORE_REVISION and CORE_ID actually read (B0 or B1, core count), and RGX+0x24[31:16].** M1 answers this.
3. **The firmware VAs of the region mappings** (FW+0xa80 GPU maps with options 0x90007; fw vt[0x1a8] translation) and the full fwinit layout (FW+0x220). M3 needs these.
4. **ACC vt+0x8a8 and vt+0x8a0** (called around boot and stop), and the first HAL slot 0x740 vs 0x748 adjacency. The verifier pinned 0x748 = SLC and 0x740 = CAT_BASE0, but 0x8a8 is unidentified.
5. **Meaning of SLEEP_CONTROL bits 29/30/31 and KICK_STATUS**, and why `0x40000000` is written. Note that 0x40000000 alone satisfies "(v>>30)==1", the fallback off-state.
6. **Is [FW+0x3e8] (the CAT_BASE0 value) pre-shifted?** And is a BIF_CTRL / MMU invalidate needed before boot? Only `0x12a8=8` appears, and only in halt paths.
7. **Unnamed RGX registers 0x3808 and 0x1340** (0x3800 is SLC_CTRL_MISC in mainline). Also the Apple boot-config tail u32 and the missing JTAG/cache args.
8. **How Linux `irq-apple-aic` coexists with a GPU driver** that writes AIC SW_CLR and hands AIC pages to META: an AIC hook, a separate page map, or a retrigger/mask interaction. INFERRED risk.
9. **Which Fender interrupt type maps to which of IRQs 135/136/137.** All three share one handler.
10. **ApplePMGR handling of gate 0x7c** (clock vs power, and whether it is exactly ps_gfx at pmgr+0x20320) was not disassembled.
11. **Kernel page shift on this build** (`_PAGE_SHIFT_CONST`; 4K INFERRED). It affects the AIC timer page base and fwinit+0x2ec.
12. Whether a computed-address access to `+0x2058` exists. Only a literal-immediate grep was done.

---

## 9 Evidence notes

**Verified (each claim was independently re-disassembled by a verifier):**
- Window selection by reg count, including the jump-table bytes and every target.
- The IOService and IOMemoryMap vtable slots; the `_IODelay`, `getPhysicalAddress` and `IOLog` stubs.
- The ProbeConfig static init and flag derivation.
- The Fender object vtable, the init at `0x66ad8c4` and the dump offsets/names.
- The region table at ACC+0xed0 and the mapping loop skip of slot 3.
- The full probe Fender write order and values.
- AppleARMIODevice vt+0x568/0x570 as the clock-gates/power-gates forwarders (`0x5b1a1c8`–`0x5b1a278`).
- The probe teardown order and the core-detect body; the supported table and rev-name table.
- setGPCPerformanceState (pre-wait, ~30 s, plain write); the override function.
- The IRQ registration, dispatcher, Fender ack, MMU-pending handler, SW_CLR ack and MSLVIRQSTATUS fallback.
- All five MTS_SCHEDULE sites.
- The LDR walker; the SOFT_RESET values and order; META_BOOT; SLC; the hwInit words.
- The ADT values (reg, ranges, meta-sw-interrupt, interrupts, gates, perf-states, absent properties).

**Corrections applied (verifier over trace):**
- **regmap:**
  - Both Fender preamble writes, not just the first, are skipped by has-kf.
  - UVDRegs has size PAGE_SIZE.
  - The 4K page size and the IRQ-138 bit mapping are INFERRED.
  - The 0xA18 site count is 51, not 40 (immaterial).
  - The thunks at `0x66be7f8`–`818` are on a power-tunable object, not device-memory calls.
- **fender-power:**
  - setGFXPower is not refcount-gated, and its gate order is clock then power in both directions.
  - isOff has the two branches described in §3.3.
  - 0x3800 has a mainline name; open question 9 of the trace is partly wrong.
  - "No 0x2058" is a literal grep only.
  - The 'type 6 = firmware power-off' meaning is INFERRED.
- **aic-irq:**
  - The AIC timer page depends on the page size.
  - In non-GPC mode index 0 becomes the firmware IRQ.
  - Index >4 calls PE_enter_debugger.
  - Function names are INFERRED (the kext is stripped).
  - The enable helper toggling index 1 was not reproduced (INFERRED).
  - "W1C" for +0x14 is INFERRED semantics.
- **meta-boot** (the verifier rejected the trace: holds=false):
  - The kick is MTS_SCHEDULE, not an AIC event source.
  - AICSWIntRegs is 0x20e104000, not 0x20e100000.
  - FW+0x160 is the Fender object.
  - Only BIF_CAT_BASE0 is written; the second call is SLC plus 0x3808.
  - SOFT_RESET #2 takes Rascal/Dusts out of reset.
  - Segment MMU args are host-computed.
  - The alive wait is an event-type-0 message, about 10×[ACC+0xc20] s, not a 1 s firmware-written flag.
  - Direct RGX stores to 0xb00, 0x12a8, 0x1340, 0x3808 and the slave port exist.
  - The has-kf flag is bit3, not bit0.
  - The trailing zero is the stream terminator.
- **ids-pstates:**
  - The MHz table ends at +0x2e0.
  - setGPC does a plain write.
  - The gating is more specific (§3).
  - The runtime Fender path depends on useGPC.
  - The PBVNC condition is RGX+0x24[31:16]≠0.
  - The omitted host Fender writes (INT_ENABLE, SLEEP_CONTROL rewrites, INT_STATUS clear) are now listed.
- **Synthesis (mine):**
  - I overrode the meta-boot verifier's "dbg1 clear on normal boot" with the three READ derivations of bit1 = useGPC (set on J96). The resulting "J96 META boot goes through the Fender program" composes two READ results; the replay itself is INFERRED.
  - I superseded the regmap "max RGX offset ~0x4178" with the READ `0x8000` write at `0x66abf1c`.
  - I corrected the plan's "rev B0" to "B0 or B1, undetermined".

**Not verified:**
- That every RGX access goes through ACC+0xd10.
- That populateLinearPowerTransferTable treats +4 as mV.
- The IOBufferMemoryDescriptor options 0x60007.
- The A10 FENDER.md comparison.
- The causeInterrupt and SW_SET scan beyond AGXG4P.

**Housekeeping:**
- An `ipsw macho disass` run left a symbol cache, `/home/tcballard/Projects/j96-touch-20261030/downloads/kernel/19H386__iPad5,1/kernelcache.release.iPad5,1_2.a2s`, outside scratch. It is not in a git repo, nobody removed it, and the user may delete it.
- Per-trace scratch work is in `/tmp/claude-1000/-home-tcballard-Projects/7aa9af37-4e91-48e5-a2e7-64bd8932ea91/scratchpad/gpu/m0-*/`.