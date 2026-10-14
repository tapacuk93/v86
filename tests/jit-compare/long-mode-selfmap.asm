; A page table edited through the self-map, which is how windows edits every one of them.
;
; The trick is that a paging structure is also ordinary memory, so an entry in it can be reached two
; ways: at its physical address, and through a pml4 entry pointed back at the pml4 itself. Windows
; relies on this for every mapping it makes - MiAddressToPte is `PTE_BASE + ((va >> 12) * 8)`, an
; address in that self-map - and its memory manager walks those addresses constantly.
;
; What matters for an emulator is that the two views are the same memory. Writing an entry through
; the self-map and then using the mapping it describes has to work, and so does the reverse: a write
; at the physical address has to be visible through the self-map. Caching a translation for one
; alias and missing a write through the other would leave the guest reading a page table that is not
; what it wrote - which looks, much later and somewhere else, like a mapping that was never made.
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

    ; pd[2] covers virtual 0x400000 onwards through a page table
    mov dword [0x12000 + 2*8], 0x13000 | 3
    mov dword [0x13000], 0x30000 | 3        ; virtual 0x400000 -> physical 0x30000

    ; pml4[1] points back at the pml4: the self-map. Everything below 2 MiB stays reachable through
    ; pml4[0], so this adds a second way to see the same pages rather than replacing the first.
    mov dword [0x10000 + 1*8], 0x10000 | 3

    mov dword [0x30000], 0xDEADBEEF
    mov dword [0x31000], 0xCAFEF00D

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
    mov eax, cr0
    or eax, (1 << 31) | 1
    mov cr0, eax

    jmp 0x08:long_mode

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; With pml4[1] pointing at the pml4, a virtual address whose top index is 1 walks the pml4 one
    ; level later than it otherwise would. The page table at 0x13000 is therefore visible as
    ; ordinary memory at the address below, worked out the way the kernel works it out:
    ;   pte_base = 1 << 39, sign extended
    ;   pte_of(va) = pte_base + ((va >> 12) * 8)
    ; for va = 0x400000 that is pte_base + 0x2000, which is the page holding pt[0].
    ; Top index 1 is in the low half of the address space, so the base is not sign extended - an
    ; address with the top bits set and bit 47 clear is in the hole between the halves and is #gp,
    ; which is what the first version of this fixture discovered about itself.
    mov rbx, 0x0000008000000000             ; pte_base for top index 1
    mov rsi, rbx
    add rsi, (0x400000 >> 12) * 8           ; the entry describing virtual 0x400000

    ; it should read back as what was written at the physical address
    mov r8, [rsi]                           ; -> 0x30003

    ; now repoint that entry through the self-map, to physical 0x31000
    mov rax, 0x31000 | 3
    mov [rsi], rax
    invlpg [0x400000]

    ; the mapping the entry describes has to follow the write
    mov r9d, [0x400000]                     ; -> 0xcafef00d

    ; and the write has to be visible at the physical address too, which is still identity mapped.
    ; It comes back with the accessed bit set, because the read through 0x400000 just above is
    ; exactly what sets it.
    mov r10d, [0x13000]                     ; -> 0x31023

    ; the other direction: write at the physical address, read through the self-map
    mov dword [0x13000], 0x30000 | 3
    invlpg [0x400000]
    mov r11, [rsi]                          ; -> 0x30003
    mov r12d, [0x400000]                    ; -> 0xdeadbeef

    hlt

%include "long-mode-epilogue.inc"
