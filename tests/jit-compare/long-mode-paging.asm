; The four level walk beyond the identity mapped large page the other fixtures use: a 4 KiB page,
; reached through a page table, mapping a virtual address that is not its own physical address.
BITS 32
    org 0x1000

    ; 0x10000 pml4, 0x11000 pdpt, 0x12000 pd, 0x13000 pt
    mov edi, 0x10000
    mov ecx, 0x4000 / 4
    xor eax, eax
    rep stosd

    mov dword [0x10000], 0x11000 | 3        ; pml4[0] -> pdpt
    mov dword [0x11000], 0x12000 | 3        ; pdpt[0] -> pd
    mov dword [0x12000], 0x00000000 | 0x83  ; pd[0] -> 2 MiB identity page, for the code

    ; pd[2] covers virtual 0x400000..0x5fffff, through a page table rather than a large page
    mov dword [0x12000 + 2*8], 0x13000 | 3
    ; pt[0] maps virtual 0x400000 to physical 0x30000
    mov dword [0x13000], 0x30000 | 3
    ; pt[1] maps virtual 0x401000 to physical 0x31000
    mov dword [0x13000 + 8], 0x31000 | 3

    ; seed the physical pages while addressing is still flat
    mov dword [0x30000], 0xDEADBEEF
    mov dword [0x31000], 0xCAFEF00D

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

    ; read through the page table, at addresses that are not their own physical addresses
    mov eax, [0x400000]                     ; expect 0xDEADBEEF
    mov ebx, [0x401000]                     ; expect 0xCAFEF00D

    ; write through it and read back, which exercises the dirty bit path
    mov dword [0x400004], 0x12345678
    mov ecx, [0x400004]                     ; expect 0x12345678

    ; and confirm the identity mapped large page still works alongside it
    mov dword [0x50000], 0x5A5A5A5A
    mov edx, [0x50000]                      ; expect 0x5A5A5A5A

    hlt

%include "long-mode-epilogue.inc"
