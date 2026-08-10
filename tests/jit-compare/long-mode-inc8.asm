; inc and dec on a byte operand, the 0xfe group. The wider forms live in 0xff alongside the near
; call, jump and push; at byte width only these two exist.
;
; What is worth measuring is that they leave carry alone - they are add and sub that do not touch
; it - and that they wrap within the byte without disturbing the rest of the register.
;
; Expected values measured on a real x86-64; see long-mode-inc8-oracle.c.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x7000

    ; inc across the top of the byte, with carry set beforehand so its survival shows
    mov rax, 0x11223344556677ff
    stc
    inc al
    mov r8, rax                 ; -> 1122334455667700, only the low byte wrapped
    pushfq
    pop rcx
    and rcx, 0x8d5
    mov r9, rcx                 ; -> 55, carry still set alongside zf, pf and af

    ; dec across zero, with carry clear
    mov rax, 0x1122334455667700
    clc
    dec al
    mov r10, rax                ; -> 11223344556677ff
    pushfq
    pop rcx
    and rcx, 0x8d5
    mov r11, rcx                ; -> 94, carry still clear

    hlt

%include "long-mode-epilogue.inc"
