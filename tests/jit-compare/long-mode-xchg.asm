; xchg swaps its two operands, so it both reads and writes the r/m one. With a memory operand the
; modrm has to be resolved once and reused, since resolving it twice would eat the displacement
; twice; a wrong displacement is what this would look like if that went wrong.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    ; register with register, at the full width
    mov rax, 0x1111111122222222
    mov rbx, 0x3333333344444444
    xchg rax, rbx                   ; rax -> 0x3333333344444444, rbx -> 0x1111111122222222

    ; register with memory, through an extended base and a displacement, which is the case that
    ; goes wrong if the modrm is resolved twice
    mov r8, 0x7000
    mov r13, 0xdeadbeefcafebabe
    mov qword [r8+0x18], r13        ; a 64-bit immediate will not fit in a store, so via a register
    mov rcx, 0x0123456789abcdef
    xchg rcx, [r8+0x18]             ; rcx -> 0xdeadbeefcafebabe
    mov rdx, [r8+0x18]              ; -> 0x0123456789abcdef, the old rcx

    ; at a 32-bit operand size the register half is written whole, so the top of rsi is cleared
    mov rsi, -1
    mov r9d, 0x55667788
    xchg esi, r9d                   ; rsi -> 0x0000000055667788
    mov r10, r9                     ; r9 -> 0x00000000ffffffff, also written whole

    ; the byte form, and with rex present so that sil is the low byte of rsi rather than ah
    mov rsi, 0x00000000556677aa
    mov r11, 0x00000000000000bb
    xchg sil, r11b                  ; sil -> 0xbb, r11b -> 0xaa
    mov r12, rsi                    ; -> 0x00000000556677bb
    mov r14, r11                    ; -> 0x00000000000000aa

    hlt

%include "long-mode-epilogue.inc"
