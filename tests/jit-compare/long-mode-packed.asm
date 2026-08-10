; The packed integer operations, which windows runs a block of while checking the image it has
; loaded. They all share one shape - a 128-bit source acting on an xmm register - and differ only
; in where the source comes from, so both forms are served by the same implementation.
;
; The memory form is the one that had to widen: delegating it to the 32-bit implementation would
; truncate a kernel address back below 4 GiB.
;
; The lane-wise wrap in the first case is what makes it a real check: a carry crossing from one
; dword into the next would still look like an addition.
;
; Expected values measured on a real x86-64; see long-mode-packed-oracle.c.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x7000
    mov rdi, 0x7100             ; where results are stored to be read back
    mov rsi, 0x7140             ; a 128-bit memory source

    mov rax, 0x00000002fffffffe
    movq xmm1, rax
    mov rax, 0x0000000500000003
    movq xmm6, rax
    movlhps xmm6, xmm6

    ; paddd: each dword lane adds on its own, so the low one wraps without carrying into the next
    paddd xmm1, xmm6
    movups [rdi], xmm1
    mov r8, [rdi]               ; -> 0000000700000001
    mov r9, [rdi + 8]           ; -> 0000000500000003

    ; pcmpgtd: signed, per dword lane
    mov rax, 0x00000002fffffffe
    movq xmm2, rax
    pcmpgtd xmm2, xmm6
    movups [rdi], xmm2
    mov r10, [rdi]              ; -> 0
    mov r11, [rdi + 8]          ; -> 0

    ; pand, the plainest of them
    mov rax, 0x00ff00ff00ff00ff
    movq xmm3, rax
    mov rax, 0x0f0f0f0f0f0f0f0f
    movq xmm4, rax
    pand xmm3, xmm4
    movups [rdi], xmm3
    mov r12, [rdi]              ; -> 000f000f000f000f
    mov r13, [rdi + 8]          ; -> 0

    ; the same operation with a memory source rather than a register
    mov rax, 0x1111111122222222
    mov [rsi], rax
    mov [rsi + 8], rax
    movq xmm5, rax
    movlhps xmm5, xmm5
    paddd xmm5, [rsi]
    movups [rdi], xmm5
    mov r14, [rdi]              ; -> 2222222244444444
    mov r15, [rdi + 8]          ; -> 2222222244444444

    hlt

%include "long-mode-epilogue.inc"
