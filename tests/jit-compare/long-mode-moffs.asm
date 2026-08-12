; mov between the accumulator and an absolute address. The address is carried in the instruction
; with no modrm and no base register, and in 64-bit mode it is a full 64 bits wide rather than the
; 32 the same opcodes take below - so these cannot be reached through the modrm path at all.
;
; Windows writes its real mode thunk's parameter block through them, at an address it knows before
; it has a register to spare for it.
;
; Each size is here because each stores a different number of bytes, and a store that is too wide
; is invisible in the value it wrote: the byte and word cases leave a known value in the bytes
; around the destination, and the load cases read back a wider field than they asked for.
;
; Expected values measured on a real x86-64; see long-mode-moffs-oracle.c.
%include "long-mode.inc"

BITS 64
DEFAULT ABS                     ; the addresses below are absolute, not rip relative
long_mode:
    mov rsp, 0x7000

    ; the fill that the narrower stores have to leave behind
    mov rax, 0xEEEEEEEEEEEEEEEE
    mov rdi, 0x7100
    mov [rdi], rax
    mov [rdi + 8], rax

    ; mov moffs64, rax - the whole register, to an address with no register behind it
    mov rax, 0x1122334455667788
    mov [qword 0x7100], rax
    mov r8, [rdi]               ; -> 1122334455667788

    ; mov moffs32, eax stores four bytes and zero extends nothing above them
    mov rax, 0xEEEEEEEEEEEEEEEE
    mov [rdi + 8], rax
    mov rax, 0x99999999AABBCCDD
    mov [qword 0x7108], eax
    mov r9, [rdi + 8]           ; -> eeeeeeeeaabbccdd

    ; mov moffs8, al reaches one byte
    mov rax, 0xEEEEEEEEEEEEEEEE
    mov [rdi + 8], rax
    mov al, 0x5A
    mov [qword 0x7108], al
    mov r10, [rdi + 8]          ; -> eeeeeeeeeeeeee5a

    ; and the loads, from a qword whose halves differ so a wrong width shows
    mov rax, 0x0102030405060708
    mov [rdi], rax

    xor rax, rax
    mov rax, [qword 0x7100]
    mov r11, rax                ; -> 0102030405060708

    mov rax, 0xFFFFFFFFFFFFFFFF
    mov eax, [qword 0x7100]     ; a 32-bit load clears the top half of rax
    mov r12, rax                ; -> 0000000005060708

    mov rax, 0xFFFFFFFFFFFFFFFF
    mov al, [qword 0x7100]       ; and a byte load leaves everything above it alone
    mov r13, rax                ; -> ffffffffffffff08

    hlt

%include "long-mode-epilogue.inc"
