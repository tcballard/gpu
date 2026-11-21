/*
 * J96 (iPad mini 4, A8/T7000, iPadOS 15.8.3 19H386) perf-write trace probe.
 * Three hooks: the ps-poll capture saves the PMGR object, the generic write
 * hook records the GFX perf-table/control and perf-regs writes (the PLL
 * configuration), and the read hook dumps the first 11 of those writes plus
 * the count, then faults with far = 0xbeef.
 *
 * Direct MMIO read (no function call, so no register clobbering):
 *   region-0 mapped base VA is at [pmgr + 0xa70]  (regionmap(0,0)->+0x18).
 *
 * Register -> value map (read from the panic report's x0..x28):
 *   x28 = perf write count
 *   first five writes:
 *     x2/x3   = w[0] {offset,value}     x4/x5   = w[1]
 *     x6/x7   = w[2]                    x10/x11 = w[3]
 *     x12/x13 = w[4]
 *   last six writes (newest first):
 *     x14/x15 = last     (count-1)      x16/x17 = count-2
 *     x19/x20 = count-3                 x21/x22 = count-4
 *     x23/x24 = count-5                 x25/x26 = count-6
 *   (x18 is skipped: it is the Darwin platform register and the panic dump
 *    does not show the zero-extended 32-bit value for it.)
 *   far      = 0xbeef  (dump captured)  /  0xdead  (capture hook never ran)
 *
 * The PMGR perf offsets (region-0 base at pmgr+0xa70) are A8/T7000-specific.
 * To port, see the "PORTING CONFIG" block in j96_page5_capture.c.
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
// Records the GFX perf-table/control [0x1c000,0x1d000) and perf-regs
// [0x28000,0x29000) writes (the PLL configuration) sequentially, cap 256:
//   buffer[32] = count, buffer[40 + 8*i] = {offset,value} of write i.
_j96_page5_write_trace:
    ldr     x16, _j96_page5_buffer
    cmp     w19, #0x1c000                // perf table/control [0x1c000, 0x1d000)
    b.lo    Lwt_done
    cmp     w19, #0x1d000
    b.lo    Lwt_record
    cmp     w19, #0x28000                // perf-regs [0x28000, 0x29000)
    b.lo    Lwt_done
    cmp     w19, #0x29000
    b.hs    Lwt_done
Lwt_record:
    ldr     w10, [x16, #32]             // write count
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
    cbz     x0, Lnot_captured
    ldr     x9, _j96_page5_buffer       // x9 = buffer pointer (stable base)

    // write trace: perf write count + first 5 + last 6 recorded {offset,value}.
    ldr     w28, [x9, #32]              // write count
    // first five writes
    ldr     w2,  [x9, #40]              // w[0].offset
    ldr     w3,  [x9, #44]              // w[0].value
    ldr     w4,  [x9, #48]              // w[1].offset
    ldr     w5,  [x9, #52]              // w[1].value
    ldr     w6,  [x9, #56]              // w[2].offset
    ldr     w7,  [x9, #60]              // w[2].value
    ldr     w10, [x9, #64]              // w[3].offset
    ldr     w11, [x9, #68]              // w[3].value
    ldr     w12, [x9, #72]              // w[4].offset
    ldr     w13, [x9, #76]              // w[4].value
    // last six writes: entry i is at buffer[40 + 8*i]; last is at 32 + 8*count.
    lsl     x8, x28, #3                 // 8*count
    add     x8, x8, #32                 // + 32
    add     x8, x9, x8                  // x8 = &entry[count-1]
    ldp     w14, w15, [x8]              // last     {offset,value} (count-1)
    ldp     w16, w17, [x8, #-8]!        // 2nd-last (count-2)
    ldp     w19, w20, [x8, #-8]!        // 3rd-last (count-3)
    ldp     w21, w22, [x8, #-8]!        // 4th-last (count-4)
    ldp     w23, w24, [x8, #-8]!        // 5th-last (count-5)
    ldp     w25, w26, [x8, #-8]!        // 6th-last (count-6)

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
