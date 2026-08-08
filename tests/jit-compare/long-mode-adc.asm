; adc and sbb, whose carry in is what makes them different from add and sub, and the byte forms.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    ; a 128-bit add built out of add + adc, which only works if the carry propagates
    mov rax, 0xFFFFFFFFFFFFFFFF
    mov rbx, 1
    add rax, rbx                ; -> 0, carry out
    mov rcx, 0
    adc rcx, 0                  ; -> 1, the carry came in

    ; sbb with a borrow
    mov rdx, 0
    mov rsi, 1
    sub rdx, rsi                ; -> -1, borrow out
    mov rdi, 5
    sbb rdi, 0                  ; -> 4, the borrow came in

    ; adc with no carry in leaves the value alone
    mov r8, 0x100
    add r8, 0                   ; clears carry
    mov r9, 7
    adc r9, 0                   ; -> 7

    ; byte forms: add al, imm8 wrapping at 8 bits, upper bits of rax untouched
    mov r10, 0x11223344556677FF
    mov rax, r10
    add al, 2                   ; 0xff + 2 = 0x01 -> rax = 0x1122334455667701
    setc r11b                   ; carry out of the byte

    hlt

%include "long-mode-epilogue.inc"
