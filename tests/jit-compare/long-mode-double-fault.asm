; A fault taken while a fault is being delivered, which is what #df means.
;
; The frame an interrupt pushes is itself memory, written through the page tables like any other.
; If the stack the gate switches to is not mapped, delivery cannot finish, and the architecture
; does not report the second fault: it raises #df, whose own gate is expected to name a stack that
; is known good. A kernel's #df handler exists precisely because this is the one fault it cannot
; prevent, and windows arrives at it with its bugcheck already decided.
;
; What is easy to get wrong is to write the frame first and notice the fault afterwards, which
; leaves the first handler running on a stack that was never writable, or to let the second fault
; be delivered as itself - a #pf inside a #pf, forever.
;
; The #pf gate here names an ist stack that is deliberately unmapped and the #df gate names one
; that is mapped, so taking an ordinary #pf has to arrive at the #df handler instead, and the #pf
; handler has to never run at all.
%include "long-mode.inc"

DFSTACK equ 0x5000                          ; mapped: inside the prologue's large page
PFSTACK equ 0x600000                        ; not mapped: there is no pd entry for it
IDT     equ 0x9000

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; a tss holding both stacks
    mov rdi, 0x8000
    mov rcx, 0x68 / 8
    xor rax, rax
    rep stosq
    mov qword [0x8000 + 0x24], DFSTACK      ; ist1
    mov qword [0x8000 + 0x2C], PFSTACK      ; ist2

    mov rdi, gdt + 0x30
    mov word [rdi], 0x67                    ; limit
    mov word [rdi + 2], 0x8000              ; base 15:0
    mov byte [rdi + 4], 0
    mov byte [rdi + 5], 0x89                ; present, available 64-bit tss
    mov byte [rdi + 6], 0
    mov byte [rdi + 7], 0
    mov dword [rdi + 8], 0
    mov dword [rdi + 12], 0
    mov ax, 0x30
    ltr ax

    ; vector 8, #df, on ist1 - the stack that is mapped
    mov rdi, IDT + 8 * 16
    mov rax, df_handler
    mov [rdi], ax
    mov word [rdi + 2], 0x08
    mov byte [rdi + 4], 1                   ; ist1
    mov byte [rdi + 5], 0x8E
    shr rax, 16
    mov [rdi + 6], ax
    shr rax, 16
    mov [rdi + 8], eax
    mov dword [rdi + 12], 0

    ; vector 14, #pf, on ist2 - the stack that is not
    mov rdi, IDT + 14 * 16
    mov rax, pf_handler
    mov [rdi], ax
    mov word [rdi + 2], 0x08
    mov byte [rdi + 4], 2                   ; ist2
    mov byte [rdi + 5], 0x8E
    shr rax, 16
    mov [rdi + 6], ax
    shr rax, 16
    mov [rdi + 8], eax
    mov dword [rdi + 12], 0

    mov rdi, 0x7300
    mov word [rdi], 0xFFF
    mov rax, IDT
    mov [rdi + 2], rax
    lidt [rdi]

    xor r8, r8                              ; set by the #df handler
    xor r9, r9                              ; its error code
    xor r10, r10                            ; whether it came in on ist1
    xor r11, r11                            ; set by the #pf handler, which must not run
    xor r12, r12                            ; cr2, which is recorded but not asserted

    mov eax, [0x700000]                     ; -> #pf, whose delivery -> #df
    hlt                                     ; not reached: #df does not return here

pf_handler:
    mov r11, 1
    hlt

; #df pushes an error code, which is always zero, so the frame is that then rip, cs, rflags, rsp,
; ss. rsp is read before anything is pushed on top of it.
;
; cr2 is read but deliberately not asserted. It comes back as the address of the frame write that
; could not be made rather than the address the original fault was about, because the second page
; fault writes cr2 on its way to being escalated - which is what every implementation at hand does,
; and is the concrete reason a #df handler is told it can assume nothing. Which of the frame's five
; writes is the one reported is not something to fix in place either.
df_handler:
    mov r8, 1
    mov r9, [rsp]
    mov rbx, rsp
    shr rbx, 8
    cmp rbx, (DFSTACK >> 8) - 1
    sete r10b
    movzx r10, r10b
    mov r12, cr2
    hlt

align 8
gdt:
    dq 0                                    ; 0x00 null
    dq 0x00209A0000000000                   ; 0x08 64-bit code, dpl 0
    dq 0x0000920000000000                   ; 0x10 data, dpl 0
    dq 0
    dq 0
    dq 0
    dq 0                                    ; 0x30 tss descriptor, written at run time
    dq 0
gdt_end:
gdtr:
    dw gdt_end - gdt - 1
    dd gdt
