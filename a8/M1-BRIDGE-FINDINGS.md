# J96 GPU M1: the missing step is probably the GFX bridge settings (static, 9 Nov 2026)

Question: Fender reports GPC state 1 and `ps_gfx` reports fully on, yet the first RGX read
freezes the SoC (`m1-staged-20261103.log`, `m1-gpc1-dump-20261109.log`). What does iPadOS do
between "GFX power on" and the RGX read that Linux does not?

Answer (READ in the ADT and the 15.8.3 kernelcache; the link to the freeze is INFERRED):
**ApplePMGR writes the device's "bridge settings" every time a device reaches power state
0xf. GFX has two bridges, at PA 0x201f00000 and 0x201f80000. Nothing in our Linux tree or
m1n1 patches writes them.** These are the "unknown PMGR reg[12]/[13] windows" that
`GPU-PLAN.md` section 5 said not to touch.

Conventions as in `M0-STATIC-RE.md`: a pc `0x66f0dc8` stands for `0xfffffff0066f0dc8`.

## ADT (`/device-tree/arm-io/pmgr`)

- `#bridges` = 14, `bridge-reg-index` = 2: bridge N uses pmgr `reg[2 + N]`.
- `devices` entries are 48 bytes. Byte 0x18 is the device's bridge count and bytes 0x1c.. are
  its bridge indices (READ in the kext, below). Bytes 0x0a/0x0b are the ps index and ps-reg
  group; byte 0x03 is the device id.
- GFX (id 0x7c, ps-reg group 3 index 4 = `ps_gfx` 0x20e020320, no parent): **2 bridges, 10 and 11**.
- Every other bridge belongs to one device: 0 ANS, 1 MEDIA, 2 MSR, 3 JPG, 4 VENC, 5 VDEC,
  6 ISP, 7 DISP_BUSMUX, 8 DISP0, 9 DISP1, 12 USB, 13 PCIE.
- No `bridge-settings-version` property, so the per-bridge `bridge-settings-N` properties
  are used: lists of (offset, value) u32 pairs.

| Bridge | pmgr reg | PA | Size | Writes |
|---|---|---|---|---|
| 10 | reg[12] | 0x201f00000 | 0x1000 | `+0x18 = 0x80010004` |
| 11 | reg[13] | 0x201f80000 | 0x1000 | 32 writes, `+0x00` to `+0x7c` (table below) |

Bridge 10's value is the one most other bridges get at `+0x14` (ANS, JPG, PCIE, ...), so it
looks like the same kind of bridge with a different register offset.

Bridge 11 values, by offset:

| Offsets | Value |
|---|---|
| 0x00 0x04 0x08, 0x14–0x2c, 0x38 0x3c, 0x50 0x54 0x58, 0x60, 0x6c | 0x007c7c01 |
| 0x0c 0x10, 0x34 | 0x007c7901 |
| 0x30, 0x5c, 0x70 | 0x006c6901 |
| 0x40 0x44 0x48 0x4c | 0x00747201 |
| 0x64 0x68, 0x74 0x78 0x7c | 0x00797901 |

Reproduce with `tools/adt_pmgr_bridges.py ADT tools/` (and `tools/adt_pmgr_devices.py` for
the device table).

## Kernelcache (ApplePMGR, iPadOS 15.8.3)

- Parse (`0x66dd8cc`–`0x66dda80`, inside ApplePMGR start `0x66dc7a4`): `#bridges` →
  PMGR+0x2670, `bridge-settings-version` → +0x2684, bridge table → +0x2668 (per bridge, per
  die, 0x40-byte entries: +0x08 mapped base, +0x10 pair count, +0x18 pair list, +0x20 counter
  config, +0x38 owning device id). With version 0 it reads `bridge-settings-%d`, asserts the
  length is a multiple of 8, and stores length/8 and the data pointer.
- Bridge register write (vtable slot +0x998 = `0x66f0d38`): `str w3, [base, w2, uxtw]`. A
  plain 32-bit write at mapped base + offset. The read twin is `0x66f0d54`.
- Apply one bridge (`0x66f0dc8`, version 0 path `0x66f0e0c`–`0x66f0e78`): for each pair,
  write value at offset through slot +0x998, in list order.
- Apply a device's bridges (`0x66f60a8`): loops over the device entry's bridge list (count
  at +0x18, indices at +0x1c..), calls `0x66f0dc8` for each, then enables the bridge's
  counters if it has a counter config.
- When (`0x66f5738`–`0x66f581c`, and the same shape at `0x66ea470`–`0x66ea4cc`): in the
  device power-state path, after `0x66e3ed8` has set the ps register to the new state, and
  **only if the new state is 0xf**, it calls `0x66f60a8`. So the settings are rewritten on
  every power-on, which fits registers that lose their contents when the domain is gated.
- Not traced: what `0x66e3da0` does before the ps write (called with the low nibble of
  device byte 0x0f, which is 0 for GFX), and the body of `0x66e3ed8`.

For AGXG4P this all happens inside its "power gate on" call (`M0-STATIC-RE.md` 3.1 step 2),
so before the Fender writes and long before the RGX read.

## Why this fits the freeze (INFERRED)

- The two windows sit next to Fender (0x201e00000) inside the GPU's address range.
- iBoot leaves GFX off (`ps_gfx` reads 0x300 at boot), so nobody has configured these bridges
  when Linux first powers the domain. ANS, USB and DISP0 work under Linux without this
  because iBoot powered them and Linux never gates them.
- Fender answers and RGX does not: Fender is a separate slave; the RGX CR window is behind
  the bridge(s).
- The timed dump showed nothing changing for 1 s after GPC 1, so a delay is not the fix.

Not established: which of the two bridges gates the RGX window, what the bridge 11 fields
mean, and whether the bridge windows can be read back.

## Independent check (second analyst, 9 Nov)

Each claim above was re-derived from the ADT and the kernelcache by a reviewer who had not
seen the first trace:

- **Bridge-to-address mapping: CONFIRMED.** `bridge-reg-index` is saved at `0x66dd47c`; the
  per-bridge loop computes `bridge-reg-index + N` (`0x66dd620`) and maps that pmgr reg index
  through the provider's `mapDeviceMemoryWithIndex` slot (`0x66dd6bc`, the slot AGXG4P uses
  for sgx reg[0]/[1]); the mapped VA goes to BridgeData+0x08 (`0x66dd7e8`). arm-io `ranges`
  maps child 0x0 to PA 0x200000000.
- **Device-to-bridge list, the apply, and the 33 values: CONFIRMED** (values compared
  programmatically with the module's tables). All three ApplePMGR vtables have `0x66f0d38`
  in slot +0x998. That an absent `bridge-settings-version` leaves the field at 0 is inferred.
- **CORRECTION: iOS also sets AUTO_ENABLE (bit 28) on the ps register.** After the actual
  state reaches 0xf, `0x66e433c`–`0x66e435c` ORs in 0x10000000 and writes the register (for
  devices whose flags byte has bit 2 clear; GFX's is 0). This comes before the bridge apply.
  Every Linux stage so far cleared bit 28 (domain forced on). Mainline's
  `apple_pmgr_ps_power_on` sets it.
- `0x66e3da0` is `_setPSAutoMinLevel`: it puts the level (0 for GFX) in bits 19:16 and clears
  bits 9:8. With `ps_gfx` at 0x300 it changes nothing.
- Nothing else in this path applies to GFX: no power-gate helper (entry byte 0x0e is 0), no
  byte-0x19 block, no post-apply block (entry byte 2 is 0), no bridge counters (the ADT has
  no `bridge-counters`).
- NOT VERIFIED: that AGXG4P's clock-gate and power-gate calls for id 0x7c arrive in this
  path with state 0xf, and the bodies of the register write and poll slots (+0x988, +0x990).

## Hardware result, 10 Nov (`m1-bridge-20261110.log`)

- `gpu-bridge-write`: all 33 writes completed with `ps_gfx` forced on. The windows are writable.
- `gpu-bridge-id`: the bridge writes, then stage 4: froze on the first RGX read again.
  **The bridge writes alone, with AUTO_ENABLE clear, are not enough.** Whether the writes
  took effect is unknown (no read-back).

## The AGX-to-PMGR link, traced (10 Nov; READ, single analyst, not yet re-checked)

The link the second analyst could not verify is now followed end to end:

- AppleARMIODevice forwards to its owner (`[dev+0x88]`, stored in init at `0x5b1a14c`):
  clock gate `owner->vt+0x568(id, enable)` (`0x5b19da0`), power gate
  `owner->vt+0x570(id, enable, out)` (`0x5b19e54`).
- The owner class is AppleARMIO's SoC subclass (vtable `0x6eec698`; the base class
  `0x6d10af8` returns unsupported in both slots; strings name AppleS5L8960XIO/AppleT7000IO).
  Its +0x568 (`0x644e558`) calls the `function-clock_gate` object at owner+0xf0 through
  vt+0x80 with (id, enable); its +0x570 (`0x644e5e4`) calls the `function-power_gate` object
  at owner+0xf8 with (id, enable, out).
- ADT `/arm-io`: `function-clock_gate` = (pmgr phandle 0x19, 'clkG'), `function-power_gate` =
  (pmgr phandle 0x19, 'pwrG'). ApplePMGR's function factory (`0x66d88a0`–`0x66d88fc`,
  `0x66d8b5c`) builds one object per FourCC: clkG vtable `0x6f41a70`, pwrG vtable `0x6f41ba8`.
- **clkG call (`0x66fa39c`)**: `0x66f4a1c(pmgr, id & 0xfffffff, enable & 1, enable >> 1, die)`.
  `0x66f4a1c` is the function that contains the traced power-state path (`0x66f5738`–
  `0x66f581c`): min level, target 0xf with poll, AUTO_ENABLE, bridge apply. So "clock gate
  on" is the whole device power-on.
- **pwrG call (`0x66fa5d4`)**: runs `0x66f5984` under the command gate with (id, out). That
  function only *reads* the device's ps register (two flag tests through `0x66eedec`) and
  stores a boolean in `*out`. It is a query ("was this device gated?"), not a write.

So between "GFX on" and the RGX read, iOS's PMGR-side hardware writes for GFX are the ones
already listed. The only one no Linux run has made is AUTO_ENABLE (bit 28). Not traced: the
first part of `0x66f4a1c` (`0x66f4a1c`–`0x66f5738`, about 3 KB) for anything it does for a
device with GFX's entry before it reaches the ps write.

## Probe tokens (`probe/apple-j96-gpubridge.c`, `probe/README.md`)

Next boot, in this order: `gpu-ps-auto-watch` (PMGR only: does the domain gate itself under
AUTO_ENABLE?), `gpu-bridge-readback` (do the bridge writes stick? the reads are outside the
iOS path), then `gpu-bridge-id-auto` (may freeze). The first three tokens:

1. `gpu-bridge-write`: `ps_gfx` on → the 33 bridge writes, each announced → `ps_gfx` off.
2. `gpu-bridge-id-auto`, the iOS-exact order: `ps_gfx` on → AUTO_ENABLE → the 33 bridge
   writes in ADT order (bridge 10 then 11) → Fender probe writes and GPC 1 → 10 µs → read
   RGX+0x20 and +0x18 → GPC 0 → `ps_gfx` off.
3. `gpu-bridge-id`: as 2 without AUTO_ENABLE.

New accesses compared with stage 4: 33 writes in two windows that have never been touched
under Linux, and bit 28 of `ps_gfx`. A freeze is possible at the first bridge access;
recovery is the usual DFU boot. Reading the bridge registers back is outside the iOS path
here (iOS only reads bridge counters), so these runs do not do it.

## After the 10 Nov runs: the clock question (static, partial)

Runs 3–5 (`m1-bridge-20261110.log`): AUTO_ENABLE does not stick on `ps_gfx` and the domain
never gates itself; the bridge registers read 0x4 / 0 after power-on and hold all 33 written
values; the iOS-exact run still froze. The PMGR device-power path is no longer the suspect.

What is known about the GPU clock:

- ADT `/arm-io` `clock-frequencies` (96 entries) has no 365/450/550/600 MHz entry, and the sgx
  node has no `clock-ids`. pmgr `clocks` lists only AF, LIO, DISP0, MCU_FIXED, the two ISP
  sensor refs and VENC. So the GPU clock is not one of PMGR's fixed clocks: Fender ("VCM")
  generates it per perf state.
- AGXG4P gives the firmware a Fender mapping of 0x5000 bytes (`M0-STATIC-RE.md` section 2),
  but the host only ever touches +0x0..+0x14, +0x1000, +0x1004, +0x10000.. and +0x20000. So
  Fender has registers in 0x0–0x4fff that only the firmware (or iBoot) writes; a per-state
  clock/voltage table would live there. INFERRED.
- At probe time no firmware is running, yet iOS's state-1 request yields a readable core. So
  state 1 must work from values already in Fender: reset defaults, or values iBoot left.
- Our dumps show the seven host-visible Fender registers reset to 0 across a `ps_gfx` off/on.
  If iBoot's Fender setup is lost the same way, or was never done on the checkm8/Pongo boot
  path, state 1 would select no clock and the RGX read would hang exactly as seen. INFERRED,
  and the leading hypothesis now.

Not found by string search: any GFX PLL or perf-state table in ApplePMGR (the kernelcache
strings `gfx_divider_0`, `gfxdv_pwr`, `FenderPWRGate` are trace/report names, not code paths).

Next probe (not written): a wider read-only Fender dump with `ps_gfx` on, before any write
and again at GPC 1 (for example +0x1000–0x11fc, and the starts of +0x2000, +0x3000, +0x4000),
looking for a per-state table and whether it is empty. Those offsets have never been read; a
hang is possible. The other route is ground truth from iPadOS itself (plan M2: the same
registers read under a jailbroken 15.8.3).

## Fender scan, 10 Nov (`m1-fender-scan-20261110.log`)

No per-state clock table was found. With `ps_gfx` on and the bridges written, every scanned
Fender offset (+0x0–0x3c, +0x1000–0x11fc, +0x2000/0x3000/0x4000 samples, +0x10000–0x1001c,
+0x20000–0x2003c) reads zero before the Fender writes, apart from the sequencer window. At GPC 1
only the registers we wrote or the transition raised changed (+0x0, +0x14, +0x1000). So either
the table is somewhere not scanned, or Fender genuinely holds no configuration on this boot path.
The scan cannot tell those apart.

The sequencer window +0x10000 already held 0xffff0000 before the run's own write, followed by
random-looking words, unchanged by GPC transitions: SRAM that survives `ps_gfx` power cycles.

**What this leaves (INFERRED).** On a checkm8 boot the bootloader's hardware setup has already
run before Pongo takes over, on our Linux path and on palera1n's iPadOS boot alike, and Metal
works under palera1n. If that holds, the missing step is done by the iPadOS kernel itself
before AGXG4P's probe reads CORE_ID: in ApplePMGR's start, or another platform kext that runs
earlier, rather than in iBoot. That makes it findable statically in the kernelcache. The
untraced first ~3 KB of `0x66f4a1c` and ApplePMGR's start-up code are the first places to read.

## Trace in progress (10 Nov, stopped partway; READ unless marked)

- `0x66f4a1c` is the entry of `ApplePMGR::_enableDeviceGated` (its own assert string names it).
  It calls `0x66ee24c` (when there is no out pointer; posts event 0xc001), then runs the real
  body `0x66f4ad0` under the command gate (`[pmgr+0x160]` vt+0xe8).
- Body `0x66f4ad0`: looks up the device entry (`0x66e4624`); skips devices whose entry flags
  have both 0x10 and 0x20 set; target state = 0xf when enabling, else 0x4 or 0 (clock- or
  power-gated); checks PMGR state at +0x14c; calls `0x66f47a0` (and `0x66f2040` if it returns
  non-zero), then `0x66ef9bc(device, die)`, then compares the cached state byte
  (pmgr+0x19554 + die*0x260 + id) with the target and calls `0x66f5054` on a change. The
  device power-state path traced earlier (`0x66f5738`–`0x66f581c`) follows later in this body.
- `0x66ef9bc`: walks a per-device list (pmgr+0x18338, +0x179b8) over dies and, for entries
  whose byte 9 is set, calls `[pmgr+0x160]` vt+0x100 repeatedly until byte 0 clears. Looks like
  a wait on dependent clients or clusters. INFERRED; no register write seen in it.
- `0x66f5054`: a state-change notifier (calls `0x66e5db8`, `0x66f62c4`). No register write seen.
- `0x66f2040`: has delays (`0x670a92c` with 0xca00 and 0x4240) and an indirect call. NOT READ;
  this is the most likely place for hardware writes in the untraced part.

Not done yet: `0x66f2040` and `0x66f47a0` in full, and ApplePMGR's start (`0x66dc7a4`) for
one-time hardware setup that touches GFX or a GPU clock.

## External evidence: J81 (iPad Air 2, A8X), read 12 Nov

Source: mattonik/ipad-nixos `research/` (clone at 583540b, 11 Nov 2026), chiefly `gpu-status.md`,
`2026-11-10-j81-page5-capture-results.md`, `2026-11-10-j81-linux-gpc-page5-timed-probe.md`,
`2026-11-11-j81-ios-page5writer-result.md`, `2026-11-08-j81-gfx-perf-state-live-read.md`. Their
values are from J81 boots (T7001, iOS 15.8.x), not this device; raw logs are private to them.

- Same hang on J81: GFX `ps` 0x3ff, bridge writes (66 on A8X), Fender GPC 1, then the first RGX
  read never returns. Under iPadOS the same reads return (G4G A1).
- Their 66 Linux bridge stores match iOS's bridge writer calls in order: the bridges are
  not the gap there either.
- **GFX perf-slot table** at `0x20e01c000 + n*0x10` (16 entries; control `0x20e01c200`),
  written by LLB from fuses; iBoot derives the ADT `perf-states` from it. On J81 Linux it is
  populated (state 1 = 365 MHz) and unchanged by GFX power-on. On A9 the analogous records
  are applied by hardware when Fender is asked for state n.
- **PMGR page 5, `0x20e005004` bit 30**: iPadOS reads 0 before the GPC poll and 0x40000000
  after it; J81 Linux reads 0 after reaching GPC 1. LLB treats `0x20e000000`–`0x20e005fff` as
  six clock-like pages in a rate calculation. Cause and meaning unknown; a hooked iOS writer
  site saw no matching store (does not exclude hardware or firmware). The J81 author does not
  justify writing it.

Implication for J96 (INFERRED): a read-only PMGR snapshot here — the perf-slot table and its
control words, and `+0/+4/+8` of the six pages from `0x20e000000` — before and after `ps_gfx`
on and at GPC 1, would show whether J96 matches J81 (table populated, page-5 bit 30 clear).
All of it lies in pmgr reg[0], which the Linux PMGR regmap already maps.
