; Interrupt delivery in long mode when the ring changes, and the interrupt stack table.
;
; Long mode drops the 32-bit rules here. The stack pointer comes from a 64-bit tss that holds bare
; pointers and no selectors; ss is loaded with a null selector whose rpl records the ring; the
; frame is always five eight-byte slots, ss and rsp included, whether or not the ring changed; and
; an ist entry switches the stack whatever the privilege, which is how a kernel gives #df and nmi a
; stack it knows is good.
;
; Windows needs all of it as soon as anything runs in user mode, since every interrupt taken there
; comes back through this path.
;
; This builds its own idt and tss, drops to cpl 3 through iretq - which is the privilege-changing
; return this same work had to teach iret - takes an interrupt back up, and returns again.
;
; Expected values are derived rather than measured: this is ring 0 setup, so the user space oracle
; the other fixtures use cannot run it.

%define TSS       0x8000
%define IDT       0x9000
%define KSTACK    0x6000
%define ISTSTACK  0x5000
%define USTACK    0x7000

%include "long-mode.inc"

BITS 64
DEFAULT ABS

; vector, handler, ist index
%macro SET_GATE 3
    mov rdi, IDT + (%1 * 16)
    mov rax, %2
    mov [rdi], ax                           ; offset 15:0
    mov word [rdi + 2], 0x08                ; the ring 0 code selector
    mov byte [rdi + 4], %3                  ; ist index, 0 for none
    mov byte [rdi + 5], 0xEE                ; present, dpl 3, 64-bit interrupt gate
    shr rax, 16
    mov [rdi + 6], ax                       ; offset 31:16
    shr rax, 16
    mov [rdi + 8], eax                      ; offset 63:32
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

    ; a 64-bit tss: rsp0 at 4, ist1 at 0x24, and nothing else that matters here
    mov rdi, TSS
    mov rcx, 0x68 / 8
    xor rax, rax
    rep stosq
    mov qword [TSS + 4], KSTACK
    mov qword [TSS + 0x24], ISTSTACK

    ; its descriptor, which in long mode is sixteen bytes rather than eight
    mov rdi, gdt + 0x30
    mov word [rdi], 0x67                    ; limit
    mov word [rdi + 2], TSS                 ; base 15:0
    mov byte [rdi + 4], 0                   ; base 23:16
    mov byte [rdi + 5], 0x89                ; present, available 64-bit tss
    mov byte [rdi + 6], 0                   ; limit 19:16 and flags
    mov byte [rdi + 7], 0                   ; base 31:24
    mov dword [rdi + 8], 0                  ; base 63:32
    mov dword [rdi + 12], 0
    mov ax, 0x30
    ltr ax

    mov rdi, IDT
    mov rcx, 0x1000 / 8
    xor rax, rax
    rep stosq
    SET_GATE 0x40, ring3_handler, 0
    SET_GATE 0x41, ist_handler, 1
    SET_GATE 0x42, halt_handler, 0
    lidt [idtr]

    xor r8, r8
    xor r9, r9
    xor r10, r10
    xor r12, r12
    xor r13, r13
    xor r14, r14
    xor r15, r15

    ; down to cpl 3 by returning to a frame built by hand, which is the privilege-changing iret
    push qword 0x23                         ; ss, rpl 3
    push qword USTACK
    push qword 0x202                        ; rflags, if set
    push qword 0x2b                         ; cs, rpl 3
    push qword user_entry
    iretq

user_entry:                                 ; cpl 3, rsp = USTACK
    int 0x40
    ; iretq should have put us back at cpl 3 on the stack we left
    mov bx, cs
    cmp bx, 0x2b
    sete r15b
    movzx r15, r15b

    int 0x41                                ; the one with an ist entry
    int 0x42                                ; the one that halts

ring3_handler:                              ; cpl 0
    mov bx, cs
    cmp bx, 0x08
    sete r8b
    movzx r8, r8b

    mov rbx, rsp                            ; rsp0 was loaded, so the frame is just under KSTACK
    shr rbx, 8
    cmp rbx, (KSTACK >> 8) - 1
    sete r9b
    movzx r9, r9b

    mov rbx, [rsp + 8]                      ; the interrupted cs
    cmp rbx, 0x2b
    sete r10b
    movzx r10, r10b

    mov rbx, [rsp + 32]                     ; the interrupted ss
    cmp rbx, 0x23
    sete r12b
    movzx r12, r12b

    mov rbx, [rsp + 24]                     ; the interrupted rsp
    cmp rbx, USTACK
    sete r13b
    movzx r13, r13b

    iretq

ist_handler:                                ; cpl 0, on the ist stack rather than rsp0
    mov rbx, rsp
    shr rbx, 8
    cmp rbx, (ISTSTACK >> 8) - 1
    sete r14b
    movzx r14, r14b
    iretq

halt_handler:
    hlt

align 8
gdt:
    dq 0                                    ; 0x00 null
    dq 0x00209A0000000000                   ; 0x08 64-bit code, dpl 0
    dq 0x0000920000000000                   ; 0x10 data, dpl 0
    dq 0                                    ; 0x18 the base sysret and this layout count from
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
