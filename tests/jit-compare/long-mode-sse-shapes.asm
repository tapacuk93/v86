; The sse shapes that do not fit the 128-bit source table: the stores, the ones carrying an
; immediate, and the ones whose destination is a general purpose register.
;
; These are what an sse2 memcpy, memset and string search are built out of, so a 64-bit guest
; reaches them almost immediately - and each was missing from the 64-bit table, where a missing
; opcode is a panic rather than a fault.
;
; The store widths are the part worth checking. movq writes eight bytes and movntdq sixteen; a movq
; that stored the whole register would silently overwrite whatever follows the destination, which
; is invisible in the value it did write.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    mov rdi, 0x7100
    mov rax, 0x0102030405060708
    mov [rdi], rax
    mov rax, 0x1112131415161718
    mov [rdi + 8], rax
    movdqa xmm0, [rdi]

    ; pshufd with 0x1b reverses the four dwords; the immediate follows the modrm, so a rip
    ; relative operand would have to count past it
    pshufd xmm1, xmm0, 0x1B
    movq r8, xmm1                           ; -> 1516171811121314

    ; movq stores eight bytes and leaves the eight after them alone
    mov rsi, 0x7200
    mov rax, 0xEEEEEEEEEEEEEEEE
    mov [rsi], rax
    mov [rsi + 8], rax
    movq [rsi], xmm0
    mov r9, [rsi]                           ; -> 102030405060708
    mov r10, [rsi + 8]                      ; -> eeeeeeeeeeeeeeee, untouched

    ; movntdq stores all sixteen
    mov rax, 0xEEEEEEEEEEEEEEEE
    mov [rsi], rax
    mov [rsi + 8], rax
    movntdq [rsi], xmm0
    mov r11, [rsi + 8]                      ; -> 1112131415161718

    ; the mask instructions, whose destination is a general purpose register
    mov rax, 0x8080808080808080
    mov [rdi], rax
    mov [rdi + 8], rax
    movdqa xmm2, [rdi]
    pmovmskb r12d, xmm2                     ; -> ffff, sixteen sign bits
    movmskps r13d, xmm2                     ; -> f, four
    movmskpd r14d, xmm2                     ; -> 3, two

    hlt

%include "long-mode-epilogue.inc"
