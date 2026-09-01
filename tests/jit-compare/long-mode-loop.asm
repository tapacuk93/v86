; loop, loope, loopne and jrcxz, which count in rcx rather than in ecx.
;
; The counter is the whole register in long mode - the address size chooses it, and 64 is the
; default - so a count whose low 32 bits are 1 does not fall to zero on the first turn. That is the
; case an implementation written for 32-bit mode gets wrong, and the last test below is only about
; that.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; plain loop: five turns and rcx left at zero
    mov rcx, 5
    xor r8, r8
.plain:
    inc r8
    loop .plain                             ; -> r8 = 5

    ; loope keeps going while zf is set and the count is not out
    xor rax, rax
    mov rcx, 4
    xor r9, r9
.while_equal:
    inc r9
    cmp rax, rax                            ; zf = 1
    loope .while_equal                      ; -> r9 = 4, the count ran out first

    ; loopne stops the moment zf is set, whatever is left in the count
    mov rcx, 9
    xor r10, r10
.until_equal:
    inc r10
    cmp rax, rax                            ; zf = 1
    loopne .until_equal                     ; -> r10 = 1
    mov r11, rcx                            ; -> 8, decremented once and abandoned

    ; jrcxz reads the count without touching it
    xor rcx, rcx
    mov r12, 1
    jrcxz .zero
    mov r12, 2
.zero:
    mov r13, rcx                            ; -> 0, jrcxz left it alone

    ; and the whole register counts: 0x100000001 decrements to 0x100000000, which is not zero,
    ; so this is taken. An implementation counting in ecx would see 1 -> 0 and fall through.
    mov rcx, 0x100000001
    mov r14, 0
    loop .wide
    mov r14, 0xbad
    jmp .done
.wide:
    mov r14, 1
.done:
    mov r15, rcx                            ; -> 0x100000000

    hlt

%include "long-mode-epilogue.inc"
