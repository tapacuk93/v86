; syscall and sysret - the way a 64-bit kernel is entered and left.
;
; Neither reads a descriptor table. The selectors come out of IA32_STAR and the hidden segment
; state is fixed by the architecture, which is what makes them cheap and also what stops them going
; through the ordinary segment loading path. syscall leaves the return address in rcx and the flags
; in r11, because it has not switched to a stack it could push them on; sysret takes them back out.
;
; Windows enters every system call this way, so nothing in user mode runs without it.
;
; This does the whole round trip: down to cpl 3 through sysret, back up through syscall, and down
; again. The prologue's mapping is supervisor-only, so the first thing here is to set the user bit
; at all three levels - without it the first instruction fetched at cpl 3 would fault.
;
; Expected values are derived rather than measured: these are ring 0 instructions, so the user
; space oracle the other fixtures use cannot run them.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; the u bit has to be set at every level, not just the leaf
    mov dword [0x10000], 0x11000 | 7
    mov dword [0x11000], 0x12000 | 7
    mov dword [0x12000], 0x87
    mov rax, cr3
    mov cr3, rax                            ; drop the translations cached without it

    ; efer.sce, without which both instructions are #ud
    mov ecx, 0xC0000080
    rdmsr
    or eax, 1
    wrmsr

    ; star: bits 47:32 are the cs syscall enters with - 0x08, so ss is 0x10. Bits 63:48 are the
    ; base sysret returns to - 0x18, so it returns to cs 0x2b and ss 0x23. Those two need not
    ; exist in the gdt, since sysret does not look them up.
    mov ecx, 0xC0000081
    xor eax, eax
    mov edx, 0x00180008
    wrmsr

    ; lstar, where syscall from 64-bit mode lands
    mov ecx, 0xC0000082
    mov eax, kernel_entry
    xor edx, edx
    wrmsr

    ; sfmask, the rflags bits syscall clears: if and df
    mov ecx, 0xC0000084
    mov eax, 0x600
    xor edx, edx
    wrmsr

    xor r8, r8
    xor r9, r9
    xor r10, r10
    xor r12, r12
    xor r13, r13
    xor r14, r14
    xor r15, r15

    ; into user mode, which from here is only reachable through sysret
    mov rcx, user_entry
    mov r11, 0x202                          ; if set, and the bit that is always set
    o64 sysret

user_entry:                                 ; cpl 3
    mov r8, 0x1111111111111111
    mov r9, 0x2222222222222222
    xor eax, eax                            ; call 0: the one that checks things
    syscall
after_syscall:
    ; sysret should have put us back at cpl 3 with the selector star named
    mov bx, cs
    cmp bx, 0x2b
    sete r15b
    movzx r15, r15b

    mov eax, 1                              ; call 1: the handler halts
    syscall

kernel_entry:                               ; cpl 0
    cmp eax, 1
    je .halt

    mov bx, cs
    cmp bx, 0x08                            ; the selector out of star, with rpl forced to 0
    sete r10b
    movzx r10, r10b

    mov bx, ss
    cmp bx, 0x10                            ; the descriptor after it
    sete r12b
    movzx r12, r12b

    mov rbx, after_syscall
    cmp rcx, rbx                            ; syscall saved the address of the next instruction
    sete r13b
    movzx r13, r13b

    pushfq
    pop rbx
    shr rbx, 9
    and rbx, 1
    xor rbx, 1                              ; 1 if syscall cleared if, as sfmask asked it to
    mov r14, rbx

    o64 sysret                              ; rcx and r11 are still what syscall left there

.halt:
    hlt

%include "long-mode-epilogue.inc"
