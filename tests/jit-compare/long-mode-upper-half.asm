; A virtual address in the sign extended upper half of the canonical address space.
;
; Every existing high-address fixture here uses something like 0x8140000000, which is pml4 index 1
; - the *lower* half. A 64-bit kernel does not live there: windows runs at 0xfffff8xx_xxxxxxxx,
; which is pml4 index 496, and the top sixteen bits are all ones. So the half of the address space
; the whole exercise is about had no test at all.
;
; The address used is the shape of a real windows kernel address. It is mapped onto a page the
; prologue's identity mapping also covers, so the same bytes can be reached both ways and the two
; views must agree.
;
; Tables above the three the prologue builds at 0x10000..0x13000:
;   0x13000  pdpt   0x14000  page directory   0x15000  page table -> physical 0x8000
%include "long-mode.inc"

HIGH    equ 0xFFFFF80220A68000
PML4_I  equ (HIGH >> 39) & 0x1FF
PDPT_I  equ (HIGH >> 30) & 0x1FF
PD_I    equ (HIGH >> 21) & 0x1FF
PT_I    equ (HIGH >> 12) & 0x1FF

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    mov rdi, 0x10000 + PML4_I * 8
    mov dword [rdi], 0x13000 | 3
    mov rdi, 0x13000 + PDPT_I * 8
    mov dword [rdi], 0x14000 | 3
    mov rdi, 0x14000 + PD_I * 8
    mov dword [rdi], 0x15000 | 3
    mov rdi, 0x15000 + PT_I * 8
    mov dword [rdi], 0x8000 | 3
    mov rax, cr3
    mov cr3, rax

    mov rbx, HIGH
    mov rsi, 0x8000                         ; the same page through the identity mapping

    ; write high, read low
    mov rax, 0x1122334455667788
    mov [rbx], rax
    mov r8, [rsi]                           ; -> 1122334455667788

    ; write low, read high
    mov rax, 0x99AABBCCDDEEFF00
    mov [rsi + 8], rax
    mov r9, [rbx + 8]                       ; -> 99aabbccddeeff00

    ; and an eight byte read of a descriptor sized field, which is what a table walk does
    mov rax, 0x00CF92001234FFFF
    mov [rsi + 16], rax
    mov r10, [rbx + 16]                     ; -> cf92001234ffff

    ; the indices, so a failure says which level was wrong rather than just that it was
    mov r11, PML4_I                         ; -> 1f0
    mov r12, PDPT_I
    mov r13, PD_I
    mov r14, PT_I

    hlt

%include "long-mode-epilogue.inc"
