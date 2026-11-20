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
 *   x2  = page0 +0x04   x3  = page1 +0x04   x4  = page2 +0x04   (POST-GPC)
 *   x5  = page3 +0x04   x6  = page4 +0x04   x7  = page5 +0x04   (POST-GPC)
 *   x10 = page5 +0x00   x11 = page5 +0x08   x12 = page5 +0x18
 *   x13 = page5 +0x1c   x14 = page5 +0x20
 *   x15 = ps_gfx  (PMGR +0x20320)
 *   x16 = +0x1c200 (GFX perf-state control)
 *   x17 = +0x1c300
 *   x19 = +0x2300c
 *   x20 = first page-5 write offset (0 if none)   x21 = first write value
 *   x22..x27 = page0..page5 +0x04 at the CAPTURE hook (ps_gfx power-on, early),
 *              diffed against x2..x7 (post-GPC) to show when bit 30 comes up.
 *   x28 = number of page-5 writes seen (0 = page 5 is a hardware status, never
 *         written by any driver during the power-on)
 *   (x18 is skipped: it is the Darwin platform register and the panic dump
 *    does not show the zero-extended 32-bit value for it.)
 *   far      = 0xbeef  (dump captured)  /  0xdead  (capture hook never ran)
 *
 * The PMGR offsets below (region-0 base at pmgr+0xa70, the six clock pages,
 * ps_gfx, perf-state control, 0x2300c) are A8/T7000-specific. To port, see the
 * "PORTING CONFIG" block in j96_page5_capture.c.
 *
 * READ-ONLY: no MMIO store.
 */
    .text
    .p2align 2
    .globl _j96_page5_start, _j96_page5_end
    .globl _j96_page5_poll_capture, _j96_page5_read
    .globl _j96_page5_write_trace
    .globl _j96_page5_buffer

_j96_page5_start:

// --- capture hook (replaces `blr x8` of the ps poll) ------------------------
// At entry: x20 = PMGR object, x8 = poll fn ptr, x30 = the continuation.
_j96_page5_poll_capture:
    stp     x29, x30, [sp, #-16]!
    ldr     x16, _j96_page5_buffer
    str     x20, [x16]                  // buffer[0] = PMGR object
    // Early (power-gate) snapshot of the six clock pages' +0x04, so the
    // read-hook (post-GPC) value can be diffed against the ps_gfx-on value.
    ldr     x9, [x20, #0xa70]           // region-0 mapped base VA
    cbz     x9, Lcap_unmapped
    ldr     w10, [x9, #0x004]           // page0 +0x04
    ldr     w11, [x9, #0x1004]          // page1 +0x04
    ldr     w12, [x9, #0x2004]          // page2 +0x04
    ldr     w13, [x9, #0x3004]          // page3 +0x04
    add     x14, x9, #0x4, lsl #12
    ldr     w14, [x14, #0x004]          // page4 +0x04
    add     x15, x9, #0x5, lsl #12
    ldr     w15, [x15, #0x004]          // page5 +0x04
    stp     w10, w11, [x16, #8]         // buffer[1..2] = page0/1 +0x04
    stp     w12, w13, [x16, #16]        // buffer[3..4] = page2/3 +0x04
    stp     w14, w15, [x16, #24]        // buffer[5..6] = page4/5 +0x04
    b       Lcap_run
Lcap_unmapped:
    movz    w10, #0xdead
    movk    w10, #0xdead, lsl #16
    str     w10, [x16, #8]              // buffer[1] = sentinel (region not mapped)
Lcap_run:
    blr     x8                          // run the original poll
    ldp     x29, x30, [sp], #16
    ret

// --- write hook (replaces `str w21,[x8,w19,uxtw]` of the generic write) ------
// At entry: x8 = base VA, w19 = offset, w21 = value, x30 = the continuation.
// Records writes to the GPU-late PMGR regions only (page 5, the GFX perf table
// 0x1c000-0x1d000, and the perf-regs 0x28000-0x29000). It deliberately does NOT
// record the early-boot ps/clock writes, so the buffer is only touched late in
// boot (the all-region variant faulted writing the buffer too early).
_j96_page5_write_trace:
    ldr     x16, _j96_page5_buffer
    cmp     w19, #0x6000                 // clock pages 0-5 [0x0000, 0x6000)
    b.lo    Lwt_record
    cmp     w19, #0x1c000                // GFX perf table [0x1c000, 0x1d000)
    b.lo    Lwt_chk_preg
    cmp     w19, #0x1d000
    b.lo    Lwt_record
Lwt_chk_preg:
    cmp     w19, #0x28000                // perf-regs [0x28000, 0x29000)
    b.lo    Lwt_done
    cmp     w19, #0x29000
    b.hs    Lwt_done
Lwt_record:
    ldr     w10, [x16, #32]             // write count (word 8)
    cmp     w10, #256                   // cap at 256 entries
    b.hs    Lwt_done
    add     x11, x16, #40               // trace base (word 10)
    add     x11, x11, x10, lsl #3
    stp     w19, w21, [x11]             // record {offset, value}
    add     w10, w10, #1
    str     w10, [x16, #32]
Lwt_done:
    str     w21, [x8, w19, uxtw]        // the original write
    ret

// --- read hook (replaces `mov w0,#0xa` after the GPC busy poll) -------------
_j96_page5_read:
    ldr     x16, _j96_page5_buffer
    ldr     x0, [x16]                   // x0 = saved PMGR object
    ldr     w22, [x16, #8]              // capture-time page0 +0x04
    ldr     w23, [x16, #12]             // capture-time page1 +0x04
    ldr     w24, [x16, #16]             // capture-time page2 +0x04
    ldr     w25, [x16, #20]             // capture-time page3 +0x04
    ldr     w26, [x16, #24]             // capture-time page4 +0x04
    ldr     w27, [x16, #28]             // capture-time page5 +0x04
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

    // write trace: write count + the LAST recorded (offset, value) — the most
    // recent write, i.e. the clock-gate write during the power-on.
    // Reload the buffer pointer into x16 (x16 was clobbered by the +0x1c200 word).
    ldr     x16, _j96_page5_buffer
    ldr     w28, [x16, #32]             // write count
    cbz     w28, Lrd_nowr
    sub     w9, w28, #1                 // last index = count - 1
    add     x9, x16, x9, lsl #3         // x9 = x16 + (count-1)*8
    ldr     w20, [x9, #40]              // last write offset
    ldr     w21, [x9, #44]              // last write value
    b       Lrd_wr_done
Lrd_nowr:
    mov     w20, #0
    mov     w21, #0
Lrd_wr_done:

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
