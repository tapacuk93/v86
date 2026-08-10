; cdqe widens eax into rax with its sign, and cqo spreads rax's sign across the whole of rdx,
; which is what has to happen before a signed 64-bit divide. Both are the 64-bit spellings of
; opcodes that mean something narrower below long mode, so the operand size decides which.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    ; cdqe on a negative value: the top half fills with ones
    mov rax, 0x1111111180000001
    cdqe                            ; rax -> 0xffffffff80000001
    mov rbx, rax

    ; and on a positive one, where the stale top half must be cleared rather than kept
    mov rax, 0x111111117fffffff
    cdqe                            ; rax -> 0x000000007fffffff
    mov rcx, rax

    ; cqo with a negative rax fills rdx entirely
    mov rax, -2
    mov rdx, 0x1234567812345678     ; must be overwritten, not merged
    cqo                             ; rdx -> 0xffffffffffffffff
    mov rsi, rdx
    mov rdi, rax                    ; cqo leaves rax alone

    ; cqo with a positive rax clears rdx entirely
    mov rax, 0x7fffffffffffffff
    mov rdx, -1
    cqo                             ; rdx -> 0x0000000000000000
    mov r8, rdx

    ; the boundary: bit 63 set is negative, bit 62 set is not
    mov rax, 0x8000000000000000
    cqo
    mov r9, rdx                     ; -> all ones

    mov rax, 0x4000000000000000
    cqo
    mov r10, rdx                    ; -> zero

    ; the 32-bit form still means cdq: edx takes eax's sign and the top half is cleared
    mov rdx, -1
    mov rax, 0xffffffff80000000
    cdq                             ; edx -> 0xffffffff, zero extended into rdx
    mov r11, rdx

    hlt

%include "long-mode-epilogue.inc"
