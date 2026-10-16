; The sse operations that take an immediate, and the shift-by-immediate groups.
;
; shufps picks four lanes by a byte of selectors, two from each register; cmpps and cmpss name the
; comparison the same way and answer in lanes of all ones or all zeros rather than in flags;
; unpcklps interleaves the low halves and reads only 64 bits of its source. The three shift groups
; (0f 71, 72 and 73) are one opcode each with the operation in the modrm's middle field and the
; count in an immediate, and only their register forms exist.
;
; All of them turn up in optimised string and memory routines, which is why user mode reaches them
; as soon as it runs anything at all. The immediate comes after the operand, so it has to be read
; last whatever the operand turned out to be - reading it first gives every one of these the wrong
; count and the wrong lanes.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    mov rax, 0x0000000200000001
    mov [0x30000], rax
    mov rax, 0x0000000400000003
    mov [0x30008], rax                      ; 1 2 3 4, as dwords
    mov rax, 0x0000000600000005
    mov [0x30010], rax
    mov rax, 0x0000000800000007
    mov [0x30018], rax                      ; 5 6 7 8

    ; shufps takes lanes 2 and 3 of the destination and lanes 0 and 1 of the source
    movdqa xmm0, [0x30000]
    movdqa xmm1, [0x30010]
    shufps xmm0, xmm1, 0x4E
    movdqa [0x30020], xmm0
    mov r8, [0x30020]                       ; -> 3 4
    mov r9, [0x30028]                       ; -> 5 6

    ; unpcklps interleaves the low halves of the two
    movdqa xmm2, [0x30000]
    movdqa xmm3, [0x30010]
    unpcklps xmm2, xmm3
    movdqa [0x30030], xmm2
    mov r10, [0x30030]                      ; -> 1 5
    mov r11, [0x30038]                      ; -> 2 6

    ; cmpps against itself: every lane equal, so every lane all ones
    mov rax, 0x3F8000003F800000             ; 1.0f, twice
    mov [0x30040], rax
    mov [0x30048], rax
    movdqa xmm4, [0x30040]
    cmpeqps xmm4, [0x30040]
    movdqa [0x30050], xmm4
    mov r12, [0x30050]                      ; -> all ones

    ; cmpss, which answers in the low lane only and leaves the rest of the register alone
    mov dword [0x30060], 0x40000000         ; 2.0f
    movdqa xmm5, [0x30040]
    cmpltss xmm5, dword [0x30060]
    movd r13d, xmm5                         ; -> all ones: 1.0 < 2.0

    ; psllw, the 0f 71 group: each word shifted left by four
    mov rax, 0x0001000100010001
    mov [0x30070], rax
    mov [0x30078], rax
    movdqa xmm6, [0x30070]
    psllw xmm6, 4
    movdqa [0x30080], xmm6
    mov r14, [0x30080]                      ; -> 0x10 in each word

    ; psrld, the 0f 72 group: each dword shifted right by two
    mov rax, 0x0000001000000010
    mov [0x30090], rax
    mov [0x30098], rax
    movdqa xmm7, [0x30090]
    psrld xmm7, 2
    movdqa [0x300A0], xmm7
    mov r15, [0x300A0]                      ; -> 4 in each dword

    hlt

%include "long-mode-epilogue.inc"
