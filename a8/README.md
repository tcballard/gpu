# A8 (T7000) GPU work: iPad mini 4 (J96)

Bring-up notes, hardware logs and probe modules for the GPU of the iPad mini 4 (J96,
iPad5,1, Apple A8 / T7000), on iPadOS 15.8.3 kernelcache analysis and a RAM-booted Linux
7.3.0-rc1 kernel. **Status: blocked at milestone M1.** The first read of the RGX core-ID
register hangs the SoC; no identity, firmware or job yet.

Read in this order:

1. `GPU-PLAN.md`: the plan and milestones.
2. `M0-STATIC-RE.md`: static analysis of AGXG4P (register windows, power-on, interrupts,
   META boot).
3. `M1-BRIDGE-FINDINGS.md`: the M1 investigation, newest sections last.
4. `m1-*.log`: one log per hardware run, with dates, setup and results.

| Path | What |
|---|---|
| `probe/` | Out-of-tree Linux probe modules (`apple-j96-gpudump`, `apple-j96-gpubridge`) and how to run them |
| `tools/` | ADT and Mach-O helpers used for the static analysis |
| `tools/serial/` | Host helpers for the J96 dev image's USB serial console |
| `../tools/a8/ios-capture/` | iPadOS-side capture tools (not completed) |
| `*.json` | Raw outputs of the analysis passes the notes were written from |

The probe modules drive real hardware and can hang the SoC; each run is gated, logged and
power-cycles the GPU domain afterwards. Paths under `/home/tcballard` in the notes are the
author's local checkouts. Nothing of Apple's binary data is committed here: no firmware,
kernelcache, device-tree dump or capture. Register values in the notes and in
`probe/apple-j96-gpubridge.c` were read from the device or its device tree.

Written with AI assistance (Claude) and checked on hardware where the logs say so.
