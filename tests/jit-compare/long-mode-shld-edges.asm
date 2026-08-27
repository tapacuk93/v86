; The shift counts shld and shrd have to survive.
;
; The count is masked with 31 even at an operand size of 16, so a guest can ask for a shift of 20
; bits out of a 16-bit operand. The architecture calls that undefined and hardware produces
; something arbitrary; what matters here is that the emulator does not compute `16 - 20` as an
; unsigned shift amount and take itself down on a guest's undefined behaviour.
;
; The other end is a count of one less than the operand size, the largest that is defined, where
; both halves of the result come from a shift by one.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; a 16-bit shld asked for 20 bits: past the operand size, so the destination is left as it was
    mov rax, 0xFFFFFFFFFFFF1234
    mov bx, 0xABCD
    mov cl, 20
    shld ax, bx, cl
    mov r8, rax                             ; -> ffffffffffff1234

    ; the largest defined count at 64 bits
    mov rax, 0x8000000000000000
    mov rbx, 0xFFFFFFFFFFFFFFFF
    shld rax, rbx, 63
    mov r9, rax                             ; -> 7fffffffffffffff
    setc r10b
    movzx r10, r10b                         ; -> 0, the bit shifted out was clear

    ; and a count of zero, which changes nothing at all
    mov rax, 0x1122334455667788
    mov rbx, 0xFFFFFFFFFFFFFFFF
    stc
    shld rax, rbx, 0
    mov r11, rax                            ; -> 1122334455667788
    setc r12b
    movzx r12, r12b                         ; -> 1, carry untouched

    hlt

%include "long-mode-epilogue.inc"
