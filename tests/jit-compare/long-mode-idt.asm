; Take an exception in 64-bit mode and come back from it. The gate is sixteen bytes and the frame
; is five eight byte slots plus an error code, none of which the 32-bit path gets right.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    ; build an idt whose entry for #ud (vector 6) points at the handler below. Only that entry is
    ; ever used, so the rest is left as it is.
    mov rax, handler
    mov word [0x20000 + 6*16 + 0], ax           ; offset 15:0
    mov word [0x20000 + 6*16 + 2], 0x08         ; selector, the 64-bit code segment
    mov byte [0x20000 + 6*16 + 4], 0            ; ist 0
    mov byte [0x20000 + 6*16 + 5], 0x8E         ; present, dpl 0, interrupt gate
    shr rax, 16
    mov word [0x20000 + 6*16 + 6], ax           ; offset 31:16
    shr rax, 16
    mov dword [0x20000 + 6*16 + 8], eax         ; offset 63:32

    lidt [idtr64]

    mov r12, 0                                  ; set by the handler
    mov r13, 0                                  ; set after returning

    ud2                                         ; -> #ud, vector 6
after_fault:
    mov r13, 2
    hlt

handler:
    mov r12, 1
    ; the frame is rip, cs, rflags, rsp, ss - step rip past the two byte ud2 and return
    mov rax, [rsp]
    add rax, 2
    mov [rsp], rax
    o64 iret

align 8
idtr64:
    dw 256*16 - 1
    dq 0x20000

%include "long-mode-epilogue.inc"
