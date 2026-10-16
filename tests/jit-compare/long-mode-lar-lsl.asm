; lar and lsl: read a descriptor's access rights, or its limit, without loading it.
;
; Both are allowed to unprivileged code, and zf is the answer to whether the selector named
; anything readable at all - when it did not, the destination is left exactly as it was, which is
; the part easy to get wrong when the implementation returns a value either way.
;
; Windows reaches lsl from user mode early: ntdll reads the current processor number out of a
; descriptor's limit, which is how it knew which cpu it was on before rdpid existed. The selector
; operand is 16 bits whatever the operand size, and the operand size is the destination's - so
; rex.w gives a 64-bit destination holding a zero extended 32-bit limit.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; a descriptor with a byte granular limit
    mov bx, 0x18
    xor rax, rax
    lsl eax, bx
    setz r11b
    mov r8, rax                             ; -> 0xabcd, the limit as written
    movzx r11, r11b                         ; -> 1, the selector was readable

    ; and one with a page granular limit, which lsl reports in bytes
    mov bx, 0x20
    xor rax, rax
    lsl eax, bx
    mov r9, rax                             ; -> 0x1fff

    ; lar on the same descriptor returns its access rights, masked to the bytes that hold them
    mov bx, 0x18
    xor rax, rax
    lar eax, bx
    mov r10, rax                            ; -> 0x9200

    ; a null selector names nothing: zf clear, and the destination untouched
    mov rax, 0xDEAD
    mov bx, 0
    lsl eax, bx
    setz r13b
    mov r12, rax                            ; -> 0xdead, exactly as it was
    movzx r13, r13b                         ; -> 0

    ; rex.w makes the destination 64 bits, and the 32-bit limit zero extends into it
    mov bx, 0x18
    mov rax, -1
    lsl rax, bx
    mov r14, rax                            ; -> 0xabcd, the upper half cleared

    hlt

align 8
gdt:
    dq 0                                    ; 0x00 null
    dq 0x00209A0000000000                   ; 0x08 64-bit code, dpl 0
    dq 0x0000920000000000                   ; 0x10 data, dpl 0
    dq 0x000092000000ABCD                   ; 0x18 data, limit 0xabcd, byte granular
    dq 0x0080920000000001                   ; 0x20 data, limit 1 page, granularity bit set
gdt_end:
gdtr:
    dw gdt_end - gdt - 1
    dd gdt
