# Handoff: J96 GPU bring-up, afternoon of 17 Nov 2026

iPad mini 4 (J96, iPad5,1, A8/T7000). This picks up from `NEXT-SESSION.md` (17 Nov, morning)
and records what was done and paused later that day. Read `NEXT-SESSION.md` first for the general
setup, boot recipes and rules, then this file, then the last four sections of
`M1-BRIDGE-FINDINGS.md`.

## Where it stands

**M1 route step 1 is done: the pre-kernel state matches.**
- A same-boot, read-only snapshot of 671 PMGR words at the PongoOS shell and under Linux agrees on:
  - clock pages 0–5;
  - the GFX perf table and its control words (`+0x1c000`–`+0x1c3fc`);
  - the LLB-written pages (`+0x10000`–`+0x140bc`, `+0xf208`–`+0xf21c`);
  - `+0x2300c`.
- The only differences are power domains Linux deliberately changes: CPU1, AUTO_ENABLE on the
  always-on domains, unused I2C/UART off, SPI1 and PCIe on, AMP on auto.
- So the LLB/iBoot state survives checkm8 → Pongo → m1n1 → Linux. The missing GPU-clock step is
  in the running iPadOS state around AGXG4P's GPC state-1 request.

**Page 5 `+0x1c` bit 27 is a live status bit, not a lead.**
- An early_initcall read and a read-only watcher show it toggling continuously from the first Linux
  read onward (`0x04040000` ↔ `0x0c040000`).
- The morning's single Pongo sample happened to catch it set.
- The one curiosity (INFERRED): idle pages 0, 2 and 3 hold bit 27 steady at 1; only page 5
  flickers.

**Static (option 2), done so far (single analyst, not re-checked):**
- No ADT property points at page 5.
- `0x66f47a0` and `0x66f2040` make no register writes, and `0x66f2040` is not reached for GFX.
- Every AppleT7000PMGR region-0 write has a literal offset outside page 5 and the GFX perf area.
- `setPerfState` handles only SOC and CPU.

## Update, later 17 Nov: replies from the Orchard GPU people

- **The Orchard iOS capture tool can't answer M1.** `tools/a10/ios-capture` (OrchardLinux/gpu)
  saves only memory the GPU driver shares with the app, plus the logged IOKit calls. Page 5 is
  a PMGR hardware register (PA `0x20e005000`), reachable only from the kernel. Our own
  `GPUCapture.app` (branch `a8-ios-capture`) already does the same job on the A8; it is what M2
  used.
- **Orchard has no planned-panic tool.** They read "page 5" as GPU firmware shared memory. The
  planned-panic series is mattonik's (ipad-nixos, `research/probes/j81-agx-postpower-panic`),
  with private artifacts: ask that author, not Orchard.
- **New lead (open): how does the A10 (iPad 6) Linux bring-up get the GPU clock running?** Their
  GPU powers up and answers under Linux, so something in their path (m1n1, PMGR, perf state,
  power sequence) starts the GFX clock before the first RGX read. A reply asking for their
  register-level "before the first RGX read" sequence was drafted for Henrik Klee (Orchard). If he
  answers, compare its step order with ours (the PMGR layout differs between A8 and A10).

## Paused or open

1. **iPadOS-side capture of the working state (route step 2): paused here.**
   - The plan is to ask the J81 author (mattonik/ipad-nixos) for their planned-panic capture tool,
     or to ask them to add page 5 and related words to their next capture.
   - The user is contacting them; a draft message was written in the 17 Nov session.
   - In this session, work on applying a change to the iPadOS kernel at boot was stopped by a
     safety check. Nothing was built for it. Do not pick that work up again from here; use the
     J81 author's tool or data.
2. **A page-5 characterisation token: planned, not built.**
   - The idea was a read-only token sampling page 5 rapidly at GFX off, `ps_gfx` on and GPC 1.
   - Writing it was stopped by a safety check, and the probe source was left unchanged (verified).
     It was not attempted again.
3. **Static: `ApplePMGR::start` / `initDriver`.**
   - A background agent was tracing these, the superclass methods AppleT7000PMGR tail-calls, any
     ADT tunables applied at start, and J81's SoC-tuner display-idle/MCC lead.
   - Its result had not arrived when this handoff was written.
   - Its working files are in the temporary scratchpad (below). If they are gone, redo the task.
4. **Unpushed commits** on `tcballard/gpu` `a8-bringup` (local clone `~/Projects/orchard-gpu-fork`):
   - `fca9b7e` (step 1 snapshot tools and result);
   - `364379f` (bit-27 result, static check, watcher patch; it also carries an edit to
     `NEXT-SESSION.md` revising step 2 to "ask the J81 author").
   - Ask the user before pushing.
5. **Other work, while M1 waits** (from `NEXT-SESSION.md`): the AGX firmware command-queue trace
   from `0x6693234` (M4 prep), and the M2 shader comparison with the A10.

## Files on this laptop

**Notes and tools** (working folder `~/Projects/j96-omarchy/gpu/`; mirrored to `~/Projects/orchard-gpu-fork/a8/`):

| Path | What |
|---|---|
| `M1-BRIDGE-FINDINGS.md` | the results above, last four sections |
| `tools/handoff_regs.py` | the 671-word register list; `pongo-cmds`, `parse`, `diff`, `c-table` |
| `tools/pongo-handoff-snap.sh` | peeks at the Pongo shell through the hash-checked pongoterm; log to `private/` |
| `tools/linux-handoff-snap.sh DIR` | Linux half over SSH (token `gpu-pmgr-handoff-snap`), then diff. DIR must be an absolute path. |
| `probe/apple-j96-gpubridge.c`, `.ko` | adds token `gpu-pmgr-handoff-snap` (read-only). Module sha256 `348162d2…c678`, vermagic `7.3.0-rc1-j96-firstboot+`. |
| `probe/apple-j96-gpuprobe-watch.patch` | the early-read and watcher patch for the built-in driver (reference only; not applied) |
| `probe/README.md` | entry for the new token |
| `HANDOFF-20261117-PM.md` | this file (not yet committed to the mirror) |

**Boot tooling** (`~/Projects/j96-omarchy/`):
- `j96-boot`: two new opt-in flags; without them it behaves exactly as before.
  - `--pongo-snapshot`: snapshot at the Pongo shell, then ask before continuing into Linux.
  - `--image DIR`: boot `DIR/scripts/boot.sh` instead of `dev-image`.
- `dev-image/`: the normal dev image, unchanged.
- `dev-image-early/`: a copy of it with only the kernel swapped, to the **watcher kernel**
  (`Image.gz` `01ae482c…`). Its config is newer than `dev-image`'s (Bluetooth and more), and it
  floods the kernel log for 3 minutes after boot. Use only for that experiment; delete when no
  longer needed.

**Kernel build** (`~/Projects/iomarchy-j96-tNPWSDe4/build/`):
- The source is `linux-src-touchbus/` (not `src/linux`), and the output is `linux-j96dev/`.
- `drivers/misc/apple-j96-gpuprobe.c` has been restored to its original (it isn't tracked in git).
- The last compiled `linux-j96dev/arch/arm64/boot/Image.gz` still contains the watcher; the next
  build rebuilds it from the restored source.

**Hardware logs (Apple data, private only)** (`~/Projects/j96-omarchy/private/`):
- `handoff-snap-20261117-095649-UKjW/`: `pongo.log` and `linux.log` (step 1, same boot).
- `handoff-snap-20261117-early-103123/`: `early.log` (0.019 s read) and the late snapshot.
- `handoff-snap-20261117-watch-110040/`: `watch.log` (dmesg; the first 21 s were lost to the
  ring buffer) and `journal.log` (the full watcher log from the journal).

**Reference material, permanent** (`~/Projects/j96-omarchy/downloads/ext-20261117/`):
- `ipad-nixos/` (J81 notes at `0f42b65`). The planned-panic write-ups are
  `research/probes/j81-agx-postpower-panic/README.md` and
  `research/2026-11-16-j81-agx-postpower-page5-result.md`. Their capture tool is not public.
- `palera1n-src/` (beta3 source at `42d6506`). `src/pongo_helper.c` holds the Pongo boot command
  sequence.

**Temporary (session scratchpad, may vanish)**
(`/tmp/claude-1000/-home-tcballard/9d353325-863e-47af-ab58-a70e632904eb/scratchpad/`):
- `agent-pmgr/`: full disassembly of ApplePMGR and AppleT7000PMGR (kernelcache-derived; do not copy
  into a repo).
- `agent-pmgr2/`: working files of the unfinished start/initDriver trace.
- Backups: `apple-j96-gpuprobe.c.orig`, `j96-boot.orig`, `Image.gz.prev`.

## State of the hardware

- At the time of writing, the iPad was running the watcher kernel from `dev-image-early/`.
- A clean `systemctl poweroff` was slow earlier that day; forcing it off (Home + Power, about
  10 s) is fine once Linux has left USB.
- For the next normal boot: `./j96-boot`, without `--image`.

## Rules (unchanged)

- Read-only on PMGR clocks: no guessed writes to page 5, the perf table or any voltage. No RGX
  access under Linux.
- Apple data stays in `private/`.
- Ask before pushing or opening a PR.

## Lead from Orchard's A10 code (17 Nov, evening)

On the A10 the core becomes readable after: `ps_gfx` on → GPU coprocessor (`gfx-kf`, RTKit)
firmware placed and started, run bit **Fender `+0x2048` bit 0** → `Fender+0x1000 = 0x11` with
readback. Before that request their Fender read `+0x2048 = 1`, `+0x2050 = 0xf`, `+0x2054 = 0x2f`,
`+0x2058 = 1`; after it `+0x2058` = 0 (their firmware treats `+0x2058` as part of a reset step).
Sources: OrchardLinux/gpu `a10/FENDER.md` §18.2, `a10/bringup/kernel.md` §1.5. The A8 has no
`gfx-kf` (J96 ADT has no `has-kf`), so this is not directly portable. But J96's Fender
`+0x2040..+0x20fc` had never been read: `gpu-fender-scan` now reads it (last range).
Module sha256 `02fa7069…`. Run: `gpu/tools/linux-handoff-snap.sh <abs private dir> gpu-fender-scan`.
