; The shift-by-immediate group on an xmm register: psrldq, pslldq and psrlq.
;
; psrldq and pslldq shift the whole 128-bit register by whole bytes, so they move data between the
; two halves; psrlq shifts each 64-bit half on its own and does not. Only the register form of this
; group exists.
;
; Expected values measured on a real x86-64; see long-mode-psrldq-oracle.c.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x7000
    mov rdi, 0x7100

    mov rax, 0x0123456789abcdef

    ; psrldq by eight brings the high half down and clears the high half
    movq xmm2, rax
    movlhps xmm2, xmm2
    psrldq xmm2, 8
    movups [rdi], xmm2
    mov r8, [rdi]               ; -> 0123456789abcdef
    mov r9, [rdi + 8]           ; -> 0

    ; pslldq by four moves bytes up across the halves
    movq xmm3, rax
    movlhps xmm3, xmm3
    pslldq xmm3, 4
    movups [rdi], xmm3
    mov r10, [rdi]              ; -> 89abcdef00000000
    mov r11, [rdi + 8]          ; -> 89abcdef01234567

    ; psrlq shifts each half on its own, by bits rather than bytes
    movq xmm4, rax
    psrlq xmm4, 8
    movups [rdi], xmm4
    mov r12, [rdi]              ; -> 000123456789abcd
    mov r13, [rdi + 8]          ; -> 0

    hlt

%include "long-mode-epilogue.inc"
