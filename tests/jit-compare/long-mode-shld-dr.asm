; shld and shrd, the debug registers, push/pop of fs and gs, and movnti.
;
; All of these were missing from the 64-bit tables, and an opcode that is missing there is a panic
; rather than a fault - so the first one a kernel reaches ends the run. Windows clears dr7 as it
; starts, builds 64-bit shifts out of shld and shrd, and fills large structures with movnti.
;
; The expected values follow from the definitions: shld fills the vacated low bits from the source's
; high end, shrd the vacated high bits from the source's low end, and the 32-bit form zero extends
; into the full register the way every 32-bit write in 64-bit mode does.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; shld: rax left by 8, the low 8 bits filled from the top of rbx
    mov rax, 0x1122334455667788
    mov rbx, 0xAABBCCDDEEFF0011
    shld rax, rbx, 8
    mov r8, rax                             ; -> 22334455667788aa

    ; shrd: rax right by 8, the high 8 bits filled from the bottom of rbx
    mov rax, 0x1122334455667788
    mov rbx, 0xAABBCCDDEEFF0011
    shrd rax, rbx, 8
    mov r9, rax                             ; -> 1111223344556677

    ; the 32-bit form, whose result zero extends into the whole register, with the count in cl
    mov rax, 0xFFFFFFFF11223344
    mov ebx, 0xAABBCCDD
    mov cl, 8
    shld eax, ebx, cl
    mov r11, rax                            ; -> 223344aa

    ; movnti, a store that asks not to be cached; there is no cache here to bypass
    mov rax, 0x0123456789ABCDEF
    mov rdi, 0x7300
    movnti [rdi], rax
    mov r10, [rdi]                          ; -> 123456789abcdef

    ; dr7, whose bit 10 always reads set
    mov rax, 0x400
    mov dr7, rax
    xor rax, rax
    mov rax, dr7
    mov r12, rax                            ; -> 400

    ; and a breakpoint address register, which holds what it is given
    mov rax, 0x12345678
    mov dr0, rax
    xor rax, rax
    mov rax, dr0
    mov r13, rax                            ; -> 12345678

    ; push and pop of the two segments long mode keeps; the stack slot is eight bytes either way
    mov ax, 0x10
    mov fs, ax
    push fs
    pop r14                                 ; -> 10

    push qword 0x10
    pop gs
    xor rax, rax
    mov ax, gs
    mov r15, rax                            ; -> 10

    hlt

%include "long-mode-epilogue.inc"
