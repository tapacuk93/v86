; Reading and writing the fs and gs bases without a system call, and rdtscp.
;
; A 64-bit kernel reaches its per-processor state through gs, and user code reaches thread local
; storage through fs. Doing either through wrmsr costs a trip to ring 0, so the four fsgsbase
; instructions exist to do it directly - and because they are unprivileged, they are gated: a
; processor whose cr4.fsgsbase is clear answers them with #ud, and so must this one. A guest that
; has not asked for the feature must not be given it quietly.
;
; rdtscp reads the timestamp counter and, beside it, whatever the kernel put in IA32_TSC_AUX - its
; own number for the processor, so a thread can tell whether it moved between two readings. There
; is one processor here, so what comes back is what was written.
;
; All three of the register writes are checked for zero extension, which is the trap every 32-bit
; delegation in this work has fallen into: a 32-bit write clears the upper half, and an
; implementation that preserves it is wrong in a way nothing notices until a value is reused.
%include "long-mode.inc"

IDT equ 0x9000

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; an idt whose #ud handler steps over the instruction that faulted
    mov rdi, IDT + 6*16
    mov rax, ud_handler
    mov [rdi], ax
    mov word [rdi + 2], 0x08
    mov byte [rdi + 4], 0
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

    xor r8, r8
    xor r15, r15                            ; set by the #ud handler

    ; 1: before cr4.fsgsbase is set, this is #ud. The handler sets r15 and steps past it; the
    ; instruction is five bytes, which is what the handler adds.
    rdfsbase rax
    mov r8, r15                             ; -> 1, it faulted

    ; now ask for the feature
    mov rax, cr4
    or rax, 1 << 16
    mov cr4, rax

    ; 2: a base in the high half of the address space, which is where a kernel's own is
    mov rax, 0xFFFF800012340000
    wrfsbase rax
    xor rbx, rbx
    rdfsbase rbx
    mov r9, rbx                             ; -> 0xffff800012340000

    ; 3: a base that can actually be read through, and the proof that it took effect
    mov dword [0x40000], 0x11112222
    mov rax, 0x40000
    wrfsbase rax
    mov r10d, [fs:0]                        ; -> 0x11112222

    ; 4: the same for gs, which has its own base and its own instruction
    mov dword [0x41000], 0x33334444
    mov rax, 0x41000
    wrgsbase rax
    mov r11d, [gs:0]                        ; -> 0x33334444
    xor rbx, rbx
    rdgsbase rbx
    mov r12, rbx                            ; -> 0x41000

    ; 5: the 32-bit form writes a 32-bit base, and the read of it zero extends like every other
    ; 32-bit write - the upper half of the register must not survive
    mov rax, -1
    wrfsbase eax                            ; a base of 0xffffffff
    mov rbx, -1
    rdfsbase ebx
    mov r13, rbx                            ; -> 0xffffffff, not 0xffffffffffffffff

    ; 6: rdtscp hands back what the kernel put in IA32_TSC_AUX
    mov ecx, 0xC0000103
    mov eax, 0x2A
    xor edx, edx
    wrmsr
    mov rcx, -1
    rdtscp
    mov r14, rcx                            ; -> 0x2a, and zero extended

    hlt

; The faulting instruction is five bytes - f3 48 0f ae c0 - and nothing here is meant to retry it,
; so the frame's return address is stepped past it.
ud_handler:
    mov r15, 1
    mov rax, [rsp]
    add rax, 5
    mov [rsp], rax
    o64 iret

%include "long-mode-epilogue.inc"
