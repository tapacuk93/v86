; cr2 after a page fault at an address above 4 GiB.
;
; cr2 holds the linear address that faulted, and v86's control registers are an i32 array - so a
; fault in the high half of the address space reached the handler with the address truncated. The
; code even said so, on the grounds that nothing read it back. A 64-bit kernel reads cr2 in its
; page fault handler on every demand page, and its addresses are all in the high half.
;
; This maps one high page and deliberately leaves the next one unmapped, faults on it, and has the
; handler compare cr2 against the address it touched.
;
; Tables above the three the prologue builds at 0x10000..0x13000:
;   0x13000  pdpt for the high address, entry 5
;   0x14000  page directory
;   0x15000  page table: entry 0 mapped, entry 1 deliberately not
;   0x9000   idt
%include "long-mode.inc"

HIGH_VA   equ 0x8140000000
HIGH_GONE equ 0x8140001000
IDT       equ 0x9000

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
    mov rdi, 0x15000                        ; pt[0] -> physical 0x8000; pt[1] left zero
    mov dword [rdi], 0x8000 | 3
    mov rax, cr3
    mov cr3, rax

    ; an idt with a handler for #pf, which is vector 14
    mov rdi, IDT + 14 * 16
    mov rax, pf_handler
    mov [rdi], ax                           ; offset 15:0
    mov word [rdi + 2], 0x08                ; the ring 0 code selector
    mov byte [rdi + 4], 0                   ; no ist
    mov byte [rdi + 5], 0x8E                ; present, dpl 0, 64-bit interrupt gate
    shr rax, 16
    mov [rdi + 6], ax                       ; offset 31:16
    shr rax, 16
    mov [rdi + 8], eax                      ; offset 63:32
    mov dword [rdi + 12], 0

    mov rdi, 0x7300
    mov word [rdi], 0xFFF
    mov rax, IDT
    mov [rdi + 2], rax
    lidt [rdi]

    ; the mapped page works
    mov rbx, HIGH_VA
    mov dword [rbx], 0x1234
    mov r10d, [rbx]                         ; -> 1234

    ; and the next one faults
    mov rbx, HIGH_GONE
    mov eax, [rbx]                          ; #pf, which does not return here

pf_handler:
    mov rax, cr2
    mov r9, rax                             ; -> 8140001000, the address at full width
    mov rbx, HIGH_GONE
    cmp rax, rbx
    sete r8b
    movzx r8, r8b                           ; -> 1
    hlt

%include "long-mode-epilogue.inc"
