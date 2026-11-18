# J96 page-5 KPF probe (palera1n `--override-kpf`)

Read-only planned-panic probe for the iPad mini 4 (J96, A8, iPadOS 15.8.3
`19H386`). Captures PMGR clock page 5 `+0x4` at the AGX power-on point so the
working iPadOS value can be diffed against Linux. See the full spec in
`~/Projects/j96-omarchy/gpu/ios-panic-probe/README.md`.

Two hooks (J81 `page5writer` approach, no `ml_io_map`):
- **capture** `0x66e4294` (ApplePMGR ps-poll `blr x8`) — saves the PMGR object.
- **read** `0x6695a44` (AGXG4P post-GPC-poll `mov w0,#0xa`) — reads page 5 via
  `[pmgr]->vt[0x980](pmgr, 0, 0x5004, 0)` and faults (value lands in `x0`/`far`).

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

Unlock after reboot and read `x0`/`far` from the panic report
(`collect-ios-reports.sh`). `x0 == far == 0x40000000` = page-5 bit 30 set after
the GPC poll; `0` = still clear; `0xdead` = the capture hook never ran.
