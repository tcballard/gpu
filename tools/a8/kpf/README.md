# J96 full-state KPF probe (palera1n `--override-kpf`)

Read-only planned-panic probe for the iPad mini 4 (J96, A8, iPadOS 15.8.3
`19H386`). Captures the six PMGR clock pages' `+0x04` (running-status) words,
`ps_gfx`, the GFX perf-state control words, `0x2300c` and the page-5 words
that differ from Linux, at the AGX power-on point, so the working iPadOS state
can be diffed against Linux. See the full spec in
`~/Projects/j96-omarchy/gpu/ios-panic-probe/README.md`.

Two hooks (J81 `page5writer` approach, no `ml_io_map`):
- **capture** `0x66e4294` (ApplePMGR ps-poll `blr x8`) — saves the PMGR object.
- **read** `0x6695a44` (AGXG4P post-GPC-poll `mov w0,#0xa`) — reads the region-0
  mapped base from `[pmgr + 0xa70]`, dumps 17 words into `x2..x21`, then faults
  (`far = 0xbeef`). Register map in `j96_page5_shell.S` and `decode_dump.py`.

## Files

| File | What |
|---|---|
| `j96-kpf.patch` | 4-file patch (2 new + 2 one-line) to apply to `checkra1n/pongoOS` |
| `j96_page5_capture.c` | KPF component (for reference; already in the patch) |
| `j96_page5_shell.S` | shellcode (for reference; already in the patch) |
| `verify_sites.py` | offline signature/UUID check against the kernelcache |

## Build (CI)

`.github/workflows/a8-kpf.yml` clones `checkra1n/pongoOS` at
`ce17354ad7daa5e650be0709fb5de5afabe5c461`, applies `j96-kpf.patch`, and runs
`make build/checkra1n-kpf-pongo` on the macOS runner (Xcode's `ld64` handles
`-kext`; LLVM `ld64.lld` does not). The artifact is `checkra1n-kpf-pongo`.

## Run

Verify the module SHA-256, then from DFU:

```sh
sudo palera1n --rootless \
  --override-kpf <path>/checkra1n-kpf-pongo --debug-logging
```

Unlock after reboot and collect the panic report (`collect-ios-reports.sh`).
Decode the dump with `decode_dump.py panic-full-*.ips`: `far == 0xbeef` means
the dump was captured, `0xdead` means the capture hook never ran. The page-5
`+0x04` value (register `x7`) is the M1 answer: bit 30 set = GFX PLL running.
