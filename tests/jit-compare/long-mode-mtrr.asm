; The memory type range registers.
;
; Nothing here interprets them - this emulator has no caches, so every memory type behaves the same
; - but a processor whose cpuid says mtrr exists must let a guest read and write them, and windows
; expects the feature on anything it will run on. So they are storage that reads back what was
; written, which is the whole of the contract a guest can observe.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; cpuid advertises it
    mov eax, 1
    cpuid
    mov r8, rdx
    shr r8, 12
    and r8, 1                               ; -> 1, mtrr

    ; mtrrcap: eight variable ranges, fixed ranges, write combining
    mov ecx, 0xFE
    rdmsr
    mov r9, rax                             ; -> 508

    ; a variable range register round trips at full width
    mov ecx, 0x200                          ; physbase0
    mov eax, 0x00000006                     ; write back
    mov edx, 0x0000000F
    wrmsr
    xor eax, eax
    xor edx, edx
    rdmsr
    shl rdx, 32
    or rax, rdx
    mov r10, rax                            ; -> f00000006

    ; and so does a fixed range one, which is a different slot
    mov ecx, 0x250                          ; fix64k_00000
    mov eax, 0x06060606
    mov edx, 0x06060606
    wrmsr
    xor eax, eax
    xor edx, edx
    rdmsr
    shl rdx, 32
    or rax, rdx
    mov r11, rax                            ; -> 606060606060606

    ; the default type register
    mov ecx, 0x2FF
    mov eax, 0xC00                          ; enabled, fixed enabled
    xor edx, edx
    wrmsr
    xor eax, eax
    rdmsr
    mov r12, rax                            ; -> c00

    ; and the last variable range, to show the whole block is addressed
    mov ecx, 0x20F                          ; physmask7
    mov eax, 0x87654321
    mov edx, 0x0000000F
    wrmsr
    xor eax, eax
    xor edx, edx
    rdmsr
    shl rdx, 32
    or rax, rdx
    mov r13, rax                            ; -> f87654321

    hlt

%include "long-mode-epilogue.inc"
