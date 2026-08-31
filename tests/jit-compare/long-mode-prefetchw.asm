; prefetchw, and the three cpuid bits Windows checks before it will boot.
;
; Windows 8.1 and later refuse to start on a processor without prefetchw, cmpxchg16b and
; lahf/sahf in 64-bit mode. A kernel that does not find one of them bugchecks immediately - before
; it has filled in its interrupt table, which is what made this hard to recognise: the failure
; looks like a breakpoint into an empty idt rather than like a missing feature.
;
; prefetch and prefetchw are hints. The operand is decoded so the instruction has the right length,
; and nothing is accessed - notably they do not fault on an address that is not mapped, which is
; checked here, since this fixture has no idt to take a fault with.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    mov eax, 0x80000001
    cpuid
    mov r8, rcx
    shr r8, 8
    and r8, 1                               ; -> 1, prefetchw
    mov r9, rcx
    and r9, 1                               ; -> 1, lahf/sahf in 64-bit mode

    mov eax, 1
    cpuid
    mov r10, rcx
    shr r10, 13
    and r10, 1                              ; -> 1, cmpxchg16b

    ; the hint itself changes nothing
    mov rdi, 0x7100
    mov rax, 0x1122334455667788
    mov [rdi], rax
    prefetchw [rdi]
    mov r11, [rdi]                          ; -> 1122334455667788

    ; and does not fault on an address that is not mapped
    mov rbx, 0xFFFF800000000000
    prefetchw [rbx]
    mov r12, 1                              ; -> 1, still running

    hlt

%include "long-mode-epilogue.inc"
