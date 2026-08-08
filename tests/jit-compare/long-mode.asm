; Enter long mode and run a few 64-bit instructions, so the code generator can be tested there the
; same way it is in 32-bit mode.
;
; The harness starts this in 32-bit protected mode with flat segments and nothing else set up, so
; the paging structures and the gdt are both built here. Only the low 2 MiB is mapped, with a
; single large page, which is all the test needs.

BITS 32
    org 0x1000

    ; page tables. pml4 -> pdpt -> pd, with the pd entry a 2 MiB page covering 0..2 MiB
    mov edi, 0x10000
    mov ecx, 0x3000 / 4
    xor eax, eax
    rep stosd

    mov dword [0x10000], 0x11000 | 3        ; pml4[0] -> pdpt, present + rw
    mov dword [0x11000], 0x12000 | 3        ; pdpt[0] -> pd,   present + rw
    mov dword [0x12000], 0x00000000 | 0x83  ; pd[0]   -> 2 MiB page, present + rw + ps

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

    ; pe as well as pg: the harness starts with is_32 set but cr0 untouched, and paging cannot be
    ; enabled without protected mode
    mov eax, cr0
    or eax, (1 << 31) | 1                   ; cr0.pg | cr0.pe, which activates long mode
    mov cr0, eax

    jmp 0x08:long_mode

BITS 64
long_mode:
    ; a handful of 64-bit operations whose results end up in registers the harness compares
    mov rax, 0x1122334455667788
    mov rbx, 0x00000000FFFFFFFF
    add rax, rbx
    mov rcx, rax
    sub rcx, 0x1000
    xor rdx, rdx
    or rdx, rcx
    and rdx, rbx
    mov rsi, 0x7FFFFFFFFFFFFFFF
    add rsi, 1                              ; overflow, so the flags matter
    mov rdi, 0
    sub rdi, 1                              ; borrow
    hlt

align 8
gdt:
    dq 0                                    ; null
    dq 0x00209A0000000000                   ; 64-bit code: present, dpl0, exec/read, l=1
    dq 0x0000920000000000                   ; data
gdt_end:

gdtr:
    dw gdt_end - gdt - 1
    dd gdt
