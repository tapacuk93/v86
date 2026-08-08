; Operand sizes in 64-bit mode. The expected values are worked out from the instruction set rather
; than from what v86 happens to do, and are asserted by the runner.
;
; The point is that the three widths differ in two ways at once: how many bytes the immediate
; occupies, and what happens to the rest of the destination register.

%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    ; 16-bit: immediate is two bytes, and bits above 15 are left alone
    mov rax, 0x1122334455667788
    and ax, 0x0FFF                          ; 0x7788 & 0x0fff = 0x0788
                                            ; expect rax = 0x1122334455660788

    ; 32-bit: immediate is four bytes, and the write zero extends into the full register
    mov rbx, 0x1122334455667788
    and ebx, 0x0FFFFFFF                     ; 0x55667788 & 0x0fffffff = 0x05667788
                                            ; expect rbx = 0x0000000005667788

    ; 64-bit: immediate is four bytes, sign extended
    mov rcx, 0x1122334455667788
    and rcx, -0x10000                       ; expect rcx = 0x1122334455660000

    ; 16-bit add, to check the carry does not leak upwards
    mov rdx, 0x112233445566FFFF
    add dx, 1                               ; expect rdx = 0x1122334455660000

    ; 32-bit add, zero extending
    mov rsi, 0x11223344FFFFFFFF
    add esi, 1                              ; expect rsi = 0x0000000000000000

    hlt

%include "long-mode-epilogue.inc"
