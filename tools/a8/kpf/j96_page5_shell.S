/*
 * J96 (iPad mini 4, A8/T7000, iPadOS 15.8.3 19H386) FULL-STATE dump probe.
 * Same two hooks as before, but the read hook now captures the six clock
 * pages (+0x00/+0x04/+0x08 each), ps_gfx, the GFX perf-state control words
 * and 0x2300c directly into x1..x28 and faults with far = 0xbeef.
 *
 * Direct MMIO read (no function call, so no register clobbering):
 *   region-0 mapped base VA is at [pmgr + 0xa70]  (regionmap(0,0)->+0x18).
 *
 * Register -> value map (read from the panic report's x0..x28):
 *   x1  = page0 +0x00   x2  = page0 +0x04   x3  = page0 +0x08
 *   x4  = page1 +0x00   x5  = page1 +0x04   x6  = page1 +0x08
 *   x7  = page2 +0x00   x10 = page2 +0x04   x11 = page2 +0x08
 *   x12 = page3 +0x00   x13 = page3 +0x04   x14 = page3 +0x08
 *   x15 = page4 +0x00   x16 = page4 +0x04   x17 = page4 +0x08
 *   x19 = page5 +0x00   x20 = page5 +0x04   x21 = page5 +0x08
 *   x22 = page5 +0x18   x23 = page5 +0x1c   x24 = page5 +0x20
 *   x25 = ps_gfx  (PMGR +0x20320)
 *   x26 = +0x1c200 (GFX perf-state control)
 *   x27 = +0x1c300
 *   x28 = +0x2300c
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

    // page 0 = base + 0x0000
    mov     x8, x9
    ldr     w1,  [x8, #0x00]
    ldr     w2,  [x8, #0x04]
    ldr     w3,  [x8, #0x08]

    // page 1 = base + 0x1000
    add     x8, x9, #0x1, lsl #12
    ldr     w4,  [x8, #0x00]
    ldr     w5,  [x8, #0x04]
    ldr     w6,  [x8, #0x08]

    // page 2 = base + 0x2000
    add     x8, x9, #0x2, lsl #12
    ldr     w7,  [x8, #0x00]
    ldr     w10, [x8, #0x04]
    ldr     w11, [x8, #0x08]

    // page 3 = base + 0x3000
    add     x8, x9, #0x3, lsl #12
    ldr     w12, [x8, #0x00]
    ldr     w13, [x8, #0x04]
    ldr     w14, [x8, #0x08]

    // page 4 = base + 0x4000
    add     x8, x9, #0x4, lsl #12
    ldr     w15, [x8, #0x00]
    ldr     w16, [x8, #0x04]
    ldr     w17, [x8, #0x08]

    // page 5 = base + 0x5000
    add     x8, x9, #0x5, lsl #12
    ldr     w19, [x8, #0x00]
    ldr     w20, [x8, #0x04]
    ldr     w21, [x8, #0x08]
    ldr     w22, [x8, #0x18]
    ldr     w23, [x8, #0x1c]
    ldr     w24, [x8, #0x20]

    // ps_gfx = base + 0x20320
    add     x8, x9, #0x20, lsl #12
    ldr     w25, [x8, #0x320]

    // GFX perf-state control = base + 0x1c200, +0x1c300
    add     x8, x9, #0x1c, lsl #12
    ldr     w26, [x8, #0x200]
    ldr     w27, [x8, #0x300]

    // 0x2300c
    add     x8, x9, #0x23, lsl #12
    ldr     w28, [x8, #0xc]

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
