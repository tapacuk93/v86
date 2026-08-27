; in and out in 64-bit mode.
;
; These were missing from the 64-bit table entirely, which a kernel does not survive: every legacy
; device - the interrupt controller, the timer, the cmos, the disk - is reached this way. rex.w
; means nothing to them, so the width comes from the opcode and the 0x66 prefix alone, and there is
; no 64-bit form.
;
; The 8-bit round trip goes through the interrupt controller's mask register, which reads back what
; was written. The wider ones read a port nothing is attached to, which answers all ones - enough to
; show the operand size reached the right handler, which is the part that could be wrong.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; out imm8 / in imm8, through the master pic's interrupt mask
    mov al, 0xA5
    out 0x21, al
    xor eax, eax
    in al, 0x21
    mov r8, rax                             ; -> a5

    ; the same port through dx rather than an immediate, with a different value
    mov dx, 0x21
    mov al, 0x5A
    out dx, al
    mov rax, 0xFFFFFFFFFFFFFF00             ; the narrow read must leave the rest of rax alone
    in al, dx
    mov r9, rax                             ; -> ffffffffffffff5a

    ; 16 bits, from a port nothing is attached to
    mov dx, 0x1234
    mov rax, 0xFFFFFFFFFFFF0000
    in ax, dx
    mov r10, rax                            ; -> ffffffffffffffff

    ; 32 bits, which zero extends into rax the way every 32-bit write in 64-bit mode does
    mov rax, 0x1111111111111111
    in eax, dx
    mov r11, rax                            ; -> ffffffff

    ; and the out side at each width, which has nowhere to be observed but must not fault
    mov eax, 0x12345678
    out dx, eax
    out dx, ax
    out dx, al
    mov r12, 1                              ; -> 1, reached the end

    hlt

%include "long-mode-epilogue.inc"
