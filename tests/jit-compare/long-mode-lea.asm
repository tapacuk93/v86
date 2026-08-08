; lea computes an address without touching memory, so it is not subject to the limit on addresses
; v86 can actually reach, and must not fault on one it could not.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    ; a small base and a larger negative displacement, which wraps below zero
    mov r8, 0x2e
    lea eax, [r8-0x41]              ; 0x2e - 0x41 = -0x13, at 32 bits -> 0xffffffed

    ; the same at 64 bits, where it stays negative
    lea rbx, [r8-0x41]              ; -> 0xffffffffffffffed

    ; and one that genuinely is above 4 GiB, which lea still computes happily
    mov r9, 0x100000000
    lea rcx, [r9+0x10]              ; -> 0x100000010

    ; rip relative, which is the other form only 64-bit mode has
    lea rdx, [rel marker]

    ; if lea had faulted, none of this would run
    mov r15, 0x1EA00000

    hlt
marker:

%include "long-mode-epilogue.inc"
