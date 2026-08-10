; Windows reads efer and writes it straight back to turn nxe on. By the time it does, the cpu has
; set lma itself, so the value written has lma in it - and lma is read only, meaning the write of it
; is ignored rather than faulted. Treating it as a reserved bit raises #gp, which kills a guest that
; has not installed an idt yet.
;
; The prologue's own efer write does not cover this: it runs before cr0.pg, so lma is still clear.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    mov ecx, 0xC0000080             ; ia32_efer
    rdmsr
    mov r8d, eax                    ; -> 0x500, lme set by the prologue and lma by the cpu
    mov r9d, edx                    ; -> 0, efer has nothing in its top half

    or eax, 1 << 11                 ; nxe, leaving lma set in the written value
    wrmsr                           ; must not fault

    rdmsr
    mov r10d, eax                   ; -> 0xd00, nxe now on and lma still reported
    mov r11d, edx                   ; -> 0

    hlt

%include "long-mode-epilogue.inc"
