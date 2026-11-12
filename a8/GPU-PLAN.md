# J96 (A8 / T7000) GPU acceleration: synthesis and plan

Sources: the five investigations are tagged [a10-method], [j96-adt], [j96-kexts], [mainline] and [orchard-patches]. My own checks in this pass are tagged [lead]. Anything inferred is marked INFERRED.

## 1. What the A8 GPU is and how Apple runs it

**Verdict: the A8 runs Apple-built firmware on the Rogue core's own META MCU. There is no RTKit coprocessor.** Confidence is high. All five investigations agree, independently.

- **Kexts.** The kernelcache has only com.apple.AGXG4P (IOClass AGXAcceleratorG4P_B0, IONameMatch 'gpu,t7000', MetalPluginName 'AGXMetalA8') and com.apple.AGXFirmwareKextG4P [j96-kexts].
  - The firmware kext matches IOResources and links no RTBuddy or AppleA7IOP. A search for 'AGXFirmwareKextG4PRTBuddy' finds 0 matches [j96-kexts].
  - The driver code is FWController/agxk_fwc_meta.cpp. Its strings include 'RGX_CR_META_BOOT 0x%08X', 'Timed out waiting for META slave port idle' and 'METADEBUG: Timedout waiting for META alive!' [j96-kexts], [j96-adt].
- **ADT.** The only GPU node is /device-tree/arm-io/sgx ('gpu,t7000'). There is no gfx-kf node or GPU IOP; the only IOPs are sep, ans and sio [j96-adt], [a10-method], [orchard-patches].
- **Firmware image.** The firmware is a standard IMG META LDR stream, 114,796 bytes long, in AGXFirmwareKextG4P's __TEXT.__const [j96-kexts], [mainline].
  - Its header has devid 0x01aa5500 and sl_data 0x1190.
  - It holds 90 L1 blocks: 70 LOADMEM, 12 ZEROMEM, 2 CONFIG, 5 of cmd 0x10 and 1 START_THREADS.
  - It was built from two thread ELFs, g4p_b0_t0.elf and g4p_b0_t1.elf, and its build stamp is 'Oct 15 2023 02:09:45'.
- **Core identity.** The core is G4P revision B0 in Apple's naming, from the AppleEmbeddedGPUDriversGX2G4 source tree. It uses the legacy (pre-G5) BIF MMU, with no DART [j96-kexts], [j96-adt]. The kernelcache contains no BVNC or marketing string at all [j96-kexts].
  - "GX6450, Series 6XT, 4 clusters" comes from outside knowledge and is unconfirmed until RGX_CR_CORE_ID is read on hardware. INFERRED.
- **Host–firmware protocol.** The protocol is Apple's AGF channel model: TA/3D/CL channels, submitDeviceControl(AGFIAcceleratorRingEntry*), and event, log and trace rings. It is not IMG's RGXFWIF KCCB/FWCCB; grepping for RGXFWIF and kccb finds nothing [j96-kexts], [mainline].
- **Fender.** A Fender/GPC block exists (agxk_fender_meta.cpp, 'Could not map Fender reg range', setGPCPerformanceState) [j96-kexts], [orchard-patches]. It is probably the second sgx window, PA 0x201e00000 (INFERRED, consistent across [j96-adt], [a10-method] and [orchard-patches]). Its register layout is unverified.

### Contradictions resolved

1. **What meta-sw-interrupt points at.**
   - [orchard-patches] calls 0x20e104010 and 0x20e104090 "PMGR address space" and a host-to-META doorbell.
   - [j96-adt] shows that PMGR reg[0] is 0x20e000000 + 0x40000, which ends at 0x20e040000. AIC is 0x20e100000 + 0x100000. So these words are AIC+0x4010 (SW_SET) and AIC+0x4090 (SW_CLR), in the word that covers IRQs 128–159. The bits are 0x40 (IRQ 134) and 0x400 (IRQ 138).
   - **[j96-adt] is correct: these are AIC registers, not PMGR.**
   - My reading (INFERRED, [lead]): META cannot be an AIC target, so a write to AIC SW_SET can only raise an interrupt towards the AP. The likelier meaning is that these registers let the firmware (or the host, re-triggering itself) raise and clear AP IRQs 134 and 138 in software. The host-to-META kick is then probably a separate RGX register (META/MTS). This must be settled by disassembling AGXG4P's use of 'AICSWIntRegs'. Until then, do not write these registers.
2. **IRQ routing.** On the A10 the RGX IRQ goes to the IOP, and the orchard patch skips pvr_device_irq_init [orchard-patches]. On the A8 the 5 sgx IRQs (134–138) go to AIC, so the AP gets real interrupts [j96-adt]. The A10 polling shortcut is not needed, but it can be kept as a fallback.
3. **Page size.**
   - The A10 driver assumes 16K pages (PD_VALID_16K) [orchard-patches].
   - J96 runs 4K pages, and Orchard notes say A7/A8/A8X have no 16K granule [orchard-patches]. Mainline pvr_mmu uses PAGE_SIZE and supports 4K [mainline].
   - The kext string 'GPU uses 16K page size but CPU does not' [orchard-patches], [mainline] means the GPU page size is a configuration choice. On A8, iOS itself runs 4K pages (INFERRED), so the firmware should accept 4K.
   - **Conclusion: 4K is the expected setting and is not a blocker**, but it has to be confirmed in the firmware's MMU setup.
4. **Which reference is "closer" for booting.** [mainline] says mainline's META boot is the starting point. [a10-method] and [orchard-patches] say the A10 Apple variant is the template. Both are right, for different layers:
   - Boot and loader: mainline pvr_fw_meta.c and pvr_fw_startstop.c. [lead] confirmed that the local tree has meta_ldr_cmd_loadmem, meta_ldr_cmd_zeromem and meta_ldr_cmd_config, and META_SP_MSLVCTRL1 polling, in pvr_fw_meta.c lines 41–204.
   - Device attachment (static device info, Apple pwr_ops, no IMG header) and the job/queue layer: the A10 pvr_apple*.c structure.
   - The A10 RTKit, mailbox, window and G9P init data (X/P/T/U/V, 13 rings): discard. Nothing of it applies.
5. **m1n1 OPP fill.** [a10-method] and [orchard-patches] say m1n1 fills the GPU OPP table from sgx perf-states. [lead] checked the local m1n1 trees: /home/tcballard/Projects/orchard-hardware/boot/m1n1/patches contains only j71b/0001-j71b-boot-support.patch, and /home/tcballard/Projects/orchard-omarchy-a/boot/m1n1/patches contains only j71b/0002-omarchy-splash.patch. Grepping both for sgx or gpu finds nothing. **The J96 m1n1 build does not have orchard patch 0011.** DVFS needs that patch or a static OPP table in the DT.
6. **Is the unstripped iOS 10 tree a G4P reference?** [a10-method] lists AGXFirmwareKextG4P among the T8010 and s8000 trees. Whether a G4P driver (AGXG4P / AGXAcceleratorG4P with symbols) is in there is not established. [lead] tried the GitHub API and the request failed: 'curl: (35) TLS connect error'. This stays open, and it is a cheap, high-value check (see M2).

## 2. Best route and hard blockers

**Recommended route: a hybrid.** Build an "Apple G4P" variant of upstream drm/imagination:

- mainline META LDR loader and META start/stop register sequences
- plus the A10-style Apple attachment (static device info, no IMG firmware header, Apple pwr_ops)
- plus a new G4P host-protocol backend rebuilt from AGXG4P
- with the powervr UAPI kept, so Mesa's pvr Vulkan driver plus Zink can sit on top.

### Rejected options

- **Mainline drm/imagination with IMG firmware.** No IMG image exists for a 4-cluster 6XT part. The staging images are 4.40.2.51 and 4.45.2.58 (GX6250, 2 clusters), 4.46.6.62 (GX6650) and 5.9.1.46 (G6110), and the kernel requires an exact BVNC match (pvr_fw.c:128) [mainline]. Forcing gpuid= would pair the wrong device info with a probably Apple-modified core. INFERRED.
- **Mainline with Apple's firmware.** Rejected as-is. The image is not a multiple of 4K and has no pvr_fw_info_header (the first u32 at size−4K is 0xae000) [mainline], and it speaks AGF, not FWIF.
- **Porting the A10 variant directly.** Rejected. RTKit, the A7IOP mailbox and the G9P ABI do not exist on A8 [orchard-patches].

### Hard blockers, ranked

1. **The host-firmware ABI is undocumented.** This is the biggest blocker. It covers the G4P init structures, the AGF ring entries, the TA/3D/CL channel layout and the kick mechanism. On the A10 this came from an unstripped iOS 10 T8010 kext (3647 symbols) plus crash-by-crash rebuilding [a10-method]. **No unstripped T7000 AGX kext is known** [a10-method]. We have a stripped 15.8.3 AGXG4P with rich assert strings and about 281 KB of __text [j96-kexts]. Whether iOS 10 trees carry a symbolled G4P driver is unverified (see 1.6).
2. **The shader ISA is unknown.** AGX_CR_USC_INST_BASE_FRAG and AGX_CR_USC_PARTITION_CONFIG hint at an Apple-modified USC [j96-kexts], and the A10 USC is Apple's despite Rogue fixed-function hardware [a10-method]. Current Xcode ships only libapplegpuG9G12 [a10-method], so there is no metal-tt target for G4P (INFERRED). Ground truth needs captured shaders from iPadOS 15.8.3 via palera1n (A8 supports checkm8; palera1n on 15.x is INFERRED to work).
   - If the ISA is stock Rogue 6XT, Mesa pco may be reusable, which would be a large win [mainline].
   - If it is Apple-modified, a new G4P encoder is needed, as on the A10. That is months-scale without a toolchain.
3. **Mesa support.**
   - Mesa has no GX6450 device-info entry.
   - 6XT support is "partially supported" only for GX6250 4.40.2.51, and 4.45 and 4.46 are "unsupported" [mainline].
   - It needs PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1.
   - The A10 work also had to bypass shared code (no per-render SPM/load-op programs) and found the firmware has no transfer engine [a10-method].
   - Mesa upstream declines LLM-generated code [mainline], so this stays a private fork.
4. **Firmware licensing.** Apple's image must be extracted from the user's own IPSW at runtime and never committed or redistributed [j96-kexts]. That is a policy constraint, not a technical one.
5. **MMU page size.** Not a blocker, as resolved above. The Rogue PC/PD/PT format applies and there is no DART [j96-adt], [mainline].
6. **Display.**
   - The iPad uses simpledrm on the boot framebuffer (/vram at PA 0x87d0de000, 36 MiB [j96-adt]).
   - The GPU driver is render-only, so output must be copied into a simpledrm dumb buffer. wlroots multi-GPU / PRIME with CPU copy can do this (INFERRED). At 1536×2048×4 that is about 12.6 MB per full frame, roughly 750 MB/s at 60 fps on two cores, before simpledrm's own shadow copy (INFERRED arithmetic).
   - The proper fix is an ADBE KMS driver. The kernelcache has AppleH7ADBE0 / 'adbe0,t7000', and Orchard has an A9 ADBE driver; mainline drm/adp matches 'apple,h7-display-pipe' [orchard-patches]. disp0 is at 0x206200000 and dart-disp0 at 0x206304000/0x206300000, the same as T8010 [j96-adt], [orchard-patches]. This track is independent of the GPU work.
7. **Kernel config and DT.** Easy.
   - CONFIG_DRM_POWERVR=m; all its dependencies are met [mainline].
   - ps_gfx already exists at pmgr+0x20320 ([j96-adt] confirms the ADT GFX id 0x7c decodes to exactly this register).
   - The A8 variant needs a Kconfig option that does not depend on APPLE_RTKIT [orchard-patches].
   - A dummy fixed 'core' clock or the optional-clock change [mainline], [orchard-patches].

## 3. Staged milestones

Each milestone has a hardware-checkable "done" test. Effort assumes AI-assisted work at the A10 pace, where possible.

**M0 — Static RE, no hardware (1–2 days)**
- Disassemble AGXG4P locally:
  - the Fender power-up sequence (agxk_fender_meta.cpp, agfPollFenderReg/pollFenderReg)
  - the reg-index getters (which sgx reg is RGX and which is Fender)
  - the use of AICSWIntRegs
  - AGXMetaFirmware boot: LDR walk, CONFIG handling, the META address map 0x10000000 / 0x20000000 / 0x60000000 / 0xc0000000 / 0xe0000000, and the kick register
- Retry the userlandkernel tree API for a G4P driver kext.
- Done: a written register sequence for power-on and power-off, with kext offsets as evidence. No Apple data goes into any repo.

**M1 — Smallest safe probe: power the GFX domain and read IDs, read-only (half a day)**
- From m1n1 proxy or a tiny debug module:
  1. Set ps_gfx (pmgr+0x20320) on and poll its actual state.
  2. Read sgx reg[1] (0x201e00000) for Fender status.
  3. Read RGX_CR_CORE_ID (0x201000018), CORE_REVISION (0x201000020) and the 64-bit read at 0x20.
  4. Power off again.
- Do not touch RGX until Fender reports the core powered [a10-method]. If M0 says a Fender power request is needed, do only that write, mirroring iOS.
- Done: non-zero, non-0xdeadbeef CORE_ID and revision values that are stable across two cold boots, and ps_gfx back off afterwards. These give the BVNC and the cluster count (expect 4; INFERRED).
- Note: mainline's decode of these registers may produce a non-IMG BVNC, as the A10's 0x011b0602 does (13.10.6.2) [mainline]. Add the A8 value as EXPERIMENTAL.

**M2 — Ground truth on iPadOS (2–4 days, partly in parallel with M1)**
- On palera1n 15.8.3, capture:
  - one compiled compute shader and one fragment shader (AGXCompilerService / AGXMetalA8 output)
  - one compute submission and its ring contents
  - a Fender/RGX register snapshot
- Done: shader binaries checked against Mesa pco_isa.py. Either they parse as Rogue, or they show the Apple 0xc000 padding / 0x8000 end pattern [a10-method]. **This is the go/no-go for effort size.**

**M3 — META firmware boots (3–7 days)**
- DT node: 'apple,t7000-gpu' with reg 0x201000000 and 0x201e00000, AIC 134–138 and power-domains=<&ps_gfx>.
- Driver: an A8 pvr variant with static device info, using the mainline LDR loader to walk the runtime-extracted blob into firmware memory with Rogue MMU firmware mapping, then META boot.
- Done: the firmware's 'META FW started! (%s)' log, or a firmware-written alive stamp, readable from host memory. META thread T0/T1 status shows them running. A clean stop and power-off follows, and nothing hangs on rmmod.

**M4 — Firmware initialised and kernel-internal compute self-test (1–2 weeks)**
- Rebuild the G4P init data and the device-control and CL channels crash by crash, as on the A10.
- Done: a terminate-only CL job completes with a stamp or interrupt, then a captured or hand-built shader writes a marker value (the A10 analogue is 0x1357, exp 68 [a10-method]).

**M5 — UAPI compute via powervr ioctls (3–5 days)**
- Done: a userspace test submits compute through DRM_IOCTL_PVR_* and reads back results, with a bounded timeout and recovery.

**M6 — Render: TA/3D channels, parameter manager, free list (1–3 weeks)**
- Done: a first triangle rendered to a GEM buffer and dumped to a PNG that matches the expected output.

**M7 — Mesa: device info, ISA backend, Vulkan, Zink (2 weeks if the ISA is Rogue; 1–3 months if it is Apple)**
- Done: vkcube, then a GL client through Zink, shown via PRIME copy onto simpledrm.

**M8 — Display path and performance (1–3 weeks)**
- Work: an ADBE KMS driver for t7000; GPU DVFS through an OPP table (port m1n1 0011 or a static DT table built from the ADT's 365/450/550/600 MHz states [j96-adt]); memory and SoC perf-state checks [a10-method].
- Done: a compositor runs on KMS plus the GPU, with measured fps and CPU against pixman.

**Display track D0 (parallel, independent of the GPU)**
- Add a t7000 disp0/dart-disp0 node and test the A9 ADBE driver or drm/adp register offsets.
- Done: the KMS connector lists 1536×2048 and a page flip shows a test pattern.

## 4. What the user sees at each stage

- **M0–M6:** nothing on screen. The desktop stays labwc with pixman on simpledrm, unchanged. Progress shows only as dmesg, debugfs and dumped images.
- **M7:** Vulkan and GL demos (vkcube, glmark2 via Zink) run, probably below 60 fps and through an extra CPU copy. The labwc desktop is still not faster.
- **M8:** a GPU-composited desktop becomes possible. Even on the A10, Labwc on the GPU was slower than pixman: about 3× the CPU, about 240 MB more memory, and scroll p99 of 26 ms against 19 ms [a10-method]. On a 2 GB A8 that also has a copy to simpledrm, expect the same or worse until KMS and the Mesa bypasses are done. The real visible gain is effects (blur, Hyprland-style animation) and GL/Vulkan apps, not basic desktop speed.

## 5. Hardware risks and keeping each probe reversible

- **Power domains.**
  - Touch only ps_gfx and the Fender window.
  - Never write the AIC SW_SET/CLR words, PMGR perf-regs (pmgr+0x28000, SoC/CPU only [j96-adt]) or voltage tables.
  - Do not touch the unknown PMGR reg[12]/[13] windows at 0x201f00000 and 0x201f80000.
  - Access RGX only after Fender reports the core powered. An unpowered access can cause an SError or a bus hang; that is recoverable by reboot (INFERRED).
- **Voltage and thermal.**
  - Do not program GPU perf states above iOS values. The ceiling is 600 MHz at 950 mV [j96-adt].
  - Start at the lowest state.
  - Keep jobs short and bounded with timeouts.
  - The device has no fan. Watch the PMGR/SoC temperature sensors if they are exposed, or limit run length.
  - Device max power is 3348 per the ADT, units unknown.
- **Reversibility.**
  - Everything is a tethered RAM boot: no flash writes and no NAND or NVMe changes. A reboot via checkm8 restores state.
  - Build the GPU code as a module, with pm_runtime and power-off on remove.
  - M1 is read-only apart from the single power-on.
  - Keep the firmware blob in RAM or the initramfs, extracted at runtime.
- **Lock-ups.**
  - A META or GPU hang can wedge the bus. Use the polled timeouts as the A10 did ('5 s timeout recovery' [orchard-patches]).
  - Keep the NBD root mounted read-mostly during probes, so a hang does not corrupt the Omarchy image. INFERRED good practice.
- **Constraints for this session.** I did not touch the iPad in this pass. All hardware steps above are for the user to run.

## 6. Verdict

GPU acceleration on J96 is **feasible in principle but a substantially bigger project than the A10.**

**In its favour:**
- There is no IOP or RTKit layer.
- The firmware is a standard META LDR image that mainline already knows how to parse.
- The MMU is Rogue and 4K works.
- IRQs reach the AP.
- ps_gfx already exists.
- M1 and M3 are small and low-risk.

**Against it:**
- The G4P host ABI must be reverse-engineered from a stripped iOS 15 kext, without the symbolled kext the A10 had.
- The shader ISA is unknown, with no Metal toolchain target for it.
- Mesa 6XT support is weak, and Mesa upstream declines LLM-generated code.
- There is no KMS display driver yet.
- On the A10 the end result was still slower than pixman for plain desktop use.

**Timescale (INFERRED):**
- M1 (core ID read): days.
- M3/M4 (firmware up, compute marker): 2–4 weeks.
- First triangle: 1–2 months.
- Usable Vulkan/Zink: 2–3 months if the ISA is stock Rogue, otherwise 3–6+ months.
- A desktop that is faster than pixman: uncertain. It may never beat pixman for Labwc without the ADBE KMS driver and heavy Mesa tuning.

**Recommendation:**
1. Do M0 and M1 now; they are cheap and safe.
2. Do M2 (the ISA capture) before committing to anything past M4. It decides whether this is a months-scale or a half-year project.
3. Pursue display track D0 in parallel. It is independent of the GPU, removes the simpledrm copy, and helps whatever renderer ends up on top.

## Files

- Scratch area: /tmp/claude-1000/-home-tcballard-Projects/7aa9af37-4e91-48e5-a2e7-64bd8932ea91/scratchpad/gpu/
- Local META LDR loader: /home/tcballard/Projects/iomarchy-j96-tNPWSDe4/build/linux-src-touchbus/drivers/gpu/drm/imagination/pvr_fw_meta.c
- Local m1n1 patch sets (no sgx pstate patch in either): /home/tcballard/Projects/orchard-hardware/boot/m1n1/patches/j71b/ and /home/tcballard/Projects/orchard-omarchy-a/boot/m1n1/patches/j71b/
- Kernelcache: /home/tcballard/Projects/j96-touch-20261030/downloads/kernel/19H386__iPad5,1/kernelcache.release.iPad5,1_2
- ADT: /home/tcballard/Projects/j96-touch-20261030/private/j96-adt-20261030.bin