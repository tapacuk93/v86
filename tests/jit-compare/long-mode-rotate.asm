; The rotates of the shift group - rol, ror, rcl and rcr. Windows mixes pointers with rol on the
; way into long mode, so winload reaches these before it has an idt and the #ud was fatal.
;
; They are not shifts with a different direction: they leave sf, zf and pf untouched, where a shift
; publishes its result to all three. Case G is what pins that down.
;
; The expected values come from running this same sequence on a real x86-64 rather than from
; working out what it should be; see the oracle referenced in long-mode-rotate.expected. Only cf
; and of are compared, since those are the only flags a rotate defines.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    ; A: rol by an immediate, 64-bit
    mov rax, 0x123456789abcdef0
    rol rax, 5
    mov r8, rax
    pushfq
    pop rax
    and rax, 0x801                  ; cf|of, the only flags a rotate defines
    mov r9, rax

    ; B: ror by an immediate, 64-bit
    mov rax, 0x123456789abcdef0
    ror rax, 4
    mov r10, rax
    pushfq
    pop rax
    and rax, 0x801
    mov r11, rax

    ; C: rcl by one with cf clear, rotating the top bit out into cf
    mov rax, 0x8000000000000000
    clc
    rcl rax, 1
    mov r12, rax
    pushfq
    pop rax
    and rax, 0x801
    mov r13, rax

    ; D: the 32-bit form, which must zero extend like any other 32-bit write
    mov rax, 0xffffffff12345678
    rol eax, 8
    mov r14, rax
    pushfq
    pop rax
    and rax, 0x801
    mov r15, rax

    ; E: rcr by a large count with cf set, a cycle 65 bits wide
    mov rax, 0x0123456789abcdef
    stc
    rcr rax, 63
    mov rbx, rax
    pushfq
    pop rax
    and rax, 0x801
    mov rcx, rax

    ; F: the 8-bit form, whose count is taken modulo the operand width
    mov rax, 0x12
    rol al, 9
    mov rdx, rax
    pushfq
    pop rax
    and rax, 0x801
    mov rsi, rax

    ; G: sf, zf and pf are not outputs of a rotate and must survive it. xor sets zf and pf, the mov
    ; between does not touch flags, and the rotate must not publish a result of its own.
    xor rax, rax
    mov rax, 1
    rol rax, 1
    mov rdi, rax
    pushfq
    pop rax
    and rax, 0x8d5                  ; the whole arithmetic set, to catch zf and pf being clobbered
    mov rbp, rax

    hlt

%include "long-mode-epilogue.inc"
