; bt, bts, btr and btc on memory with the index in a register.
;
; This is a different instruction from its register form in all but name. The index is a signed
; integer indexing a bit array that begins at the operand, so it reaches outside the operand in
; either direction, and what is accessed is the byte the index lands in rather than the operand
; itself. The register form, by contrast, takes the index modulo the operand size.
;
; It is what a 64-bit Windows bootloader tests its bitmaps with, and it was the first instruction
; the boot reached that this fork did not have.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; a bit array at 0x7100: byte 0 = 0x00, byte 1 = 0x01, byte 2 = 0x00, byte 8 = 0x80
    mov rdi, 0x7100
    xor rax, rax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov byte [rdi + 1], 0x01                ; bit 8 of the array
    mov byte [rdi + 8], 0x80                ; bit 71

    ; bit 8 is set
    mov rcx, 8
    bt [rdi], rcx
    setc r8b
    movzx r8, r8b                           ; -> 1

    ; bit 9 is not
    mov rcx, 9
    bt [rdi], rcx
    setc r9b
    movzx r9, r9b                           ; -> 0

    ; bit 71 is, and it is well outside the eight bytes at the operand
    mov rcx, 71
    bt [rdi], rcx
    setc r10b
    movzx r10, r10b                         ; -> 1

    ; a negative index reaches below the operand: bit -8 is byte -1, which holds 0
    mov byte [rdi - 1], 0x02                ; bit -7
    mov rcx, -7
    bt [rdi], rcx
    setc r11b
    movzx r11, r11b                         ; -> 1

    ; bts sets a bit and reports what it was
    mov rcx, 16
    bts [rdi], rcx
    setc r12b
    movzx r12, r12b                         ; -> 0, it was clear
    movzx r13, byte [rdi + 2]               ; -> 1, and it is set now

    ; btr clears one, btc flips one
    mov rcx, 8
    btr [rdi], rcx
    movzx r14, byte [rdi + 1]               ; -> 0

    mov rcx, 71
    btc [rdi], rcx
    movzx r15, byte [rdi + 8]               ; -> 0, 0x80 flipped off

    hlt

%include "long-mode-epilogue.inc"
