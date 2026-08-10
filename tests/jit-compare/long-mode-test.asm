; test against an immediate in the accumulator, which is the shortest way to ask about a bit and so
; is everywhere in compiled code. Only flags come out of it, so each case is turned into a byte
; with setcc; the registers are cleared first because setcc writes only the low one.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    xor r12d, r12d
    xor r13d, r13d
    xor r14d, r14d
    xor r15d, r15d

    ; the byte form: al is 0xff, so bit 7 is set and the result is negative but not zero
    mov rax, 0xff
    test al, 0x80
    setz r8b                        ; -> 0
    sets r9b                        ; -> 1

    ; nothing in common, so the result is zero
    test al, 0x00
    setz r10b                       ; -> 1

    ; the wide form with rex.w, where the immediate is sign extended to all ones and the result is
    ; rax itself: not zero, and not negative since bit 63 is clear
    mov rax, 0x123456789abcdef0
    test rax, -1
    setz r11b                       ; -> 0
    sets r12b                       ; -> 0

    ; the same but with bit 63 set, which is the only bit the sign of a 64-bit test depends on
    mov rax, 0x8000000000000000
    test rax, -1
    sets r13b                       ; -> 1

    ; at a 32-bit operand size the sign comes from bit 31, not bit 63
    mov rax, 0x00000000ffffffff
    test eax, 0x80000000
    sets r14b                       ; -> 1
    setz r15b                       ; -> 0

    ; and the accumulator itself must be untouched by any of it
    mov rbx, rax

    hlt

%include "long-mode-epilogue.inc"
