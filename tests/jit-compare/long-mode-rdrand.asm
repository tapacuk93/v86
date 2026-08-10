; rdrand is what windows uses to seed itself once cpuid advertises it, and it is reached through
; the 0f c7 group rather than an opcode of its own.
;
; The values it produces are not reproducible, so what is checked here is the shape of the result
; instead: the 32-bit form zero extends like every other 32-bit write, and success is reported in cf
; with the remaining arithmetic flags cleared.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    mov rbx, -1
    rdrand ebx                  ; the 32-bit form must clear the top half
    shr rbx, 32
    mov r8, rbx                 ; -> 0

    rdrand rcx                  ; the 64-bit form, two draws wide
    pushfq
    pop rax
    and rax, 0x8d5              ; cf|pf|af|zf|sf|of
    mov r9, rax                 ; -> 1, cf alone
    xor rcx, rcx                ; the draw itself differs run to run, so it cannot be left live

    hlt

%include "long-mode-epilogue.inc"
