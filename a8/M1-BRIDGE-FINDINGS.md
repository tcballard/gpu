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

## PMGR clock snapshots, 12 and 16 Nov (`m1-clock-snap-20261112.log`, `m1-clock-wide-20261116.log`)

**J96 matches J81.** Decoded with J81's fit, f = 24 MHz × fb[20:12] / (pre[8:4] × (post[3:0]+1)):

- **GFX perf slots (pmgr+0x1c000 + n×0x10) are populated and match the ADT.** Slots 1–4 give
  365/450/550/600 MHz; slots 5–8 give 182.5/225/275/300 MHz (post divider doubled). The top byte
  goes 0x5f/0x65/0x70/0x70, which fits 600 + 3.125 mV × code = 896/915/950/950 mV (INFERRED). The
  table does not change with GFX power or GPC state.
- **pmgr+0x1c200** reads 0x80000000, and 0x80110100 at GPC 1. It drops back at GPC 0, so the Fender
  request reaches PMGR. +0x1c300 = 0x40000001 is constant. Nothing else in +0x1c000..+0x1c3fc is
  non-zero apart from the slots.
- **Six clock pages (pmgr+0xN000) share one register layout.** Pages 1 and 4 run: +0 decodes to 792
  and 1200 MHz with bit 31 set, and +4 = 0x40000000. Pages 0, 2 and 3 are idle: +0 = 0x1010 (24 MHz
  × 1, reset), and +4 = 0x80000001. **Page 5 is in a third state**: +0 = 0x1010, +4 = 0, +8 bit 24
  set, and +0x1c = 0x04040000 where the idle pages read 0x0c040000.
- **At GPC 1, page 5 reacts but does not start.** Right after the poll, +0x1c bit 27 is set; it is
  cleared again 1 s later. +0 and +4 never change. J81 iPadOS reads page 5 +4 = 0x40000000 after
  the GPC poll, the running-page status.

**Reading (INFERRED, now the leading hypothesis):** page 5 is the GFX PLL. Under iPadOS the state-1
request leaves it running at the slot-1 rate. Under Linux the request reaches it (the +0x1c flicker,
+0x1c200) but it never configures or locks. Its idle state (+4 = 0 rather than 0x80000001) suggests
an enable or ownership step that has not happened on this boot path. The RGX window has no clock,
which fits the hang.

Next (static): find what writes pmgr+0x5000..0x503c or +0x1c200/+0x1c300 in the 15.8.3
kernelcache. Candidates are ApplePMGR's start (`0x66dc7a4`), `0x66f2040` and `0x66f47a0`, plus any
other kext that maps pmgr reg[0]. If none does, it is iBoot (not run with GFX in mind on our path)
or hardware, and the iPadOS read (plan M2) is the route. Do not write page 5 until the sequence and
the GFX voltage are known.

## Who writes the GFX PLL? Static search, 16 Nov (READ, single analyst, not re-checked)

**No kernel code writes it with a literal offset.** Searched the 15.8.3 kernelcache: XNU
`__TEXT_EXEC` and all of `__PLK_TEXT_EXEC`, llvm-objdump with grep on immediates.

- `0x1c000`/`0x1c200`/`0x1c300` and page-5 offsets (`0x5000..0x503c` as immediates or `#0x5, lsl #12`)
  are absent.
- The few `0x5004`/`0x5008`/`0x500c` hits lie in unrelated kexts (struct offsets), or are object
  fields in AppleT7000PMGR (`+0x35008`).
- **ApplePMGR** (`__TEXT_EXEC` `0x66d6000`–`0x670aa4c`): its only `0x5000` constants build ASCII names
  (`0x66e2e58`, `0x66e2ef4`).
- **AppleT7000PMGR**, a SoC kext not traced before (`__TEXT_EXEC` `0x670b000`–`0x670d3e0`):
  - Methods include `initDriver`, `setPerfState(PerfDomainID, ...)`, `perfStateChangePending`,
    `getPerfStateTableIndex`, `configVideoClock`, `getISPRefClockFrequency`, and the `_pll4Frequency`
    and `_apscSCRLock` strings.
  - It registers register blocks by (id, offset) through `0x670d338`: `0x10218`, `0x1e000`, `0x2d000`,
    `0x30000`, `0x32000`, `0x190`.
  - None of these is page 5 or `0x1c000`.
- The pmgr ADT node has no GFX entry in `perf-domains` (SOC, CPU only) or the voltage states, and no
  PLL property.

**Reading (INFERRED).** The host never programs the GFX PLL. The Fender state request drives
PMGR's GFX perf state machine, which applies the perf slot (PLL fields plus a voltage code) in
hardware. Something that machine needs is in place under iPadOS and not under Linux.

Both boot paths reach the kernel through the same iBoot-then-Pongo handoff, so the missing piece
is either done by the iPadOS kernel through a data-driven offset (not found by literal search), or
undone or never done on the Linux side.

**Ruled out:**
- Linux switching off unused domains or clocks: `dev-image/config/bootargs` already has
  `clk_ignore_unused pd_ignore_unused`.

**Lead, weakened:**
- DWI (the PMGR-to-PMU voltage interface). iPadOS's AppleS5L8940XDWI start (`0x6c992a4`–`0x6c994f0`):
  1. clock gate and power gate on (device `0x36`);
  2. DWI `+0x0 = ((nclk-div<<16) - 0x10000) | polarity-config` (= 0x1);
  3. `+0x50 = str-delay×24/nclk-div` (= 0x2ee00);
  4. `+0x4 = lockout-us×24` (= 0x78);
  5. `+0x14 = 0`;
  6. `+0x10 = 0x41`.
- But DWI already works on Linux: the `dwi_bl` backlight (DWI `+0x10`) is enabled and in use, and
  `0x41` is the backlight's `SEND1 | LE_DATA`. So iBoot configured DWI.
- Still open: whether iBoot's `+0x0`, `+0x4` and `+0x50` match iPadOS's values. A read-only check of
  those three registers under Linux settles it.

**Next leads:**
1. Read the DWI registers and `ps_dwi` on Linux (read-only).
2. Trace AppleT7000PMGR `initDriver` and `setPerfState` in full, for data-driven writes.
3. The iPadOS read of page 5 and `+0x1c200` with the GPU active (new kprobe).
4. Compare with J81 again.

## DWI on hardware, 16 Nov evening (`m1-dwi-read-20261116.log`, `m1-dwi-ios-clock-20261116.log`)

- **Read-only.** `ps_dwi` is on (0xff). DWI `+0x0 = 0x1` matches iPadOS. `+0x4 = 0x3c`, where iPadOS
  writes 0x78. `+0x50 = 0`, where iPadOS writes 0x2ee00. `+0x10` and `+0x14` hold the backlight's
  CTL/CMD, which are in use.
- **Writing iPadOS's `+0x4` and `+0x50`, then GPC 1 (no RGX access):** the writes stick, but page 5 is
  unchanged (`+0 = 0x1010`, `+4 = 0`). **DWI timing is not the missing step.**

## External evidence update: J81, read 16 Nov evening (mattonik/ipad-nixos at baa4b22)

Their values come from J81 (A8X, iPadOS 15.8.5 19H394), not this device. Key notes:
`2026-11-16-j81-agx-postpower-page5-result.md`, `-pongo-gpc-page5-result.md`,
`-pongo-core-read-result.md` and `-pmgr-transition-gap.md`.

- **When bit 30 sets.** Under iPadOS, page 5 `+0x4` is 0 after AGX's clock and power calls, still 0
  after the Fender `+0x0 = 0x40000000` store, and `0x40000000` after the GPC `0x11` request's busy
  poll. The hardware sets it during the state-1 transition. This fits our static result: no kernel
  writer.
- **Not a Linux problem.** A bare-PongoOS replay of PMGR, the bridges and GPC reached state 1 with
  page 5 `+0x4 = 0`, and the first RGX read (`0x201000020`) stalled. The cause is not Linux-specific.
- **Their remaining gap: the rest of ApplePMGR's device-transition path.** That means dependent-device
  state changes, the transition and settle path, and ordinary PMGR register writes through vtable
  `+0x988`. Their earlier capture checked `+0x988` only for page 5 itself.

**Implication for J96 (INFERRED).** The next static target is ApplePMGR's `+0x988` ordinary-write
slot and every call to it on the GFX power-on path:

- the body `0x66f4ad0` and its callees `0x66f47a0` and `0x66f2040`;
- the dependency walk `0x66ef9bc`;
- whether AppleT7000PMGR overrides `+0x988`.

Correction (same evening): J81 had already enabled DWI before GPC (OrchardLinux/gpu `a8x/README.md`, "Power transport"), with no page-5 change. Our DWI result confirms theirs rather than adding to it.

`sgx` ADT check (16 Nov): there are no `function-*` hooks beyond `clock-gates`/`power-gates` (0x7c),
and no other node points at sgx. `gfx-qos = 1 1` is unexplained (probably memory QoS).

## ApplePMGR `+0x988` writes on the GFX power-on path, 16 Nov evening (READ, single analyst)

**Register access slots.** These are the same in all three PMGR vtables (ApplePMGR `0x6f3ec10`,
`0x6f432d8`, and AppleT7000PMGR `0x6f455d0`). T7000 does not override them.

- `+0x980` (`0x66ed478`) is `read(region, offset, die)`.
- `+0x988` (`0x66ed4f0`) is `write(region, offset, value, die)`, a plain 32-bit store at
  `regionmap(region, die)+0x18 + offset`.
- `+0x990` (`0x66ed564`) is `poll(region, offset, mask, expect, timeout, die)`.

The `+0x988` call sites reachable from `_enableDeviceGated` (`0x66f4a1c`) were checked one by one
against the GFX device entry. The entry raw is
`0000007c 00000000 00000403 ... 02 ... 0a0b ... "GFX"`: flags 0, no parents, no power-gate helper,
ps group 3 index 4, bridges 10 and 11.

| Site / function | What it does | Runs for GFX? |
|---|---|---|
| `0x66e3da0`, `0x66e3ed8` (sites `0x66e3e5c`, `0x66e41cc`..`0x66e4394`) | ps register: min level, target, AUTO_ENABLE | yes; already replicated |
| `0x66f60a8` | bridge settings (`+0x998`) | yes; already replicated |
| `0x66ef230` (from `0x66f5f48`, logs "reset") | ps reset: dev-disable bit 10, reset bit 31, polls bits 11 and 31 | no: reached only via `ARST` function objects, which exist for i2c0/2/3, displayport and isp only |
| `0x66efaf8` (sites `0x66efb78`, `0x66efd84`) | per-index control table at `[+0x2344]`/`[+0x2348]` (bit 5 set, low nibble) | no: needs the ADT `clusters` property, absent on J96 |
| `0x66f6798` (called at `0x66f537c`, `0x66f584c`) | perf-domain state write (poll bit 30 clear, then state into [3:0]) | no: guarded on entry flags byte 1 bit 4 and id 8 (USBCTRL) or 14 (USB2HOST2); GFX has flags 0 |
| `0x66f5e80` (loop over regions `0x29`..`0x2b`) | bit 0 set/clear | separate command-gated function, not in the body |

**Result.** On the path read, iPadOS's PMGR does nothing for GFX beyond what Linux already does.
This agrees with the 10 Nov trace.

**Not read:** `0x66f47a0`, `0x66f2040` (conditional, called at `0x66f4b94`/`0x66f4ba0`), and any
writes through other objects (Fender, AGXG4P, other kexts).

So the missing prerequisite is probably not a PMGR register write. The remaining candidates are:

1. state set before the kernel that differs between the iPadOS and Linux/Pongo boots. J81's
   bare-PongoOS stall argues against a Pongo-only difference, but palera1n iPadOS boots through
   Pongo too.
2. something AGXG4P or another kext does through a non-PMGR path.
3. a hardware dependency only an iPadOS-side read can show.

The iPadOS read (new kprobe) is now the most direct next step. J81's planned `+0x988` capture would
confirm this table empirically.

## Upstream check, 16 Nov evening (OrchardLinux/gpu `dd5e987`, PR #3, `a8x/README.md`)

New since our base `a609394`: only the J81 notes. Relevant to J96:

- J81 restored 20 power domains, and separately enabled DWI; neither changed page 5.
- **LLB writes PMGR pages nobody has explained.**
  - It sets bit 31 at five page bases, `0x20e010000`–`0x20e014000`.
  - It copies a 47-word table to `0x20e010000`–`0x20e0100b8`.
  - It writes six words at `0x20e00f208`–`0x20e00f21c`.
  - Whether these survive the checkm8/Pongo path is unrecorded.
- PMGR `0x2300c` reads 0 early under iPadOS and `0x164` after the GPU identity read.
- Their open leads: a SoC-tuner display-idle/MCC callback before the first RGX read, and a GFX
  `state-config` record.

Next (read-only): snapshot those LLB pages, `+0xf200..+0xf21c` and `+0x2300c` on Linux, and under
iPadOS through kprobe. Compare.

## Handoff snapshot, Pongo vs Linux, same boot (17 Nov; READ on hardware)

Route step 1. One cold boot: `./j96-boot --pongo-snapshot` peeked 671 PMGR words at the PongoOS
shell (the same palera1n beta3 + bundled Pongo that the iPadOS jailbreak boot uses), then the same
boot went on to Linux, where the read-only token `gpu-pmgr-handoff-snap` read the same words about
40 s after boot. Tools: `tools/handoff_regs.py`, `tools/pongo-handoff-snap.sh`,
`tools/linux-handoff-snap.sh`. Raw logs in `private/handoff-snap-20261117-095649-UKjW/`.

**Identical:** clock pages 0–4 (+0..+0x3c), the GFX perf area +0x1c000..+0x1c3fc (slots,
+0x1c200 = 0x80000000, +0x1c300), `+0x2300c` (0 in both), `+0xf208..+0xf21c` (0 in both), the LLB
table +0x10000..+0x100bc (all 48 words non-zero, unchanged), the bit-31 page bases
+0x11000..+0x14000, and the rest of those pages (all zero). `ps_gfx` is off in both. So the LLB
state does survive checkm8/Pongo and is not undone by m1n1 or Linux.

**Different, with an obvious explanation (24 ps registers):** CPU1 on under Linux; AUTO_ENABLE
(bit 28) set by the Linux PMGR driver on the always-on domains (LIO, IOMUX, SIO, MCC, MCU, SMX, SF,
DISP_BUSMUX, DISP0, SEP); unused I2C2/3 and UART1–8 (except UART5) powered off by Linux; SPI1 (touch)
and PCIE_REF/PCIE (Wi-Fi) powered on; AMP (+0x20240) on auto and clock-gated (actual 4).

**Different, unexplained (1 word): page 5 +0x1c bit 27.** Pongo reads 0x0c040000, like every idle
page (0, 2, 3); Linux reads 0x04040000, and so did the 16 Nov boot. All other page-5 words match
(+0 = 0x1010, +4 = 0, +8 = 0x81480348). On 16 Nov this bit came back on right after the GPC 1 poll
and was clear again 1 s later. Nothing in our Linux DTS addresses page 5; m1n1 (prebuilt) not checked.

**Reading (INFERRED).** The pre-kernel assumption mostly holds: what LLB/iBoot set up reaches Linux
intact, so the missing step is not lost bootloader state. The one exception is page 5 +0x1c bit 27,
the GFX PLL page itself: it is cleared somewhere between the Pongo shell and Linux userspace (m1n1,
early Linux, or a hardware side effect of a domain change such as AMP auto-gating). Whether iPadOS
still has it set when AGXG4P powers GFX is the open question.

## Data-driven page-5 writers: static check, 17 Nov (READ, single analyst, not re-checked)

- **ADT:** no property in any node holds a page-5 offset (0x5000..0x50ff, or the PA). The hits
  are device-name bytes, GPIO pin codes and the `nco` size field.
- **`0x66f47a0`:** a recursive bool predicate on the device entry (flags & 0x82, a `+0x1b0` config
  mode with a per-device record, or any parent). It makes no register writes and returns 0 for GFX,
  so **`0x66f2040` is never reached for GFX**.
- **`0x66f2040`:** waits on `+0x1b4`, or loops reading region 7 (reg[7], 0x207e00000) with 30 s/1 s
  deadlines. No writes.
- **AppleT7000PMGR:** every region-0 write has a literal or bounded offset; none is in page 5 or
  `+0x1c000..+0x1c3ff`. `setPerfState` (`0x670c0a8`) handles SOC (`+0x1a000`) and CPU (region 8)
  only, and panics for any other domain. `initDriver` (`0x670b568`) makes no writes.
  - Side note: vt+0x5c8 (`0x670b72c`) sets bit 30 of `+0x1008` and `+0x4008` (pages 1 and 4 +0x8),
    not page 5.
  - `configVideoClock` writes page 2 and `+0x10208`/`+0x10054`.
- Correction to 16 Nov: the `0x670d338` (id, offset) calls fill a register-dump table at `+0x2310`;
  they do not register mappings.
- ADT `perf-regs` = (reg 0, `+0x28000`, 0x29 entries); `perf-domains` = SOC and CPU only.

**Not covered:** `ApplePMGR::start` and `ApplePMGR::initDriver` bodies, the superclass methods that
T7000 tail-calls (vt+0x5d0, +0x5d8, +0x6c8), and other kexts.

## Page 5 +0x1c bit 27: when does it clear? 17 Nov (READ on hardware)

A read-only `early_initcall` in the built-in `apple-j96-gpuprobe` (kernel in `dev-image-early/`)
read page 5 at 0.019 s, before secondary CPUs and before any platform driver probed. Same boot,
`gpu-pmgr-handoff-snap` at 112 s. Logs: `private/handoff-snap-20261117-early-103123/`.

| Point | page 5 +0x1c | AMP ps |
|---|---|---|
| Pongo shell (morning boot) | 0x0c040000 | 0x0f0000ff |
| Linux 0.019 s (early_initcall) | 0x0c040000 | 0x0f0000ff |
| Linux 112 s | 0x04040000 | (auto, gated) |

So m1n1 and the Pongo-to-Linux handoff do not clear bit 27; something during the Linux boot does.
At 0.019 s `ps_cpu1` already reads 0x1f0 (on before SMP bring-up). Next: a watcher in the same
driver that prints page 5 +0x1c and the CPU1/MCC/MCU/AMP/GFX ps words at each initcall level,
after every platform-bus bind, and every 10 ms for 180 s.

**Watcher result, same day (supersedes the bit-27 lead above).** A second boot with a read-only
watcher (page 5 +0x1c and the CPU1/MCC/MCU/AMP/GFX ps words at every initcall level, after every
platform-bus bind, and every 10 ms; logs `private/handoff-snap-20261117-watch-110040/`):
1614 samples over 90 s, 1444 changes. **Bit 27 toggles continuously from the first read onward**
(0x04040000 <-> 0x0c040000, no other value), already before any driver ran. In the early read of this
boot it was clear; on the previous boot it was set. During back-to-back power-domain binds (~26 µs
apart) it alternates almost every sample; 10 ms polls catch irregular set periods.

So the Pongo-vs-Linux "difference" was a single sample of a live status bit. **Step 1 result
stands without exception: Linux receives the same pre-kernel PMGR state as the Pongo shell.**
Side observation (INFERRED): on idle pages 0, 2, 3 bit 27 is steady at 1; only page 5 flickers,
which suggests the GFX PLL page is actively doing something (handshake or retry) while idle.

## ApplePMGR start-up and initDriver: static check, 17 Nov evening (READ, single analyst, not re-checked)

- **Names corrected:** `0x66dc7a4` is `ApplePMGR::initDriver` (vt 0x598); `ApplePMGR::start` is
  `0x66d61f8` (vt 0x2b0). T7000's super calls at vt+0x5d0/+0x5d8/+0x6c8 are really slots 0x5c0
  (`0x66e8e10`), 0x5c8 (`0x66e9efc`) and 0x6b8 (`0x66eca4c`). The vtable address point is +0x10.
- **Regions on T7000** (`0x670b488`): only region 0 = reg[0] (0x20e000000) and region 8 = reg[1]
  (0x202220000) are mapped; bridges are mapped separately (`+0x2668`, reg[2+n]). Every other region
  (1, 6, 7, 0xc, 0x14, 0x1e, 0x28, 0x33, 0x4e) is unmapped. This corrects "region 7 = reg[7]" above.
- **Writers reachable from start/initDriver/the super methods:**
  - ps registers (only for `pmgr-debug-always-on` boot-arg devices, or as a restore for slots
    already at 0xf);
  - bridge settings (the same code as the GFX power-on path, already replicated);
  - a perf-regs statistics block at `+0x28000..~+0x283a0` (GFX not in it: flags 0, perf 0/0);
  - CPU block (region 8), and boot-arg-gated paths.
  - **None reaches page 5, `+0x1c000..`, or a GFX register.**
- ApplePMGR has `readGFXClkGenReg`/`writeGFXClkGenReg`/`waitGFXClkGenReg` (`0x66edeac`/`ee0`/`f18`,
  region 0x4e), but nothing calls them and region 0x4e is unmapped on T7000.
- **No tunables:** J96 pmgr has no settings list beyond `bridge-settings-N`.
- **SoC tuner** (`AppleT7000SOCTuner`, `pmgr/soc-tuner`, no reg): `device-set-0` = MEDIA, ISP,
  DISP1, DISP-FB-ACTIVE, GFX. It picks an MCC config (0–3) and calls `function-dispidle_ctrl` (disp0)
  and `function-mcc_ctrl` (AMCC memory-cache/DRAM config). It writes no PMGR or GFX clock state.
- **Not covered:** the init of the cached ps state (`+0x19094`), callPlatformFunction handlers,
  AMCC writes, AGXG4P/Fender non-PMGR paths, m1n1.

## Fender +0x2040..+0x20fc on J96, 17 Nov evening (READ on hardware)

Prompted by the A10 bring-up (OrchardLinux/gpu `a10/FENDER.md` §18.2: there Fender `+0x2048` is the
GPU coprocessor run bit and `+0x2050..+0x2058` are live; `+0x2058` changes at GPC 1). Extended
`gpu-fender-scan` (module `02fa7069…`) on a fresh normal boot; result 0, no freeze; log
`private/fender-scan-20261117-193319/`.

- **All 48 words read zero, both with `ps_gfx` on (scan A) and at GPC 1 (scan B, perf = 1).**
- Every other scanned range is identical to the 10 Nov run (apart from the sequencer SRAM window).

So J96's Fender has no A10-like IOP control or status words in that page, which fits the A8 having
no `gfx-kf` coprocessor. This lead is closed. The A10 recipe (start the IOP, then
`+0x1000 = 0x11`) is not portable as such.
