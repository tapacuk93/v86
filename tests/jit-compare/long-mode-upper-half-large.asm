; A 2 MiB page in the sign extended upper half.
;
; Windows maps its kernel with large pages, and every kernel address is in the upper half - so the
; combination of the two is what a real boot spends all its time in, and neither the large page
; fixtures nor the high address ones covered it: the prologue's large page is at address zero, and
; the high address fixtures all use 4 KiB pages in the *lower* half.
;
; The page is mapped onto physical zero, which the prologue's identity mapping also covers, so the
; same bytes can be reached both ways and the two views must agree.
%include "long-mode.inc"

HIGH    equ 0xFFFFF80220A00000              ; 2 MiB aligned
PML4_I  equ (HIGH >> 39) & 0x1FF
PDPT_I  equ (HIGH >> 30) & 0x1FF
PD_I    equ (HIGH >> 21) & 0x1FF

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    mov rdi, 0x10000 + PML4_I * 8
    mov dword [rdi], 0x13000 | 3
    mov rdi, 0x13000 + PDPT_I * 8
    mov dword [rdi], 0x14000 | 3
    mov rdi, 0x14000 + PD_I * 8
    mov dword [rdi], 0x000000 | 0x83        ; a 2 MiB page at physical zero, present and writable
    mov rax, cr3
    mov cr3, rax

    mov rbx, HIGH
    mov rsi, 0                              ; the same two megabytes, identity mapped

    ; write high, read low, at an offset well inside the page
    mov rax, 0x1122334455667788
    mov [rbx + 0x8000], rax
    mov r8, [rsi + 0x8000]                  ; -> 1122334455667788

    ; write low, read high
    mov rax, 0x99AABBCCDDEEFF00
    mov [rsi + 0x8008], rax
    mov r9, [rbx + 0x8008]                  ; -> 99aabbccddeeff00

    ; and near the end of the page, where a wrong page size shows up as a wrong address
    mov rax, 0x0123456789ABCDEF
    mov [rbx + 0x1FFFF0], rax
    mov r10, [rsi + 0x1FFFF0]               ; -> 123456789abcdef

    mov r11, PD_I                           ; -> 105
    hlt

%include "long-mode-epilogue.inc"
