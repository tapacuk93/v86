; 32-bit paging through the tlb, run both interpreted and compiled.
;
; This is the regression net for changes to the tlb: the interpreter looks entries up in rust and
; compiled code has its own inlined lookup, so the two agreeing is exactly what a differential run
; checks. It covers the three things a tlb has to get right - filling an entry, keeping two virtual
; addresses that share a physical page in agreement, and dropping a stale entry on invlpg.
;
; Layout, all inside the 8 MiB the harness gives us:
;   0x20000  page directory
;   0x21000  page table for virtual 0..4 MiB, identity
;   0x22000  page table for virtual 4..8 MiB, one entry
;   0x30000  the physical page virtual 0x400000 starts out pointing at
;   0x31000  the one it is moved to

BITS 32
    org 0x1000

    ; zero the three tables
    mov edi, 0x20000
    mov ecx, 0x3000 / 4
    xor eax, eax
    rep stosd

    ; identity map the first 4 MiB, which covers the code, the tables and both data pages
    mov edi, 0x21000
    mov eax, 3                      ; present, writable, physical 0
    mov ecx, 1024
fill:
    stosd
    add eax, 0x1000
    loop fill

    mov dword [0x20000], 0x21000 | 3
    mov dword [0x20004], 0x22000 | 3        ; virtual 4..8 MiB
    mov dword [0x22000], 0x30000 | 3        ; virtual 0x400000 -> physical 0x30000

    mov eax, 0x20000
    mov cr3, eax
    ; the harness starts with is_32 set but cr0 untouched, so pe is needed alongside pg
    mov eax, cr0
    or eax, 0x80000001
    mov cr0, eax

    ; a write through the high mapping has to be visible through the identity one, since both name
    ; the same physical page
    mov dword [0x400000], 0x11111111
    mov ebx, [0x30000]              ; -> 0x11111111

    ; point the same virtual page at a different physical one. The tlb still holds the old
    ; translation at this point, so without the invlpg the write below would land on 0x30000.
    mov dword [0x22000], 0x31000 | 3
    invlpg [0x400000]

    mov dword [0x400000], 0x22222222
    mov ecx, [0x31000]              ; -> 0x22222222, the new page
    mov edx, [0x30000]              ; -> 0x11111111, the old page left as it was
    mov esi, [0x400000]             ; -> 0x22222222, the virtual address following the remap

    hlt
