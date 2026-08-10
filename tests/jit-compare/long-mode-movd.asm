; movd and movq between an xmm register and a general purpose one, plus the movlhps and 16-byte
; store beside them. Windows zeroes memory with exactly this group: a value goes into an xmm
; register, movlhps spreads it across both halves, and it is stored sixteen bytes at a time.
;
; rex.w is what widens 0f 6e and 0f 7e from movd to movq. The width cannot be taken from the
; operand size here, because the 0x66 on these is the mandatory prefix selecting the sse form
; rather than an operand size override - without rex.w the operand is 32 bits, not 16.
;
; Expected values measured on a real x86-64; see long-mode-movd-oracle.c.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x7000

    ; movq r64 -> xmm and back
    mov rdx, 0x0123456789abcdef
    movq xmm0, rdx
    movq rax, xmm0
    mov r8, rax                 ; -> 0123456789abcdef

    ; movd over a register that already holds something. The 32-bit form keeps the low four bytes
    ; and clears the rest of the xmm register rather than merging into it.
    mov rcx, 0xffffffffdeadbeef
    movq xmm1, rcx
    movd xmm1, ecx
    movq rax, xmm1
    mov r9, rax                 ; -> 00000000deadbeef

    ; movlhps and a sixteen byte store, the shape windows uses
    movq xmm2, rdx
    movlhps xmm2, xmm2
    movups [rsp], xmm2
    mov r10, [rsp]              ; -> 0123456789abcdef
    mov r11, [rsp + 8]          ; -> 0123456789abcdef, the half movlhps filled

    ; movd out of an xmm register writes 32 bits, so the top half of rax is cleared
    movd eax, xmm0
    mov r12, rax                ; -> 0000000089abcdef

    hlt

%include "long-mode-epilogue.inc"
