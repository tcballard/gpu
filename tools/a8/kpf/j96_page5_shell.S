/*
 * J96 (iPad mini 4, A8/T7000, iPadOS 15.8.3 19H386) full-state dump probe.
 * Same two hooks as before, but the read hook captures the six clock pages'
 * +0x04 (running-status) words, ps_gfx, the GFX perf-state control words,
 * 0x2300c and the page-5 words that differ from Linux, into x2..x21 and
 * faults with far = 0xbeef.
 *
 * Direct MMIO read (no function call, so no register clobbering):
 *   region-0 mapped base VA is at [pmgr + 0xa70]  (regionmap(0,0)->+0x18).
 *
 * Register -> value map (read from the panic report's x0..x28):
 *   x2  = page0 +0x04   x3  = page1 +0x04   x4  = page2 +0x04
 *   x5  = page3 +0x04   x6  = page4 +0x04   x7  = page5 +0x04
 *   x10 = page5 +0x00   x11 = page5 +0x08   x12 = page5 +0x18
 *   x13 = page5 +0x1c   x14 = page5 +0x20
 *   x15 = ps_gfx  (PMGR +0x20320)
 *   x16 = +0x1c200 (GFX perf-state control)
 *   x17 = +0x1c300
 *   x19 = +0x2300c
 *   x20 = page0 +0x00   x21 = page0 +0x08
 *   (x18 is skipped: it is the Darwin platform register and the panic dump
 *    does not show the zero-extended 32-bit value for it.)
 *   far      = 0xbeef  (dump captured)  /  0xdead  (capture hook never ran)
 *
 * READ-ONLY: no MMIO store.
 */
    .text
    .p2align 2
    .globl _j96_page5_start, _j96_page5_end
    .globl _j96_page5_poll_capture, _j96_page5_read
    .globl _j96_page5_buffer

_j96_page5_start:

// --- capture hook (replaces `blr x8` of the ps poll) ------------------------
// At entry: x20 = PMGR object, x8 = poll fn ptr, x30 = the continuation.
_j96_page5_poll_capture:
    stp     x29, x30, [sp, #-16]!
    ldr     x16, _j96_page5_buffer
    str     x20, [x16]                  // buffer[0] = PMGR object
    blr     x8                          // run the original poll
    ldp     x29, x30, [sp], #16
    ret

// --- read hook (replaces `mov w0,#0xa` after the GPC busy poll) -------------
_j96_page5_read:
    ldr     x16, _j96_page5_buffer
    ldr     x0, [x16]                   // x0 = saved PMGR object
    cbz     x0, Lnot_captured
    ldr     x9, [x0, #0xa70]            // x9 = region-0 mapped base VA

    // six clock pages' +0x04 (running status); pages 0-3 via x9 directly
    ldr     w2,  [x9, #0x004]           // page0 +0x04
    ldr     w3,  [x9, #0x1004]          // page1 +0x04
    ldr     w4,  [x9, #0x2004]          // page2 +0x04
    ldr     w5,  [x9, #0x3004]          // page3 +0x04
    add     x8, x9, #0x4, lsl #12       // page4 base
    ldr     w6,  [x8, #0x04]            // page4 +0x04
    add     x8, x9, #0x5, lsl #12       // page5 base
    ldr     w7,  [x8, #0x04]            // page5 +0x04

    // page-5 words that differ from Linux
    ldr     w10, [x8, #0x00]            // page5 +0x00
    ldr     w11, [x8, #0x08]            // page5 +0x08
    ldr     w12, [x8, #0x18]            // page5 +0x18
    ldr     w13, [x8, #0x1c]            // page5 +0x1c
    ldr     w14, [x8, #0x20]            // page5 +0x20

    // ps_gfx = base + 0x20320
    add     x8, x9, #0x20, lsl #12
    ldr     w15, [x8, #0x320]

    // GFX perf-state control = base + 0x1c200, +0x1c300
    add     x8, x9, #0x1c, lsl #12
    ldr     w16, [x8, #0x200]
    ldr     w17, [x8, #0x300]

    // 0x2300c
    add     x8, x9, #0x23, lsl #12
    ldr     w19, [x8, #0xc]

    // page0 +0x00, +0x08 (config context)
    ldr     w20, [x9, #0x00]
    ldr     w21, [x9, #0x08]

    movz    x0, #0xbeef                 // magic: dump captured
    ldr     x1, [x0]                    // data abort -> far = 0xbeef
    brk     #0

Lnot_captured:
    movz    x0, #0xdead                 // magic: capture hook never ran
    ldr     x1, [x0]                    // data abort -> far = 0xdead
    brk     #0

    .p2align 3
_j96_page5_buffer:
    .quad   0                            // filled by emit() = kernel VA of buffer

_j96_page5_end:
