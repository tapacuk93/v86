; A byte alu operation that reads and writes the same memory operand, where the operand carries a
; sib byte and a displacement.
;
; The address has to be kept from the read and reused for the write. Resolving the modrm a second
; time re-reads the sib byte and the displacement from the instruction stream, consuming them
; twice - so decoding carries on two bytes into the *next* instruction and everything after that
; is garbage. It is not a wrong result, it is a wrong instruction boundary, which is why the check
; that matters here is that the following instruction still does what it says.
;
; Windows hits this in a byte-at-a-time xor loop, where the desync landed on a displacement that
; made an address of -125.
%include "long-mode.inc"

BUF equ 0x6000

BITS 64
long_mode:
    mov rsp, 0x7000

    mov rdi, BUF
    mov byte [rdi + 2], 0x55

    mov rbp, BUF + 0x20
    mov rcx, 2

    ; op r/m8, r8 - the register form of the group
    mov al, 0x3c
    xor byte [rbp + rcx - 0x20], al
    inc rcx                     ; only lands here if the operand was consumed exactly once
    mov r8, rcx                 ; -> 3
    movzx r9d, byte [rdi + 2]   ; -> 69, which is 55 xor 3c

    ; and the immediate form, opcode 0x80, with the same addressing
    mov rcx, 2
    xor byte [rbp + rcx - 0x20], 0x0f
    inc rcx
    mov r10, rcx                ; -> 3
    movzx r11d, byte [rdi + 2]  ; -> 66, which is 69 xor 0f

    hlt

%include "long-mode-epilogue.inc"
