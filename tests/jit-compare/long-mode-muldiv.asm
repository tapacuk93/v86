; mul, imul, div and idiv - ops 4 to 7 of the 0xf6/0xf7 group. winload divides while working out
; an allocation size, and reaches it before it has an idt, so the #ud for the missing op was fatal.
;
; All four work on an operand twice the width of the one encoded: dx:ax, or just ax at byte width.
; The cases below cover a product that fills both halves, a signed product that does not, the
; 32-bit form's zero extension of *both* result registers, a dividend that genuinely needs 128
; bits, and a signed divide whose quotient truncates toward zero.
;
; The expected values come from running this same arithmetic on a real x86-64; see
; long-mode-muldiv-oracle.c. Only cf and of are compared, and only for the multiplies, since the
; divides define no flags at all.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    ; 1: mul, unsigned and wide enough to fill both halves
    mov rax, 0xdeadbeefcafebabe
    mov rbx, 0x0123456789abcdef
    mul rbx
    mov r8, rax
    mov r9, rdx
    pushfq
    pop rax
    and rax, 0x801
    mov r10, rax

    ; 2: imul with a negative operand, whose product still fits the low half sign extended
    mov rax, 0x123456789abcdef0
    mov rbx, -3
    imul rbx
    mov r11, rax
    mov r12, rdx
    pushfq
    pop rax
    and rax, 0x801
    mov r13, rax

    ; 3: the 32-bit form must zero extend both halves of the result, so rax and rdx start as all
    ; ones - a stale top half in either would show
    mov rax, -1
    mov rdx, -1
    mov rbx, 0xffffffff00001234
    mul ebx
    mov r14, rax
    mov r15, rdx

    ; 4: div of a dividend that genuinely needs 128 bits, 2^64 over 3
    mov rdx, 1
    mov rax, 0
    mov rbx, 3
    div rbx
    mov rbp, rax
    mov rsi, rdx

    ; 5: idiv with a negative dividend: the quotient truncates toward zero and the remainder takes
    ; the sign of the dividend
    mov rdx, -1
    mov rax, -100
    mov rbx, 7
    idiv rbx
    mov rdi, rax
    mov rcx, rdx

    hlt

%include "long-mode-epilogue.inc"
