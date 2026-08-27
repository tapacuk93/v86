; lgdt and lidt with a base above 4 GiB.
;
; v86 held the descriptor table bases in an i32, and the 64-bit lgdt truncated what it read. That
; is exactly what a 64-bit kernel does not survive: it builds its gdt and idt in the high half of
; the address space, and a truncated base points at nothing. It is the instruction a Windows boot
; stops on once everything before it works.
;
; The table here is placed at a high virtual address that maps onto a page the prologue's identity
; mapping also covers, so it can be written through the low view and then reached only through the
; high one. A segment is loaded from it and its base checked, which is the part that proves the
; descriptor was actually read through the high address rather than the base merely stored.
;
; Tables above the three the prologue builds at 0x10000..0x13000:
;   0x13000  pdpt for the high address, entry 5
;   0x14000  page directory
;   0x15000  page table, pointing at physical 0x8000
%include "long-mode.inc"

HIGH_VA equ 0x8140000000

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    mov rdi, 0x10000 + 1 * 8                ; pml4[1] -> pdpt
    mov dword [rdi], 0x13000 | 3
    mov rdi, 0x13000 + 5 * 8                ; pdpt[5] -> pd
    mov dword [rdi], 0x14000 | 3
    mov rdi, 0x14000                        ; pd[0] -> pt
    mov dword [rdi], 0x15000 | 3
    mov rdi, 0x15000                        ; pt[0] -> physical 0x8000
    mov dword [rdi], 0x8000 | 3
    mov rax, cr3
    mov cr3, rax

    ; build a gdt through the identity mapping, to be reached only through the high one
    mov rsi, 0x8000
    xor rax, rax
    mov [rsi], rax                          ; 0x00 null
    mov rax, 0x00209A0000000000
    mov [rsi + 8], rax                      ; 0x08 64-bit code
    mov rax, 0x00CF92001234FFFF
    mov [rsi + 16], rax                     ; 0x10 data, base 0x1234

    ; a pseudo descriptor whose base is eight bytes wide, as it is in long mode
    mov rdi, 0x7300
    mov word [rdi], 0x17                    ; three entries, twenty-four bytes less one
    mov rax, HIGH_VA
    mov [rdi + 2], rax
    lgdt [rdi]

    ; loading fs reads the descriptor through the high address, and its base is one long mode keeps
    mov ax, 0x10
    mov fs, ax
    mov ecx, 0xC0000100                     ; ia32_fs_base
    rdmsr
    shl rdx, 32
    or rax, rdx
    mov r8, rax                             ; -> 1234

    ; and the base reads back at full width
    mov rdi, 0x7400
    sgdt [rdi]
    movzx r9, word [rdi]                    ; -> 17
    mov r10, [rdi + 2]                      ; -> 8140000000

    ; the same for the idt, which is only stored and read back here - taking an interrupt through
    ; a high idt is what long-mode-ring3-interrupt is for
    mov rdi, 0x7300
    mov word [rdi], 0xFFF
    mov rax, HIGH_VA
    mov [rdi + 2], rax
    lidt [rdi]
    mov rdi, 0x7400
    sidt [rdi]
    movzx r11, word [rdi]                   ; -> fff
    mov r12, [rdi + 2]                      ; -> 8140000000

    hlt

%include "long-mode-epilogue.inc"
