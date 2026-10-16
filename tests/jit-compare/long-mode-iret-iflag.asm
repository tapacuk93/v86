; Whether iret puts the interrupt flag back, and whose privilege decides.
;
; `update_eflags` refuses to change the interrupt flag when cpl is above iopl, which is the rule
; for popf: unprivileged code may not open or close interrupts behind the kernel's back. iret has
; the same rule, but the privilege it asks about is the one that *executed* the iret, not the one
; being returned to. A kernel at cpl 0 with iopl 0 satisfies it and so restores the flag, even
; though the ring 3 code it is returning to never could.
;
; Deciding with the new cpl instead refuses the update, and the thread arrives in user mode with
; interrupts disabled - a state no hardware can produce, since the only way into cpl 3 is an iret
; or a sysret and neither can leave it that way. The guest does not notice until something looks
; at the flags: windows reads them off the trap frame of the first fault its first user mode
; thread takes, and bugchecks rather than carry on. The symptom is a process that never executes a
; single instruction.
;
; Four legs: the flag going on across a privilege change, going off across one, going on without a
; privilege change, and popf at cpl 3 being refused - which is the rule iret is being told apart
; from, and which a fix that simply dropped the check would break.

%define TSS       0x8000
%define IDT       0x9000
%define KSTACK    0x6000
%define USTACK    0x7000

%include "long-mode.inc"

BITS 64
DEFAULT ABS

; vector, handler
%macro SET_GATE 2
    mov rdi, IDT + (%1 * 16)
    mov rax, %2
    mov [rdi], ax
    mov word [rdi + 2], 0x08                ; the ring 0 code selector
    mov byte [rdi + 4], 0                   ; no ist
    mov byte [rdi + 5], 0xEE                ; present, dpl 3, 64-bit interrupt gate
    shr rax, 16
    mov [rdi + 6], ax
    shr rax, 16
    mov [rdi + 8], eax
    mov dword [rdi + 12], 0
%endmacro

long_mode:
    mov rsp, KSTACK

    ; the prologue maps the low 2 MiB supervisor-only; cpl 3 needs the u bit at every level
    mov dword [0x10000], 0x11000 | 7
    mov dword [0x11000], 0x12000 | 7
    mov dword [0x12000], 0x87
    mov rax, cr3
    mov cr3, rax

    mov rdi, TSS
    mov rcx, 0x68 / 8
    xor rax, rax
    rep stosq
    mov qword [TSS + 4], KSTACK             ; rsp0

    mov rdi, gdt + 0x30
    mov word [rdi], 0x67
    mov word [rdi + 2], TSS
    mov byte [rdi + 4], 0
    mov byte [rdi + 5], 0x89                ; present, available 64-bit tss
    mov byte [rdi + 6], 0
    mov byte [rdi + 7], 0
    mov dword [rdi + 8], 0
    mov dword [rdi + 12], 0
    mov ax, 0x30
    ltr ax

    mov rdi, IDT
    mov rcx, 0x1000 / 8
    xor rax, rax
    rep stosq
    SET_GATE 0x40, back_handler
    SET_GATE 0x41, halt_handler
    lidt [idtr]

    xor r8, r8
    xor r9, r9
    xor r10, r10
    xor r11, r11

    ; 1: down to cpl 3 with the flag asked for, from a kernel that has interrupts closed. The
    ; kernel's own state is what a real one is in here - it closed them to build the frame.
    cli
    push qword 0x23                         ; ss, rpl 3
    push qword USTACK
    push qword 0x202                        ; rflags, if set
    push qword 0x2b                         ; cs, rpl 3
    push qword user_if_on
    iretq

user_if_on:                                 ; cpl 3
    pushfq
    pop rax
    shr rax, 9
    and rax, 1
    mov r8, rax                             ; -> 1, the flag was put back

    ; 2: popf at cpl 3 must not be able to close them again, iopl being 0
    pushfq
    pop rax
    and rax, ~(1 << 9)                      ; ask for interrupts off
    push rax
    popfq
    pushfq
    pop rax
    shr rax, 9
    and rax, 1
    mov r9, rax                             ; -> 1, still on: popf was refused

    int 0x40                                ; back to cpl 0 to set up the next leg

user_if_off:                                ; cpl 3 again, this time asked for with the flag clear
    pushfq
    pop rax
    shr rax, 9
    and rax, 1
    mov r10, rax                            ; -> 0, the flag went off the same way it went on
    int 0x41

; Returns to cpl 3 a second time, with the flag clear in the frame. The same instruction that put
; it on has to be able to take it off, or the test above only shows that nothing is being updated.
back_handler:
    sti                                     ; the kernel's own flag, which must not leak through
    push qword 0x23
    push qword USTACK
    push qword 0x002                        ; rflags, if clear
    push qword 0x2b
    push qword user_if_off
    iretq

halt_handler:                               ; cpl 0, entered through an interrupt gate
    ; 3: and the same question without a privilege change. The gate cleared the flag on the way
    ; in, so the frame's copy of it is the only way it can come back.
    pushfq
    pop rax
    shr rax, 9
    and rax, 1
    mov r11, rax                            ; -> 0, an interrupt gate closed them
    push qword 0x10                         ; ss
    push qword KSTACK
    push qword 0x202                        ; rflags, if set
    push qword 0x08                         ; cs, same privilege
    push qword same_ring
    iretq

same_ring:                                  ; cpl 0
    pushfq
    pop rax
    shr rax, 9
    and rax, 1
    mov r12, rax                            ; -> 1, restored without a privilege change too
    hlt

align 8
gdt:
    dq 0                                    ; 0x00 null
    dq 0x00209A0000000000                   ; 0x08 64-bit code, dpl 0
    dq 0x0000920000000000                   ; 0x10 data, dpl 0
    dq 0                                    ; 0x18
    dq 0x0000F20000000000                   ; 0x20 data, dpl 3
    dq 0x0020FA0000000000                   ; 0x28 64-bit code, dpl 3
    dq 0                                    ; 0x30 the tss descriptor, written at run time
    dq 0
gdt_end:
gdtr:
    dw gdt_end - gdt - 1
    dd gdt
idtr:
    dw 0x1000 - 1
    dq IDT
