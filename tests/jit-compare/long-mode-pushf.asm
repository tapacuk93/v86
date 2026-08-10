; pushfq and popfq, which is how anything that must not disturb the caller's flags saves them. The
; image is eight bytes wide here. Flags are only observable through what they do, so the cases are
; turned into bytes with setcc, and the stack pointer is checked directly.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    xor r12d, r12d
    xor r13d, r13d
    xor r14d, r14d
    xor r15d, r15d

    ; pushfq must move the stack pointer by eight, not four
    mov rbx, rsp
    pushfq
    mov rcx, rsp
    sub rbx, rcx                    ; -> 8
    popfq

    ; a flag set before the push must come back after a pop, even though it was cleared between
    xor eax, eax                    ; zf = 1
    pushfq
    mov rax, 1
    test rax, rax                   ; zf = 0 now
    setz r12b                       ; -> 0, confirming it really was cleared
    popfq
    setz r13b                       ; -> 1, restored from the stack

    ; and the other way round: a clear flag must stay clear across the round trip
    mov rax, 1
    test rax, rax                   ; zf = 0
    pushfq
    xor eax, eax                    ; zf = 1
    popfq
    setz r14b                       ; -> 0

    ; the value pushed is readable as ordinary memory, and bit 1 of rflags always reads as one
    pushfq
    pop rdx
    and rdx, 2
    mov r15, rdx                    ; -> 2

    ; the stack pointer must be back where it started after all of that
    mov rsi, rsp                    ; -> 0x8000

    hlt

%include "long-mode-epilogue.inc"
