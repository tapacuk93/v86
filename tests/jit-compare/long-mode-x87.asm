; The x87 escapes in 64-bit mode, with their operands above 4 GiB.
;
; The 64-bit table had no fpu opcodes at all, and the 32-bit implementations cannot be delegated to
; because every one of them takes an i32 address. Windows initialises the fpu as it starts each
; processor, so a 64-bit boot reaches these the moment the kernel itself begins running - which is
; exactly where it stopped.
;
; Every operand below is reached through a virtual address at 517 GiB and checked through the
; identity mapping of the same page.
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

    mov rbx, HIGH_VA                        ; the operands, written through here
    mov rsi, 0x8000                         ; and checked through here

    ; fnstcw: the control word at reset
    fnstcw [rbx]
    movzx r8, word [rsi]                    ; -> 37f

    ; fldcw then fnstcw: what a kernel does to set rounding and the exception masks
    mov word [rsi], 0x027F
    fldcw [rbx]
    mov word [rsi], 0
    fnstcw [rbx]
    movzx r9, word [rsi]                    ; -> 27f

    ; fld and fstp at double precision
    mov rax, 0x3FF0000000000000             ; 1.0
    mov [rsi], rax
    fld qword [rbx]
    fstp qword [rbx + 8]
    mov r10, [rsi + 8]                      ; -> 3ff0000000000000

    ; fild and fistp, the integer pair
    mov dword [rsi], 12345
    fild dword [rbx]
    fistp dword [rbx + 8]
    mov r11d, [rsi + 8]                     ; -> 3039

    ; and an arithmetic escape whose operand is in memory: 1.0 + 2.0
    mov rax, 0x3FF0000000000000
    mov [rsi], rax
    mov rax, 0x4000000000000000             ; 2.0
    mov [rsi + 8], rax
    fld qword [rbx]
    fadd qword [rbx + 8]
    fstp qword [rbx + 16]
    mov r12, [rsi + 16]                     ; -> 4008000000000000, which is 3.0

    hlt

%include "long-mode-epilogue.inc"
