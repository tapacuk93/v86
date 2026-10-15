; Two address spaces, and what a cr3 write has to do to the translations cached from the old one.
;
; A kernel switches address spaces constantly, and the same virtual address means different memory
; in each. The architecture makes a write to cr3 invalidate every cached translation except those
; whose page table entry has the global bit, so a mapping that differs between two spaces has to
; be re-walked after the switch. An emulator that keeps the old translation reads the old space's
; memory through the new space's address - and the guest sees a page whose contents belong to some
; other process, or a page table write that appears to have gone nowhere.
;
; Global entries are the exception, and the architecture gives only one way to be rid of them that
; is guaranteed rather than permitted: changing cr4.pge invalidates everything, global included.
; This fixture uses that rather than asserting that a global entry survives a cr3 write, which
; hardware may do and may not - a tlb is always allowed to drop an entry it has room for elsewhere.
BITS 32
    org 0x1000

    ; 0x10000 pml4 / 0x11000 pdpt / 0x12000 pd / 0x13000 pt   - space A
    ; 0x20000 pml4 / 0x21000 pdpt / 0x22000 pd / 0x23000 pt   - space B
    mov edi, 0x10000
    mov ecx, 0x14000 / 4
    xor eax, eax
    rep stosd

    ; Both spaces identity map the first 2 MiB with one large page, which is where this code and
    ; its stack live: the switch happens with the instruction pointer in that range, so it has to
    ; mean the same thing on both sides of the write to cr3.
    mov dword [0x10000], 0x11000 | 3
    mov dword [0x11000], 0x12000 | 3
    mov dword [0x12000], 0x00000000 | 0x83
    mov dword [0x12000 + 2*8], 0x13000 | 3

    mov dword [0x20000], 0x21000 | 3
    mov dword [0x21000], 0x22000 | 3
    mov dword [0x22000], 0x00000000 | 0x83
    mov dword [0x22000 + 2*8], 0x23000 | 3

    ; virtual 0x400000 is an ordinary mapping, and differs between the spaces
    mov dword [0x13000 + 0*8], 0x30000 | 3
    mov dword [0x23000 + 0*8], 0x31000 | 3

    ; virtual 0x401000 is a global one, and differs too. Global describes the entry, not the
    ; address, so nothing stops the two spaces from disagreeing about where it points.
    mov dword [0x13000 + 1*8], 0x32000 | 0x103
    mov dword [0x23000 + 1*8], 0x33000 | 0x103

    mov dword [0x30000], 0xDEADBEEF         ; what 0x400000 means in space A
    mov dword [0x31000], 0xCAFEF00D         ; and in space B
    mov dword [0x32000], 0x11111111         ; what 0x401000 means in space A
    mov dword [0x33000], 0x22222222         ; and in space B

    lgdt [gdtr]

    mov eax, 0x10000
    mov cr3, eax
    mov eax, cr4
    or eax, (1 << 5) | (1 << 7)             ; cr4.pae, cr4.pge - the global bit needs pge
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
    mov r14, 0x10000                        ; space A
    mov r15, 0x20000                        ; space B

    ; space A, both addresses, which caches a translation for each
    mov r8d,  [0x400000]                    ; -> 0xdeadbeef
    mov r9d,  [0x401000]                    ; -> 0x11111111

    ; switch to space B. The ordinary mapping must be re-walked and come back as B's page.
    mov cr3, r15
    mov r10d, [0x400000]                    ; -> 0xcafef00d

    ; The global one is the entry the switch was allowed to keep, so what it reads here is not
    ; something to assert. Toggling cr4.pge is the architectural way to drop it, and after that it
    ; has to be re-walked like any other and come back as B's page.
    mov rax, cr4
    and rax, ~(1 << 7)
    mov cr4, rax
    or rax, 1 << 7
    mov cr4, rax
    mov r11d, [0x401000]                    ; -> 0x22222222

    ; and back again, to show the first space's translations were not the ones kept
    mov cr3, r14
    mov r12d, [0x400000]                    ; -> 0xdeadbeef
    mov rax, cr4
    and rax, ~(1 << 7)
    mov cr4, rax
    or rax, 1 << 7
    mov cr4, rax
    mov r13d, [0x401000]                    ; -> 0x11111111

    hlt

%include "long-mode-epilogue.inc"
