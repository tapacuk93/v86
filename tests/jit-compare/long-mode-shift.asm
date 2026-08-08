; Shifts in 64-bit mode. Expected values worked out from the instruction set.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    ; shl: carry is the last bit shifted out
    mov rax, 0x4000000000000000
    shl rax, 1                  ; -> 0x8000000000000000, cf = 0, of = 1 (sign changed)
    setc bl
    seto bh

    ; shl again: now the set bit falls out
    mov rcx, 0x8000000000000000
    shl rcx, 1                  ; -> 0, cf = 1, of = 1
    setc dl
    seto dh

    ; shr is logical, so the sign bit does not propagate
    mov rsi, 0x8000000000000001
    shr rsi, 1                  ; -> 0x4000000000000000, cf = 1
    setc r8b

    ; sar is arithmetic, so it does
    mov rdi, 0x8000000000000001
    sar rdi, 1                  ; -> 0xC000000000000000, cf = 1
    setc r9b

    ; a 32-bit shift zero extends into the full register
    mov r10, 0x1122334455667788
    shl r10d, 4                 ; -> 0x0000000056677880

    ; count is masked to 6 bits at 64, so 64 means no shift and no flag change
    mov r11, 0x1234
    shl r11, 64                 ; -> unchanged

    hlt

%include "long-mode-epilogue.inc"
