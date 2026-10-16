; The scalar floating point arithmetic: add, subtract, multiply, divide, square root, min and the
; single/double conversion, each acting on one number rather than four.
;
; The f3 or f2 prefix is what makes them scalar, and it also sets the width of the memory operand:
; 32 bits for a single, 64 for a double, where the packed form beside them reads 128. That matters
; beyond speed - reading 128 bits where the guest asked for 32 touches memory it never named, and
; faults when the operand ends a page. It also decides what the rest of the destination register
; keeps: a scalar operation leaves the upper part exactly as it was.
;
; All of compiled floating point arithmetic is these instructions, so a guest reaches them as soon
; as it runs any user mode code that does arithmetic at all.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    mov eax, 0x40000000                     ; 2.0f
    movd xmm1, eax
    mov dword [0x30000], 0x40000000         ; and the same in memory

    ; addss, register operand: 8 + 2
    mov eax, 0x41000000                     ; 8.0f
    movd xmm2, eax
    addss xmm2, xmm1
    movd r8d, xmm2                          ; -> 10.0f

    ; subss, 32 bits out of memory: 8 - 2
    mov eax, 0x41000000
    movd xmm2, eax
    subss xmm2, dword [0x30000]
    movd r9d, xmm2                          ; -> 6.0f

    ; mulss: 8 * 2
    mov eax, 0x41000000
    movd xmm2, eax
    mulss xmm2, xmm1
    movd r10d, xmm2                         ; -> 16.0f

    ; divss: 8 / 2
    mov eax, 0x41000000
    movd xmm2, eax
    divss xmm2, xmm1
    movd r11d, xmm2                         ; -> 4.0f

    ; sqrtss of 16
    mov eax, 0x41800000                     ; 16.0f
    movd xmm2, eax
    sqrtss xmm2, xmm2
    movd r12d, xmm2                         ; -> 4.0f

    ; minss of 8 and 2
    mov eax, 0x41000000
    movd xmm2, eax
    minss xmm2, xmm1
    movd r13d, xmm2                         ; -> 2.0f

    ; cvtss2sd, which widens the low single into the low double
    cvtss2sd xmm3, xmm1
    movq r14, xmm3                          ; -> 2.0

    ; addsd, 64 bits out of memory: 8 + 2 at double width
    mov rax, 0x4020000000000000             ; 8.0
    movq xmm4, rax
    mov rax, 0x4000000000000000             ; 2.0
    mov [0x30008], rax
    addsd xmm4, qword [0x30008]
    movq r15, xmm4                          ; -> 10.0

    hlt

%include "long-mode-epilogue.inc"
