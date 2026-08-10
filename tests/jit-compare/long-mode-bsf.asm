; bsf and bsr, the index of the lowest or highest set bit.
;
; A source of zero has no index at all, so zf says so and the destination keeps whatever it already
; held - the interesting case, since writing a zero there would look almost right.
;
; Expected values measured on a real x86-64; see long-mode-bsf-oracle.c.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x7000

    mov rbx, 0x0000100000000100
    mov rax, 0xdead
    bsf rax, rbx
    mov r8, rax                 ; -> 8, the lowest set bit

    mov rax, 0xdead
    bsr rax, rbx
    mov r9, rax                 ; -> 2c, the highest

    ; a zero source: the destination is left exactly as it was
    xor rbx, rbx
    mov rax, 0x1234567812345678
    bsf rax, rbx
    mov r10, rax                ; -> 1234567812345678, untouched
    pushfq
    pop rcx
    and rcx, 0x40
    mov r11, rcx                ; -> 40, zf set to say there was no bit

    ; the 32-bit form zero extends its result like any other 32-bit write
    mov rbx, 0x00080000
    mov rax, -1
    bsf eax, ebx
    mov r12, rax                ; -> 13, with the top half cleared

    hlt

%include "long-mode-epilogue.inc"
