; popcnt in 64-bit mode.
;
; v86's cpuid advertises popcnt, so a guest is entitled to use it, but the 64-bit table did not have
; it - a feature bit promising an instruction that panics the emulator when executed.
;
; The flags are the unusual part: zf says whether the source was zero, and every other arithmetic
; flag is cleared regardless of the count.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    mov rax, 0xFFFFFFFFFFFFFFFF
    popcnt r8, rax                          ; -> 40, all sixty-four bits

    mov rax, 0x1122334455667788
    popcnt r9, rax                          ; -> 1a

    ; the 32-bit form counts only the low half and zero extends the result
    mov rax, 0xFFFFFFFF0000000F
    popcnt r10d, eax
    mov r10, r10                            ; -> 4

    ; a source of zero sets zf, which is the only flag popcnt ever sets
    xor rax, rax
    stc                                     ; carry set beforehand, to see it cleared
    popcnt r11, rax                         ; -> 0
    setz r12b
    movzx r12, r12b                         ; -> 1
    setc r13b
    movzx r13, r13b                         ; -> 0, popcnt cleared it

    ; and a non-zero source clears zf
    mov rax, 1
    popcnt r14, rax                         ; -> 1
    setnz r15b
    movzx r15, r15b                         ; -> 1

    hlt

%include "long-mode-epilogue.inc"
