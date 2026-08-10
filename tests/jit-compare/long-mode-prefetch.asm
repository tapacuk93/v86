; The prefetch hints and the reserved nops beside them.
;
; They do nothing, so what matters is only that their operand is consumed: an operand carrying a
; sib byte and a displacement leaves four bytes behind, and decoding that continues inside them
; produces nonsense rather than a wrong answer. So the check is that the instruction after each one
; still does what it says.
;
; The operand is resolved but never accessed - prefetching an address that is not mapped is defined
; not to fault - which is why one of these points somewhere deliberately unmapped.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x7000

    mov rcx, 0x6000
    mov rdx, 0x10
    xor r8, r8

    prefetchnta [rcx + rdx + 0x40]
    inc r8                      ; -> 1, so the sib byte and displacement were consumed
    prefetcht0 [rcx + rdx + 0x40]
    inc r8                      ; -> 2
    prefetcht1 [rcx]
    inc r8                      ; -> 3

    ; an address with nothing mapped behind it, which must still not fault
    mov rax, 0x00000000deadb000
    prefetchnta [rax]
    inc r8                      ; -> 4

    mov r9, 0x600d              ; -> reached

    hlt

%include "long-mode-epilogue.inc"
