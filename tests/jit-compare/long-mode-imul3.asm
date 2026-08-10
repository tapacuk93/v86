; imul with three operands, which is how an index is scaled by a structure size. Carry and overflow
; report that the product did not fit in the destination; the other arithmetic flags are undefined
; and are not asserted here.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    xor r14d, r14d
    xor r15d, r15d

    ; the byte immediate form, scaling a small index
    mov rax, 7
    imul rbx, rax, 24               ; -> 168

    ; a negative immediate, sign extended from a byte
    mov rax, 5
    imul rcx, rax, -3               ; -> -15

    ; the wide immediate form
    mov rax, 0x10000
    imul rdx, rax, 0x10000          ; -> 0x100000000, which fits in 64 bits

    ; a product that does not fit: carry and overflow are set
    mov rax, 0x4000000000000000
    imul rsi, rax, 4                ; -> 0 with the top bits lost
    setc r14b                       ; -> 1

    ; one that does fit, where they must be clear
    mov rax, 0x100
    imul rdi, rax, 0x100            ; -> 0x10000
    setc r15b                       ; -> 0

    ; at a 32-bit operand size the destination is 32 bits and the top half is cleared
    mov r8, -1
    mov eax, 0x10000
    imul r8d, eax, 0x10000          ; 32-bit product is 0, so r8 -> 0

    ; from memory rather than a register, through an extended base
    mov r9, 0x7000
    mov qword [r9], 9
    imul r10, qword [r9], 11        ; -> 99

    hlt

%include "long-mode-epilogue.inc"
