; Shared prologue: build page tables and a gdt, enter long mode, jump to `long_mode`.
; Only the low 2 MiB is mapped, with a single large page, which is all these fixtures need.
BITS 32
    org 0x1000

    mov edi, 0x10000
    mov ecx, 0x3000 / 4
    xor eax, eax
    rep stosd

    mov dword [0x10000], 0x11000 | 3        ; pml4[0] -> pdpt
    mov dword [0x11000], 0x12000 | 3        ; pdpt[0] -> pd
    mov dword [0x12000], 0x00000000 | 0x83  ; pd[0]   -> 2 MiB page

    lgdt [gdtr]

    mov eax, 0x10000
    mov cr3, eax
    mov eax, cr4
    or eax, 1 << 5                          ; cr4.pae
    mov cr4, eax
    mov ecx, 0xC0000080                     ; ia32_efer
    rdmsr
    or eax, 1 << 8                          ; lme
    wrmsr
    ; the harness starts with is_32 set but cr0 untouched, so pe is needed alongside pg
    mov eax, cr0
    or eax, (1 << 31) | 1
    mov cr0, eax

    jmp 0x08:long_mode
