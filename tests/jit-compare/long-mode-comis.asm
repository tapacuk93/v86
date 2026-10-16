; The scalar floating point compares, which are how compiled code branches on a float.
;
; comiss/comisd and ucomiss/ucomisd compare one scalar against another and write the answer into
; the arithmetic flags rather than a register: equal sets zf, less sets cf, greater sets neither,
; and a nan sets all three of zf, pf and cf at once. Every `if(x < y)` in compiled floating point
; code is one of these followed by a conditional jump, so a guest that reaches any floating point
; at all reaches them immediately.
;
; The 66 prefix here selects double rather than single, which means the memory operand is 32 bits
; wide without it and 64 with it - neither of which is the 128-bit shape the rest of the sse
; memory forms have. That is what made these the last four missing in 64-bit mode: windows runs
; several minutes of kernel code before anything executes one.
;
; The flags are read back masked to zf|pf|cf, which is 0x45, since the compares leave of, sf and
; af clear and nothing else here disturbs them.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    mov eax, 0x40000000                     ; 2.0f
    movd xmm0, eax
    mov eax, 0x3F800000                     ; 1.0f
    movd xmm1, eax
    mov eax, 0x7FC00000                     ; a quiet nan
    movd xmm2, eax

    mov rax, 0x4000000000000000             ; 2.0
    movq xmm3, rax
    mov rax, 0x3FF0000000000000             ; 1.0
    mov [0x30008], rax
    mov dword [0x30000], 0x3F800000         ; 1.0f, for the 32-bit memory form

    ; ucomiss, register, greater: no flag at all
    ucomiss xmm0, xmm1
    pushfq
    pop rax
    and rax, 0x45
    mov r8, rax                             ; -> 0

    ; ucomiss, register, less: carry
    ucomiss xmm1, xmm0
    pushfq
    pop rax
    and rax, 0x45
    mov r9, rax                             ; -> 1

    ; ucomiss, register, equal: zero
    ucomiss xmm0, xmm0
    pushfq
    pop rax
    and rax, 0x45
    mov r10, rax                            ; -> 0x40

    ; ucomiss, 32 bits out of memory, greater
    ucomiss xmm0, [0x30000]
    pushfq
    pop rax
    and rax, 0x45
    mov r11, rax                            ; -> 0

    ; ucomiss against a nan: unordered, which is all three at once
    ucomiss xmm0, xmm2
    pushfq
    pop rax
    and rax, 0x45
    mov r12, rax                            ; -> 0x45

    ; ucomisd, 64 bits out of memory, greater
    ucomisd xmm3, [0x30008]
    pushfq
    pop rax
    and rax, 0x45
    mov r13, rax                            ; -> 0

    ; comisd, register, equal
    comisd xmm3, xmm3
    pushfq
    pop rax
    and rax, 0x45
    mov r14, rax                            ; -> 0x40

    ; comiss, register, less
    comiss xmm1, xmm0
    pushfq
    pop rax
    and rax, 0x45
    mov r15, rax                            ; -> 1

    hlt

%include "long-mode-epilogue.inc"
