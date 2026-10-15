; Every level of a page table, read through the self-map at its own address.
;
; `long-mode-selfmap` covers one level: the page table entry of an address. A kernel needs all four.
; Windows asks "is this address mapped" by walking down from the top, and each level has its own
; base, derived from the self-map index s by folding it in one more time:
;
;   pte_base = s << 39            the page tables
;   pde_base = pte_base + s << 30 the page directories
;   ppe_base = pde_base + s << 21 the page directory pointer tables
;   pxe_base = ppe_base + s << 12 the pml4 itself
;
; which is the same thing as applying `pte_of(va) = pte_base + (va >> 12) * 8` to its own result.
; The address of a page directory entry is the address of the page table entry *of* the page table
; entry. An emulator that walks the self-map correctly once but loses a level when the walk re-reads
; the pml4 two or three times over will answer the first question right and the rest wrong, and a
; kernel will believe an address is unmapped when it is not.
;
; With s = 1 the bases are 0x8000000000, 0x8040000000, 0x8040200000 and 0x8040201000. Top index 1
; is in the low half, so none of them is sign extended - an address with the top bits set and bit 47
; clear is in the hole between the halves and is #gp.
BITS 32
    org 0x1000

    ; 0x10000 pml4, 0x11000 pdpt, 0x12000 pd, 0x13000 pt, 0x14000 a second pt
    mov edi, 0x10000
    mov ecx, 0x5000 / 4
    xor eax, eax
    rep stosd

    mov dword [0x10000], 0x11000 | 3        ; pml4[0] -> pdpt
    mov dword [0x11000], 0x12000 | 3        ; pdpt[0] -> pd
    mov dword [0x12000], 0x00000000 | 0x83  ; pd[0]   -> 2 MiB identity page, for the code
    mov dword [0x12000 + 2*8], 0x13000 | 3  ; pd[2]   -> pt, covering virtual 0x400000
    mov dword [0x13000], 0x30000 | 3        ; pt[0]   -> physical 0x30000
    mov dword [0x14000], 0x31000 | 3        ; the second pt, for the write at the end

    mov dword [0x10000 + 1*8], 0x10000 | 3  ; pml4[1] -> the pml4: the self-map

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

    ; use the mapping first, so that every level has been walked and says so
    mov r13d, [0x400000]                    ; -> 0xdeadbeef

    ; the page table entry of virtual 0x400000: pte_base + (0x400000 >> 12) * 8
    mov rax, 0x8000000000 + (0x400000 >> 12) * 8
    mov r8, [rax]                           ; -> pt[0]

    ; its page directory entry: pde_base + (0x400000 >> 21) * 8
    mov rax, 0x8040000000 + (0x400000 >> 21) * 8
    mov r9, [rax]                           ; -> pd[2]

    ; its page directory pointer entry: ppe_base + (0x400000 >> 30) * 8
    mov rax, 0x8040200000 + (0x400000 >> 30) * 8
    mov r10, [rax]                          ; -> pdpt[0]

    ; and its pml4 entry: pxe_base + (0x400000 >> 39) * 8
    mov rax, 0x8040201000 + (0x400000 >> 39) * 8
    mov r11, [rax]                          ; -> pml4[0]

    ; Now edit the level above the page table, through the self-map, the way a kernel repoints a
    ; whole 2 MiB at once: write the page directory entry at the address just read from.
    mov rax, 0x8040000000 + (0x400000 >> 21) * 8
    mov rbx, 0x14000 | 3
    mov [rax], rbx
    invlpg [0x400000]

    ; the mapping has to follow a write made two levels deep
    mov r12d, [0x400000]                    ; -> 0xcafef00d

    hlt

%include "long-mode-epilogue.inc"
