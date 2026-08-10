; The string instructions in 64-bit mode: movs, stos and scas, with and without a rep prefix.
;
; Simpler here than at 16 or 32 bits - the address size is 64 and every segment base is zero, so
; rsi and rdi are the addresses - but the parts that are easy to get wrong are the same: df picks
; the direction, repne stops on zf rather than only on the count, and rcx is left saying where it
; stopped.
;
; Windows clears kernel structures with rep stos through addresses well above 4 GiB, which is how
; winload reaches these.
;
; Buffer at 0x6000, below the stack and inside the prologue's identity mapping. Expected values
; measured on a real x86-64; see long-mode-string-oracle.c.
%include "long-mode.inc"

BUF equ 0x6000

BITS 64
long_mode:
    mov rsp, 0x7000
    cld

    ; rep stosb over sixteen bytes
    mov rdi, BUF
    mov rcx, 16
    mov al, 0xab
    rep stosb
    mov rsi, BUF
    mov r8, [rsi]               ; -> abababababababab
    mov r9, rdi                 ; -> 6010, advanced by the count
    mov r10, rcx                ; -> 0, drained

    ; rep movsq, copying those bytes up to 0x6020
    mov rsi, BUF
    mov rdi, BUF + 32
    mov rcx, 2
    rep movsq
    mov rsi, BUF + 32
    mov r11, [rsi]              ; -> abababababababab

    ; repne scasb for a byte that is not there, so the count runs out
    mov rdi, BUF
    mov rcx, 16
    mov al, 0x99
    repne scasb
    mov r12, rcx                ; -> 0
    pushfq
    pop rax
    and rax, 0x40               ; zf
    mov r13, rax                ; -> 0, never matched

    ; and one that is there, on the very first byte, so it stops immediately
    mov rdi, BUF
    mov rcx, 16
    mov al, 0xab
    repne scasb
    mov r14, rcx                ; -> f, stopped with fifteen left

    ; df set, so stos walks backwards
    std
    mov rdi, BUF + 48
    mov rcx, 4
    mov al, 0x77
    rep stosb
    cld
    mov r15, rdi                ; -> 602c, four bytes below where it started
    mov rsi, BUF + 40
    mov rbp, [rsi]              ; -> 777777ababababab, the three it reached in this qword

    hlt

%include "long-mode-epilogue.inc"
