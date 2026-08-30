; A tss above 4 GiB.
;
; Long mode's tss descriptor is sixteen bytes and carries a 64-bit base, but ltr truncated it and
; refused anything outside the low 4 GiB - and the interrupt stack lookup read the base back out of
; the 32-bit segment_offsets array. A kernel puts its tss in the high half of the address space
; along with everything else, so neither could work.
;
; The proof here is indirect and all the better for it: an ist vector switches the stack to a
; pointer that lives *inside* the tss, so landing on that stack means the descriptor's full base
; was kept and the tss was then read through it.
;
; Tables above the three the prologue builds at 0x10000..0x13000:
;   0x13000  pdpt for the high address, entry 5
;   0x14000  page directory
;   0x15000  page table, pointing at physical 0x8000
%include "long-mode.inc"

HIGH_VA  equ 0x8140000000                   ; where the tss is seen from
ISTSTACK equ 0x5000
IDT      equ 0x9000

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

    ; the tss, written through the identity mapping and reached only through the high one
    mov rdi, 0x8000
    mov rcx, 0x68 / 8
    xor rax, rax
    rep stosq
    mov qword [0x8000 + 0x24], ISTSTACK     ; ist1

    ; its descriptor, whose base is HIGH_VA spread over four fields
    mov rdi, gdt + 0x30
    mov word [rdi], 0x67                    ; limit
    mov word [rdi + 2], 0x0000              ; base 15:0
    mov byte [rdi + 4], 0x00                ; base 23:16
    mov byte [rdi + 5], 0x89                ; present, available 64-bit tss
    mov byte [rdi + 6], 0                   ; limit 19:16 and flags
    mov byte [rdi + 7], 0x40                ; base 31:24
    mov dword [rdi + 8], 0x81               ; base 63:32
    mov dword [rdi + 12], 0
    mov ax, 0x30
    ltr ax

    ; a gate that names ist1, so the stack switches whatever the privilege
    mov rdi, IDT + 0x40 * 16
    mov rax, ist_handler
    mov [rdi], ax
    mov word [rdi + 2], 0x08
    mov byte [rdi + 4], 1                   ; ist1
    mov byte [rdi + 5], 0x8E                ; present, dpl 0, 64-bit interrupt gate
    shr rax, 16
    mov [rdi + 6], ax
    shr rax, 16
    mov [rdi + 8], eax
    mov dword [rdi + 12], 0

    mov rdi, 0x7300
    mov word [rdi], 0xFFF
    mov rax, IDT
    mov [rdi + 2], rax
    lidt [rdi]

    xor r8, r8
    xor r9, r9
    int 0x40

ist_handler:
    mov rbx, rsp
    shr rbx, 8
    cmp rbx, (ISTSTACK >> 8) - 1
    sete r8b
    movzx r8, r8b                           ; -> 1, the stack came out of the high tss
    mov r9, 1                               ; -> 1, ltr accepted a base above 4 GiB at all
    hlt

align 8
gdt:
    dq 0                                    ; 0x00 null
    dq 0x00209A0000000000                   ; 0x08 64-bit code, dpl 0
    dq 0x0000920000000000                   ; 0x10 data, dpl 0
    dq 0
    dq 0
    dq 0
    dq 0                                    ; 0x30 tss descriptor, written at run time
    dq 0
gdt_end:
gdtr:
    dw gdt_end - gdt - 1
    dd gdt
