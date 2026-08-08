; bit test group. Carry takes the bit as it was, and the index is taken modulo the operand size.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    mov rax, 0x0000000000000100      ; bit 8 set
    bt  rax, 8
    setc bl                          ; expect 1
    bt  rax, 9
    setc bh                          ; expect 0

    mov rcx, 0
    bts rcx, 63                      ; -> 0x8000000000000000, carry 0
    setc dl                          ; expect 0

    mov rsi, 0xFFFFFFFFFFFFFFFF
    btr rsi, 4                       ; -> 0xffffffffffffffef, carry 1
    setc dil                         ; expect 1

    mov r8, 0x1234
    btc r8, 2                        ; toggles bit 2: 0x1234 ^ 4 = 0x1230
    setc r9b                         ; expect 1, bit 2 of 0x1234 is set

    ; the index is taken modulo the operand size, so 64 means bit 0
    mov r10, 1
    bt  r10, 64
    setc r11b                        ; expect 1

    ; and the register index form
    mov r12, 0x8000
    mov r13, 15
    bt  r12, r13
    setc r14b                        ; expect 1

    hlt

%include "long-mode-epilogue.inc"
