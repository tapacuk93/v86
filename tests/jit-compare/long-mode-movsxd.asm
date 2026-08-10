; movsxd widens a 32-bit value to 64 bits with its sign, which is how 64-bit code turns a signed
; index or offset into a pointer, so it appears wherever an array is touched. Only the rex.w form
; is implemented; the narrower ones are discouraged and refused rather than guessed at.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    ; a negative value, which is the whole point: the top half must fill with ones
    mov eax, 0xffffffed
    movsxd rbx, eax                 ; -> 0xffffffffffffffed

    ; a positive one, where the top half must stay clear
    mov eax, 0x7ffffffe
    movsxd rcx, eax                 ; -> 0x000000007ffffffe

    ; exactly the sign bit, the boundary between the two
    mov eax, 0x80000000
    movsxd rdx, eax                 ; -> 0xffffffff80000000

    ; the destination must be written in full, not merged: rsi starts with every bit set, and a
    ; small positive source has to clear all of the top half
    mov rsi, -1
    mov eax, 1
    movsxd rsi, eax                 ; -> 0x0000000000000001

    ; from memory rather than a register, and through an extended register so rex.b is exercised
    ; alongside rex.w
    mov r8, 0x7000
    mov dword [r8], 0xfffffff0
    movsxd r9, dword [r8]           ; -> 0xfffffffffffffff0

    ; and an extended destination with an extended base, so rex.r and rex.b are both set
    mov dword [r8+4], 0x00000042
    movsxd r10, dword [r8+4]        ; -> 0x0000000000000042

    ; the source must be left alone
    mov r11, rax

    hlt

%include "long-mode-epilogue.inc"
