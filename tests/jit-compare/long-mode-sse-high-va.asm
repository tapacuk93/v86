; sse loads and stores through a virtual address above 4 GiB.
;
; The 64-bit table delegated every sse move to its 32-bit implementation, which takes an i32
; address and refuses anything that does not fit. That was survivable while only a bootloader ran
; 64-bit code, but a kernel keeps its stack and its structures in the high half of the address
; space, so movdqa [rsp+8] alone would have been enough to break it.
;
; The moves are checked in both directions and at all three widths, since the store width is the
; part that fails silently: a store that writes sixteen bytes where eight were asked for overwrites
; whatever follows the destination, and the value it did write still looks right.
;
; The high page is mapped onto one the prologue's identity mapping also covers, so the same bytes
; can be reached both ways and the two views must agree.
;
; Tables above the three the prologue builds at 0x10000..0x13000:
;   0x13000  pdpt for the high address, entry 5
;   0x14000  page directory
;   0x15000  page table, pointing at physical 0x8000
%include "long-mode.inc"

HIGH_VA equ 0x8140000000

BITS 64
long_mode:
    mov rsp, 0x7000

    mov rdi, 0x10000 + 1 * 8                ; pml4[1] -> pdpt
    mov dword [rdi], 0x13000 | 3
    mov rdi, 0x13000 + 5 * 8                ; pdpt[5] -> pd
    mov dword [rdi], 0x14000 | 3
    mov rdi, 0x14000                        ; pd[0] -> pt
    mov dword [rdi], 0x15000 | 3
    mov rdi, 0x15000                        ; pt[0] -> physical 0x8000
    mov dword [rdi], 0x8000 | 3
    mov rax, cr3
    mov cr3, rax                            ; the tables were built with paging already on

    mov rbx, HIGH_VA
    mov rsi, 0x8000                         ; the same page, seen through the identity mapping

    ; a known sixteen bytes in xmm0
    mov rax, 0x0102030405060708
    mov [rsi], rax
    mov rax, 0x1112131415161718
    mov [rsi + 8], rax
    movdqa xmm0, [rsi]

    ; movdqa out through the high address, read back low
    mov rax, 0xEEEEEEEEEEEEEEEE
    mov [rsi], rax
    mov [rsi + 8], rax
    movdqa [rbx], xmm0
    mov r8, [rsi]                           ; -> 102030405060708
    mov r9, [rsi + 8]                       ; -> 1112131415161718

    ; and movdqu in through the high address
    pxor xmm1, xmm1
    movdqu xmm1, [rbx]
    movq r10, xmm1                          ; -> 102030405060708

    ; movq stores eight bytes through the high address and no more
    mov rax, 0xEEEEEEEEEEEEEEEE
    mov [rsi], rax
    mov [rsi + 8], rax
    movq [rbx], xmm0
    mov r11, [rsi]                          ; -> 102030405060708
    mov r12, [rsi + 8]                      ; -> eeeeeeeeeeeeeeee, untouched

    ; movhps takes the upper half, again eight bytes
    mov rax, 0xEEEEEEEEEEEEEEEE
    mov [rsi], rax
    movhps [rbx], xmm0
    mov r13, [rsi]                          ; -> 1112131415161718

    ; movss reaches four bytes through the high address
    mov rax, 0xEEEEEEEEEEEEEEEE
    mov [rsi], rax
    movss [rbx], xmm0
    mov r14, [rsi]                          ; -> eeeeeeee05060708

    ; and pxor reads a 128-bit source from it
    movdqa [rbx], xmm0
    movdqa xmm2, xmm0
    pxor xmm2, [rbx]                        ; a value xored with itself
    movq r15, xmm2                          ; -> 0

    hlt

%include "long-mode-epilogue.inc"
