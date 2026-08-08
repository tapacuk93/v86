; A far call and far return within 64-bit mode, which is what the windows boot path needs and what
; could not be told apart from a bug in far_return without a fixture to try it in isolation.
BITS 32
    org 0x1000

    mov edi, 0x10000
    mov ecx, 0x3000 / 4
    xor eax, eax
    rep stosd

    mov dword [0x10000], 0x11000 | 3
    mov dword [0x11000], 0x12000 | 3
    mov dword [0x12000], 0x00000000 | 0x83

    lgdt [gdtr]

    mov eax, 0x10000
    mov cr3, eax
    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax
    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8
    wrmsr
    mov eax, cr0
    or eax, (1 << 31) | 1
    mov cr0, eax

    jmp 0x08:long_mode

BITS 64
long_mode:
    mov rsp, 0x8000
    mov rax, 0                              ; set to 1 only if the far return lands correctly

    ; push a far return frame by hand: cs then rip, each 8 bytes with rex.w
    push 0x08
    push qword after_retf
    jmp far_target

far_target:
    o64 retf                                ; pops rip and cs, should land at after_retf

    mov rax, 0xBAD                          ; skipped if the far return works
after_retf:
    add rax, 1
    hlt

align 8
gdt:
    dq 0
    dq 0x00209A0000000000
    dq 0x0000920000000000
gdt_end:
gdtr:
    dw gdt_end - gdt - 1
    dd gdt
