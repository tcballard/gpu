/*
 * J96 (iPad mini 4, A8/T7000, iPadOS 15.8.3 19H386) page-5 +0x4 capture.
 * Two-hook, read-only shellcode (J81 page5writer approach — no ml_io_map).
 *
 *   capture  replaces `blr x8` at unslid 0xfffffff0066e4294 (the PMGR ps-poll
 *            call in ApplePMGR's ps-register set). x20 = the PMGR object (this);
 *            it is stored into a buffer, then the original poll runs.
 *   read     replaces `mov w0,#0xa` at unslid 0xfffffff006695a44 (AGXG4P
 *            post-GPC-poll, before IODelay). It loads the saved PMGR object and
 *            calls [pmgr]->vt[0x980](pmgr, region=0, offset=0x5004, die=0),
 *            then deliberately faults so x0/far carry the page-5 +0x4 word.
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
    blr     x8                          // run the original poll (x0 = result)
    ldp     x29, x30, [sp], #16
    ret

// --- read hook (replaces `mov w0,#0xa` after the GPC busy poll) -------------
_j96_page5_read:
    ldr     x16, _j96_page5_buffer
    ldr     x16, [x16]                  // x16 = saved PMGR object
    cbz     x16, 1f                     // never captured -> sentinel fault
    ldr     x8, [x16]                   // vtable
    ldr     x8, [x8, #0x980]            // read(region, offset, die) slot
    mov     x0, x16                     // this = PMGR object
    mov     x1, #0                      // region 0
    mov     w2, #0x5004                 // offset (clock page 5, word +4)
    mov     x3, #0                      // die 0
    blr     x8                          // x0 = page 5 +0x4
    b       2f
1:
    movz    x0, #0xdead                 // sentinel: capture never ran
2:
    ldr     x1, [x0]                    // deliberate data abort: far = x0
    brk     #0                          // unreachable fallback

    .p2align 3
_j96_page5_buffer:
    .quad   0                            // filled by emit() = kernel VA of buffer

_j96_page5_end:
