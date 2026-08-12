; movss and movsd, the scalar half of the 0x10/0x11 pair. The f3 or f2 prefix narrows the memory
; access to 32 or 64 bits, where the same opcode without one moves the whole 128.
;
; The width of the store is the point. Windows fills one field of a structure with movsd and the
; field after it with an ordinary store, so a store that writes 128 bits lands on both and the
; second field is lost - silently, since the bytes past the destination are as writable as the
; ones asked for. Both cases here leave a known value in the bytes that must survive.
;
; The loads are the other half: a scalar load zeroes the rest of the register rather than merging
; into it, which is what separates movsd from movlps. The register form does merge, so it is here
; too - taking it for movups would carry the source's high half across.
;
; Expected values measured on a real x86-64; see long-mode-scalar-move-oracle.c.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x7000
    mov rdi, 0x7100             ; where results are stored to be read back

    mov rax, 0x1122334455667788
    movq xmm0, rax
    mov rax, 0xDEADBEEFDEADBEEF
    movq xmm1, rax
    movlhps xmm0, xmm1          ; xmm0 = deadbeefdeadbeef:1122334455667788

    ; movsd stores the low 64 bits and nothing else
    mov rax, 0xAAAAAAAAAAAAAAAA
    mov [rdi], rax
    mov [rdi + 8], rax          ; the qword that has to survive the store
    movsd [rdi], xmm0
    mov r8, [rdi]               ; -> 1122334455667788
    mov r9, [rdi + 8]           ; -> aaaaaaaaaaaaaaaa, not xmm0's high half

    ; movss stores 32 of them
    mov rax, 0xAAAAAAAAAAAAAAAA
    mov [rdi], rax
    movss [rdi], xmm0
    mov r10, [rdi]              ; -> aaaaaaaa55667788

    ; a scalar load zeroes what it does not fill
    mov rax, 0x0102030405060708
    mov [rdi + 0x20], rax
    mov rax, 0xFFFFFFFFFFFFFFFF
    movq xmm2, rax
    movlhps xmm2, xmm2          ; every bit set, so a merge would show
    movsd xmm2, [rdi + 0x20]
    movups [rdi + 0x40], xmm2
    mov r11, [rdi + 0x40]       ; -> 0102030405060708
    mov r12, [rdi + 0x48]       ; -> 0

    movq xmm3, rax
    movlhps xmm3, xmm3
    movss xmm3, [rdi + 0x20]
    movups [rdi + 0x40], xmm3
    mov r13, [rdi + 0x40]       ; -> 0000000005060708

    ; the register form merges rather than zeroing
    movq xmm4, rax
    movlhps xmm4, xmm4
    mov rax, 0x0102030405060708
    movq xmm5, rax              ; low half only, high half zero
    movsd xmm4, xmm5
    movups [rdi + 0x40], xmm4
    mov r14, [rdi + 0x40]       ; -> 0102030405060708
    mov r15, [rdi + 0x48]       ; -> ffffffffffffffff, kept rather than taken from xmm5

    hlt

%include "long-mode-epilogue.inc"
