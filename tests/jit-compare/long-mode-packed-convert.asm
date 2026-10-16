; The packed conversions between integers and floats, the duplicating move, and pinsrw.
;
; Their mandatory prefix is not 0x66, which is what kept them out of the table the rest of the
; 128-bit family goes through - that one is keyed by opcode alone, so it can only hold one form of
; each. cvtdq2ps has no prefix, cvttps2dq takes f3, cvtpd2dq takes f2, and cvtdq2pd takes f3 while
; reading only 64 bits. pinsrw is unlike all of them: its source is a general purpose register or
; 16 bits of memory rather than an xmm register.
;
; The two directions do not round the same way. cvttps2dq truncates, as its extra t says; cvtpd2dq
; rounds the way mxcsr asks, which by default is to nearest.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; cvtdq2ps: four integers to four singles
    mov rax, 0x0000000200000001
    mov [0x30000], rax
    mov rax, 0x0000000400000003
    mov [0x30008], rax                      ; 1 2 3 4
    movdqa xmm0, [0x30000]
    cvtdq2ps xmm0, xmm0
    movdqa [0x30010], xmm0
    mov r8, [0x30010]                       ; -> 1.0f 2.0f

    ; cvttps2dq: four singles truncated towards zero, which is what the extra t means
    mov rax, 0x402000003FC00000             ; 1.5f 2.5f
    mov [0x30020], rax
    mov rax, 0xC0200000BFC00000             ; -1.5f -2.5f
    mov [0x30028], rax
    movdqa xmm1, [0x30020]
    cvttps2dq xmm1, xmm1
    movdqa [0x30030], xmm1
    mov r9, [0x30030]                       ; -> 1 2
    mov r10, [0x30038]                      ; -> -1 -2

    ; cvtdq2pd: the low two integers only, widened to two doubles
    movdqa xmm2, [0x30000]
    cvtdq2pd xmm2, xmm2
    movdqa [0x30040], xmm2
    mov r11, [0x30040]                      ; -> 1.0
    mov r12, [0x30048]                      ; -> 2.0

    ; cvtpd2dq: two doubles to two integers in the low half
    mov rax, 0x4000000000000000             ; 2.0
    mov [0x30050], rax
    mov rax, 0x4008000000000000             ; 3.0
    mov [0x30058], rax
    movdqa xmm3, [0x30050]
    cvtpd2dq xmm3, xmm3
    movdqa [0x30060], xmm3
    mov r13, [0x30060]                      ; -> 2 3

    ; movddup: the low double copied into both halves
    movddup xmm4, qword [0x30050]
    movdqa [0x30070], xmm4
    mov r14, [0x30078]                      ; -> 2.0, in the half it was not read from

    ; pinsrw: one 16-bit value into the lane the immediate names
    pxor xmm5, xmm5
    mov eax, 0xBEEF
    pinsrw xmm5, eax, 2
    movdqa [0x30080], xmm5
    mov r15, [0x30080]                      ; -> 0xbeef in the third word

    hlt

%include "long-mode-epilogue.inc"
