; xadd puts the sum in the destination and the destination's old value in the register, which is
; how an interlocked increment finds out what it incremented past. Getting the two the wrong way
; round still writes plausible numbers to plausible places, so both are checked.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000
    mov r8, 0x7000

    xor r15d, r15d

    ; register with register
    mov rax, 100
    mov rbx, 7
    xadd rax, rbx                   ; rax -> 107, rbx -> 100
    mov rcx, rax                    ; -> 107, the sum
    mov rdx, rbx                    ; -> 100, what the destination held

    ; memory with a displacement, the case a second modrm resolve would get wrong
    mov r9, 40
    mov qword [r8+0x28], r9
    mov rsi, 2
    xadd [r8+0x28], rsi             ; memory -> 42, rsi -> 40
    mov rdi, [r8+0x28]              ; -> 42
    mov r10, rsi                    ; -> 40

    ; the flags are an ordinary add's, so a carry out is reported
    mov rax, -1
    mov rbx, 1
    xadd rax, rbx                   ; -1 + 1 wraps to 0 with a carry
    setc r15b                       ; -> 1
    mov r11, rax                    ; -> 0

    ; at a 32-bit operand size both operands are written whole, so a dirty top half has to be
    ; cleared on each: they are loaded 64 bits wide first so that there is something to clear
    mov r13, 0xffffffff00000005
    mov r14, 0xffffffff00000006
    xadd r13d, r14d                 ; r13 -> 0xb, r14 -> 0x5, both with the top half cleared

    hlt

%include "long-mode-epilogue.inc"
