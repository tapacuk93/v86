; cmpxchg is what every interlocked operation is built from: it compares the accumulator against
; the destination and swaps one way or the other depending on the answer, leaving zero set to say
; which happened. Both directions are covered, since taking the wrong one is silent.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000
    mov r8, 0x7000

    xor r14d, r14d
    xor r15d, r15d

    ; the match case: rax equals the destination, so the destination takes rbx and zero is set
    mov r9, 0x1111111111111111
    mov qword [r8], r9
    mov rax, 0x1111111111111111
    mov rbx, 0x2222222222222222
    cmpxchg [r8], rbx
    setz r14b                       ; -> 1
    mov rcx, [r8]                   ; -> 0x2222222222222222, the register was stored
    mov rdx, rax                    ; -> unchanged, still 0x1111111111111111

    ; the mismatch case: rax differs, so rax takes the destination and zero is clear
    mov r9, 0x3333333333333333
    mov qword [r8+0x20], r9
    mov rax, 0x4444444444444444
    mov rbx, 0x5555555555555555
    cmpxchg [r8+0x20], rbx
    setz r15b                       ; -> 0
    mov rsi, rax                    ; -> 0x3333333333333333, loaded from the destination
    mov rdi, [r8+0x20]              ; -> unchanged, the register was not stored

    ; a 32-bit mismatch, where the accumulator is written whole so the top half clears
    mov rax, -1
    mov r10d, 0x0000abcd
    mov r11d, 0x0000ffff
    cmpxchg r10d, r11d              ; eax != r10d, so eax takes r10d
    mov r12, rax                    ; -> 0x000000000000abcd

    ; the byte form, matching, so the destination takes the register
    mov rax, 0x77
    mov r13b, 0x77
    mov bl, 0x99
    cmpxchg r13b, bl                ; equal, so r13b -> 0x99
    movzx r13, r13b                 ; -> 0x99

    hlt

%include "long-mode-epilogue.inc"
