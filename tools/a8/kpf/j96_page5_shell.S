/*
 * J96 (iPad mini 4, A8/T7000, iPadOS 15.8.3 19H386) FULL-STATE dump probe.
 * Same two hooks as the single-word probe, but the read hook now captures 19
 * PMGR words directly into x10..x28 and faults with far = 0xbeef.
 *
 * Direct MMIO read (no function call, so no register clobbering):
 *   region-0 mapped base VA is at [pmgr + 0xa70]  (regionmap(0,0)->+0x18).
 *
 * Register -> value map (read from the panic report's x0..x28):
 *   x10..x25 = PMGR clock page 5, words +0x00..+0x3c   (the GFX PLL page)
 *   x26      = PMGR +0x1c200  (GFX perf-state control)
 *   x27      = PMGR +0x1c300
 *   x28      = PMGR +0x2300c
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
    ldr     x19, [x16]                  // x19 = saved PMGR object
    cbz     x19, Lnot_captured
    ldr     x9, [x19, #0xa70]           // x9 = region-0 mapped base VA

    // clock page 5 = base + 0x5000  (16 words -> x10..x25)
    add     x8, x9, #0x5, lsl #12
    ldr     w10, [x8, #0x00]
    ldr     w11, [x8, #0x04]
    ldr     w12, [x8, #0x08]
    ldr     w13, [x8, #0x0c]
    ldr     w14, [x8, #0x10]
    ldr     w15, [x8, #0x14]
    ldr     w16, [x8, #0x18]
    ldr     w17, [x8, #0x1c]
    ldr     w18, [x8, #0x20]
    ldr     w19, [x8, #0x24]
    ldr     w20, [x8, #0x28]
    ldr     w21, [x8, #0x2c]
    ldr     w22, [x8, #0x30]
    ldr     w23, [x8, #0x34]
    ldr     w24, [x8, #0x38]
    ldr     w25, [x8, #0x3c]

    // GFX perf-state control: base + 0x1c200 (x26), + 0x1c300 (x27)
    add     x8, x9, #0x1c, lsl #12
    ldr     w26, [x8, #0x200]
    ldr     w27, [x8, #0x300]

    // 0x2300c -> x28
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
