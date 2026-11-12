# apple-j96-gpudump: GPC 1 power-state dump (M1 follow-up)

Stage 4 of the built-in `apple-j96-gpuprobe` froze the SoC twice on its first RGX read
(`RGX+0x20`, 10 µs after Fender reported GPC state 1; `../m1-staged-20261103.log`). This
module repeats the power-on and Fender GPC 1 steps of stage 3 and only *reads* Fender and
`ps_gfx` around the transition. It never maps or touches the RGX window. It's a loadable
module, so no kernel rebuild or new boot image is needed.

Two tokens, each usable once per module load:

| Token | At GPC 1 | Use |
|---|---|---|
| `gpu-gpc1-dump-slow` | Every register read is announced first (300 ms each), then dump F | Run first. Six of the seven Fender registers have never been read on this hardware, so a hang names the register. |
| `gpu-gpc1-dump` | Dumps B (at once), C (+1 ms), D (+10 ms) with nothing printed in between, then E (+100 ms), F (+1 s) | The timed measurement: what Fender says at the moment stage 4 read RGX, and whether it changes. |

Both take dump A (powered, before any write, each register announced) and dump G (after
GPC 0). Timed lines carry the measured offset from GPC 1, e.g. `+12us`.

## Build (host)

```sh
make            # against iomarchy-j96-tNPWSDe4/build/linux-j96dev, LLVM=1
```

The vermagic must read `7.3.0-rc1-j96-firstboot+ SMP preempt mod_unload aarch64` (`modinfo`).
The kernel has no MODVERSIONS, so before loading check that the running kernel really is that
build tree (config and symbols), not only the same release string.

## Run (iPad, fresh boot, root console on ttyACM0)

1. Desktop off so the kernel console is on screen: `systemctl stop getty@tty1; chvt 1;
   printf '\033[9;0]' > /dev/tty1` (no blanking). Confirm on the screen with
   `echo '<0>J96GD_TEST' > /dev/kmsg`, and that `/proc/sys/kernel/printk` starts with 8.
2. Copy the module to `/run` (RAM), e.g. from the host over usb0:
   host `python3 -m http.server -b 10.96.0.1 8096 -d <dir with only the .ko>`,
   iPad `curl -o /run/apple-j96-gpudump.ko http://10.96.0.1:8096/apple-j96-gpudump.ko`,
   then check `sha256sum` on both sides.
3. Hand the node over and load (unbind first, or the module does not bind by itself):
   ```sh
   echo 201000000.gpu-probe > /sys/bus/platform/drivers/apple-j96-gpuprobe/unbind
   insmod /run/apple-j96-gpudump.ko
   cat /sys/bus/platform/devices/201000000.gpu-probe/attempt
   ```
4. `sync; echo gpu-gpc1-dump-slow > /sys/bus/platform/devices/201000000.gpu-probe/attempt`
5. `dmesg | grep J96GD`, then the same with `gpu-gpc1-dump`.

## If it hangs

The last `J96GD_NEXT` line on the iPad screen names the access.
- Slow token: the line names the register being read.
- Fast token: `write Fender+0x1000 = 0x11 and poll bit 4, then read dumps B, C, D ...` as the
  last line means one of the silent B/C/D reads hung (stage 3 proves the write and the poll).

## Reading the result

Each `J96GD_DUMP` line has `ps` (ps_gfx raw: target [3:0], actual [7:4], was-gated flags
[9:8], device-disable 10, parent-off 11, reset 31) and the seven Fender registers of iOS's own
state dump. Compare A (powered, before any write), B (GPC 1, the moment stage 4 read RGX),
C–F (later) and G (GPC 0). In particular: `sleep` (SLEEP_CONTROL; bit 29 = SNOOP, bits 29+30 =
off, and whether it still reads 0x40000000), `kick` (KICK_STATUS) and `next` (PERF_NEXT) at B
against F. If the fast run's dump A differs from the slow run's dump A, the first run changed
the state: repeat the fast token alone on a fresh boot.

---

# apple-j96-gpubridge: GFX bridge settings, then the core ID (M1, next stage)

`../M1-BRIDGE-FINDINGS.md`: iPadOS rewrites a device's "bridge settings" each time the device
reaches power state 0xf, and GFX owns two bridges (0x201f00000, 0x201f80000) that nothing on
the Linux side writes. This module does those 33 writes after `ps_gfx` on, then repeats
stage 4 of the built-in probe (Fender GPC 1, then read `RGX+0x20` and `RGX+0x18`).

| Token | What it does | Use |
|---|---|---|
| `gpu-bridge-write` | `ps_gfx` on, the 33 bridge writes each announced first (about 10 s), `ps_gfx` off. No Fender, no RGX. | Run first. Shows whether the writes are survivable; a hang names the register. |
| `gpu-bridge-id-auto` | The iOS-exact path: `ps_gfx` on, AUTO_ENABLE (bit 28) set as ApplePMGR does, the 33 writes back to back, Fender to GPC 1, 10 µs, the two RGX reads, GPC 0, `ps_gfx` off. | Run third, only if `gpu-bridge-id` returned. From the bit 28 write to GPC 0 nothing sleeps or prints; results print at the end. If `gpu-bridge-id` froze, run this alone on the next boot. NOT yet re-reviewed after its rewrite (9 Nov). |
| `gpu-bridge-id` | The same without AUTO_ENABLE (domain forced on, as every earlier stage). | Run second: differs from the twice-frozen stage 4 only by the bridge writes. |

With AUTO_ENABLE set the domain may gate itself, so the module re-reads `ps_gfx` after every
announce pause and stops (`J96GB_ABORT ps_gfx reads ...`) without touching GFX registers if it
no longer reads target 0xf and actual 0xf.

Build, copy and console setup are as for the dump module above. Only one of the probe drivers
can own the node:

```sh
rmmod apple_j96_gpudump 2>/dev/null     # if the dump module is loaded
echo 201000000.gpu-probe > /sys/bus/platform/drivers/apple-j96-gpuprobe/unbind 2>/dev/null
insmod /run/apple-j96-gpubridge.ko
cat /sys/bus/platform/devices/201000000.gpu-probe/attempt
sync; echo gpu-bridge-write > /sys/bus/platform/devices/201000000.gpu-probe/attempt
sync; echo gpu-bridge-id > /sys/bus/platform/devices/201000000.gpu-probe/attempt
sync; echo gpu-bridge-id-auto > /sys/bus/platform/devices/201000000.gpu-probe/attempt
dmesg | grep J96GB
```

## If it hangs

- `gpu-bridge-write`: the last `J96GB_NEXT write bridge N +0x.. = ...` line names the write.
- `gpu-bridge-id-auto` or `gpu-bridge-id`, last line `write the 32 bridge 11 register(s), no pauses` (or the bridge 10
  one): a bridge write hung although it passed one by one; timing matters.
- Either id token, last line `write Fender+0x1000 = 0x11 and poll bit 4, then at once read
  RGX+0x20 and RGX+0x18`: the RGX read still hangs with the bridges written. The bridge
  settings are then not sufficient (or not the cause).

## Reading the result

`J96GB_ID core_revision=... core_id=...` and `J96GB_ID_OK G4P B0|B1, N cores` is M1 done:
record both values, and repeat on a second cold boot (the plan's "stable across two cold
boots"). `J96GB_ID_UNEXPECTED` with values that are not all-ones or zero still means the
window answers.

## Diagnostic tokens (added 10 Nov, after `gpu-bridge-id` froze on the RGX read)

Neither touches Fender or RGX. Next boot order: `gpu-ps-auto-watch`, `gpu-bridge-readback`,
then `gpu-bridge-id-auto`.

| Token | What it does | Lines to read |
|---|---|---|
| `gpu-ps-auto-watch` | `ps_gfx` on, AUTO_ENABLE set as iOS does, `ps_gfx` sampled at 0, 100 µs, 1 ms, 10 ms, 100 ms, 1 s, 3 s, AUTO_ENABLE cleared, off. PMGR accesses only. | `J96GB_AUTO +...us ps=... (target, actual)`: does actual leave 0xf, and when? |
| `gpu-bridge-readback` | `ps_gfx` forced on, the 33 bridge registers read (each announced; never read before, and iOS does not read them), the 33 writes, read again, off. | `J96GB_RB before/after ...` and `N of 33 registers read back the written value`. If "before" already equals the ADT values, the writes were never a variable. |

## `gpu-fender-scan` (added 10 Nov, after `gpu-bridge-id-auto` froze too)

Looks for a per-state clock/voltage table in Fender and whether it is empty
(`../M1-BRIDGE-FINDINGS.md`, "the clock question"). `ps_gfx` forced on, the 33 bridge writes,
then scan A (before any Fender write), the Fender probe writes to GPC 1, scan B, GPC 0, off.
No RGX access. Each scan reads +0x0–0x3c, +0x1000–0x11fc, +0x2000–0x203c, +0x3000–0x303c,
+0x4000–0x403c, +0x10000–0x1001c and +0x20000–0x2003c, eight registers per announce (about
8 s per scan). Almost all of these offsets are outside what the iOS host driver reads, so a
hang is possible; the last `J96GB_NEXT scan ...` line names the eight registers.

Read `J96GB_FS A-powered +0x.....: ...` against `J96GB_FS B-gpc1 ...`: a block of similar
non-zero words (one per perf state) would be the table; "all 8 zero" everywhere in
+0x1000–0x11fc at both points supports "state 1 selects no clock". Photograph the screen if
it freezes: the lines already printed are the only record.

## `gpu-pmgr-clock-snapshot` (added 12 Nov, after reading the J81 research)

Read-only PMGR snapshots to compare the J96 with the J81 (iPad Air 2) results in
`../M1-BRIDGE-FINDINGS.md` ("External evidence"). Each snapshot reads the GFX perf-slot table
(pmgr+0x1c000 + n*0x10, +0 and +4, 16 entries), its control words (+0x1c200, +0x1c300),
+0/+4/+8 of six clock-like pages (pmgr+0x0000..0x5000) and ps_gfx. Snapshots: `0-gfx-off`,
`1-ps-on`, `2-bridged`, `3-gpc1` (right after the GPC 1 poll), `4-gpc1+1s`, `5-gpc0`,
`6-ps-off`. Fender and bridge accesses as `gpu-fender-scan`; no RGX access.

What to look for in the `J96GB_CS` lines:
- `slot01-04`: should decode to 365, 450, 550, 600 MHz (the ADT `perf-states`), with
  f = 24 MHz × fb[20:12] / (pre[8:4] × (post[3:0] + 1)) as fitted on J81.
- `page5 +4` at `3-gpc1`: 0x40000000 would match iPadOS on J81; 0 would match J81 Linux.
- Any word that changes between `1-ps-on`, `3-gpc1` and `5-gpc0`.
