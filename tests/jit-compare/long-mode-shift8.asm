; The byte forms of the shifts: by one, by an immediate and by cl. Only the low byte of the
; destination may change, and the count is masked by 31 the same as at the wider sizes. The
; registers are loaded 64 bits wide so that a shift touching more than a byte is visible.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000
    mov r8, 0x7000

    xor r12d, r12d
    xor r13d, r13d
    xor r14d, r14d
    xor r15d, r15d

    ; shl by one, with the bit that leaves the top reported in carry
    mov rax, 0xaaaaaaaaaaaaaa81
    shl al, 1                       ; 0x81 -> 0x02, carry from bit 7
    setc r13b                       ; -> 1
    mov rbx, rax                    ; -> 0xaaaaaaaaaaaaaa02, the rest untouched

    ; shr is logical, so the byte is zero extended and not sign extended before shifting: a value
    ; whose bit 7 is set must bring in a zero, not a one
    mov rax, 0xffffffffffffff81
    shr al, 1                       ; 0x81 -> 0x40, carry from bit 0
    setc r14b                       ; -> 1
    mov r12, rax                    ; -> 0xffffffffffffff40 (not rcx: cl is used as a count below)

    ; sar is arithmetic, so the same value keeps its sign
    mov rax, 0x0000000000000081
    sar al, 1                       ; 0x81 -> 0xc0
    mov rdx, rax                    ; -> 0x00000000000000c0

    ; by an immediate, and by cl
    mov rax, 0x0000000000000001
    shl al, 5                       ; -> 0x20
    mov rsi, rax

    mov rax, 0x0000000000000080
    mov cl, 3
    shr al, cl                      ; -> 0x10
    mov rdi, rax

    ; the count is masked by 31, so 33 shifts by one rather than by 33
    mov rax, 0x0000000000000001
    mov cl, 33
    shl al, cl                      ; -> 0x02
    mov r9, rax

    ; a memory operand, which takes the other path through the read modify write
    mov byte [r8+0x10], 0x81
    shl byte [r8+0x10], 1           ; -> 0x02
    movzx r10, byte [r8+0x10]

    ; a shift by zero leaves the value and the flags alone
    mov rax, 0x00000000000000ff
    mov cl, 0
    shr al, cl                      ; unchanged
    mov r11, rax                    ; -> 0xff

    hlt

%include "long-mode-epilogue.inc"
