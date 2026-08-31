; prefetchw, and the three cpuid bits Windows checks before it will boot.
;
; Windows refuses to start on a processor that does not advertise what it needs, and bugchecks with
; UNSUPPORTED_PROCESSOR before it has filled in its interrupt table - which is what made this hard
; to recognise: the failure looks like a breakpoint into an empty idt rather than like a missing
; feature.
;
; The bits checked here are the ones that were actually missing, and syscall is the instructive one:
; it was implemented, with a fixture driving the whole round trip to cpl 3 and back, and never
; advertised. A guest can only use what cpuid says exists, so an unadvertised implementation is as
; useless as an unimplemented one - and windows makes every system call through it.
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

    mov r13, rdx
    shr r13, 11
    and r13, 1                              ; -> 1, syscall/sysret

    mov eax, 1
    cpuid
    mov r10, rcx
    shr r10, 13
    and r10, 1                              ; -> 1, cmpxchg16b

    mov r14, rdx
    shr r14, 16
    and r14, 1                              ; -> 1, pat

    mov r15, rdx
    shr r15, 19
    and r15, 1                              ; -> 1, clflush

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
