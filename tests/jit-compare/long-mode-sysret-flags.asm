; What sysret does to rflags, which is take them wholesale out of r11.
;
; Unlike iret and popf, sysret asks no permission: there is no cpl against iopl test, because the
; only thing that can execute it is a kernel at cpl 0. It loads what r11 holds, forces bit 1 on,
; and never lets vm or rf through. So the interrupt flag goes back exactly as the kernel left it
; in r11 before the call - which for every return to user mode means back on, the kernel having
; run with it off since syscall cleared it through sfmask.
;
; That matters beyond the flag itself: an interrupt that arrived while the kernel had them closed
; has to be let through at this point. A process making one system call after another closes them
; again almost at once, so an interrupt merely deferred to the emulator's next convenient moment
; is an interrupt lost. This fixture checks the flags; the delivery is the same argument iret,
; popf and sti already carry in their implementations.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; cpl 3 needs the u bit at every level, not just the leaf
    mov dword [0x10000], 0x11000 | 7
    mov dword [0x11000], 0x12000 | 7
    mov dword [0x12000], 0x87
    mov rax, cr3
    mov cr3, rax

    mov ecx, 0xC0000080                     ; efer.sce
    rdmsr
    or eax, 1
    wrmsr

    ; star: syscall enters at cs 0x08, sysret returns to the pair based at 0x18
    mov ecx, 0xC0000081
    xor eax, eax
    mov edx, 0x00180008
    wrmsr

    mov ecx, 0xC0000082                     ; lstar
    mov eax, kernel_entry
    xor edx, edx
    wrmsr

    mov ecx, 0xC0000084                     ; sfmask: syscall clears if and df
    mov eax, 0x600
    xor edx, edx
    wrmsr

    xor r8, r8
    xor r9, r9
    xor r10, r10
    xor r12, r12
    xor r13, r13                            ; which time through the kernel this is

    ; the kernel's own flags are not what user mode gets: close interrupts here, and ask for them
    ; open in r11. What arrives in user mode has to come from r11.
    cli
    mov rcx, first_user
    mov r11, 0x202                          ; if set, and the bit that is always set
    o64 sysret

first_user:                                 ; cpl 3
    pushfq
    pop rax
    mov r8, rax                             ; -> 0x202, exactly what r11 asked for
    shr rax, 9
    and rax, 1
    mov r9, rax                             ; -> 1, the interrupt flag is on

    syscall                                 ; back to the kernel, which sends us down again

second_user:                                ; cpl 3 again, this time asked for with if clear
    pushfq
    pop rax
    shr rax, 9
    and rax, 1
    mov r10, rax                            ; -> 0, the same instruction takes the flag away

    ; and the bits sysret refuses to let through: vm and rf were set in r11 and must not appear
    pushfq
    pop rax
    and rax, (1 << 17) | (1 << 16)          ; vm and rf
    mov r12, rax                            ; -> 0

    syscall                                 ; cpl 3 cannot halt, so go back up to do it

; Entered twice: the first time it sends us down again with different flags, the second time there
; is nothing left to check and it stops.
kernel_entry:                               ; cpl 0
    cmp r13, 0
    jne done
    mov r13, 1
    mov rcx, second_user
    mov r11, 0x002 | (1 << 17) | (1 << 16)  ; if clear, and two bits that cannot survive
    o64 sysret
done:
    hlt

%include "long-mode-epilogue.inc"
