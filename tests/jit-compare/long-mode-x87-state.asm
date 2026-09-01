; The x87 escapes that move the whole coprocessor state through memory, and fisttp.
;
; fnsave and frstor are the only x87 instructions that touch more than ten bytes at a time: they
; carry the 28-byte protected-mode environment followed by the eight registers in stack order.
; Long mode has no wider form of its own - rex.w selects the same 108-byte layout - so what is new
; is only that the address no longer fits in the 32 bits the rest of the fpu plumbing passes round.
;
; fisttp is here because advertising sse3 is what makes a compiler emit it in place of the
; fnstcw/fldcw dance around fistp, and 64-bit windows reaches it early. It truncates toward zero
; whatever the rounding mode says, which is the whole of the difference from fistp.
;
; The values are checked by round trip rather than against hand-computed bytes: what fnsave writes
; is only interesting insofar as frstor reads it back.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000
    mov rdi, 0x7100                         ; a scratch qword
    mov rsi, 0x7200                         ; the 108-byte save area

    finit

    ; three exactly representable values, leaving st0 = 13, st1 = 11, st2 = 7
    mov qword [rdi], 7
    fild qword [rdi]
    mov qword [rdi], 11
    fild qword [rdi]
    mov qword [rdi], 13
    fild qword [rdi]

    fnsave [rsi]                            ; the state out, and an finit on what is left behind

    ; so the control word reads back as the reset value rather than whatever was in it
    fnstcw [rdi]
    movzx r8, word [rdi]                    ; -> 0x37f

    frstor [rsi]                            ; and the whole stack comes back

    fistp qword [rdi]
    mov r9, [rdi]                           ; -> 13
    fistp qword [rdi]
    mov r10, [rdi]                          ; -> 11
    fistp qword [rdi]
    mov r11, [rdi]                          ; -> 7

    ; 15/4 is 3.75, which rounds to 4 and truncates to 3
    mov qword [rdi], 15
    fild qword [rdi]
    mov qword [rdi], 4
    fild qword [rdi]
    fdivp st1
    fisttp qword [rdi]
    mov r12, [rdi]                          ; -> 3

    ; and from below, where truncation goes the other way from rounding
    mov qword [rdi], -15
    fild qword [rdi]
    mov qword [rdi], 4
    fild qword [rdi]
    fdivp st1
    fisttp qword [rdi]
    mov r13, [rdi]                          ; -> -3

    hlt

%include "long-mode-epilogue.inc"
