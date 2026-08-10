; A virtual address above 4 GiB, which is what windows runs its kernel at.
;
; v86 held virtual addresses in an i32 and indexed its tlb directly by page number, so only the low
; 4 GiB of the canonical address space could be named at all - and the page walk assumed the pml4
; index was therefore always zero. This fixture uses a non-zero pml4 index and an address that does
; not fit in 32 bits, so it exercises both.
;
; The high address is mapped onto a physical page the prologue's identity mapping also covers, so
; the same page can be reached two ways and the two views must agree.
;
; Table addresses are loaded into a register rather than written as absolute displacements: in
; 64-bit mode a bare [0x1234] is ambiguous between rip relative and absolute, and nasm resolves it
; with a warning rather than an error. The tables themselves need no zeroing, since the harness
; starts every run from a freshly zeroed 8 MiB and only the prologue has written anything.
;
; Tables, above the three the prologue builds at 0x10000..0x13000:
;   0x13000  pdpt for the high address, entry 5
;   0x14000  page directory
;   0x15000  page table, whose entries point at physical 0x8000 and 0x9000
%include "long-mode.inc"

; 517 GiB. The indices matter as much as the size: pml4 index 1 and pdpt index 5, where the pdpt
; index is the one that would be lost by truncating the address to 32 bits - bits 38:30 of it live
; partly above the boundary, and truncation turns index 5 into index 1. An address whose pdpt index
; happens to survive truncation passes this test either way, so it would not be a test at all.
HIGH_VA equ 0x8140000000

BITS 64
long_mode:
    mov rsp, 0x7000             ; clear of the pages this writes through

    mov rdi, 0x10000 + 1 * 8    ; pml4[1] -> pdpt
    mov dword [rdi], 0x13000 | 3
    mov rdi, 0x13000 + 5 * 8    ; pdpt[5] -> pd
    mov dword [rdi], 0x14000 | 3
    mov rdi, 0x14000            ; pd[0] -> pt
    mov dword [rdi], 0x15000 | 3
    mov rdi, 0x15000            ; pt[0] -> physical 0x8000
    mov dword [rdi], 0x8000 | 3

    ; the tables were built after paging was already on, so drop whatever the tlb cached
    mov rax, cr3
    mov cr3, rax

    ; write through the high address, read back through the identity mapping
    mov rbx, HIGH_VA
    mov dword [rbx], 0xdeadbeef
    mov rsi, 0x8000
    mov r8d, [rsi]              ; -> 0xdeadbeef, the same page seen low
    mov r9d, [rbx]              ; -> 0xdeadbeef, read back through the high address

    ; a second page under the same pml4 entry, to show the walk is not a one-off
    mov rdi, 0x15008            ; pt[1] -> physical 0x9000
    mov dword [rdi], 0x9000 | 3
    mov rax, cr3
    mov cr3, rax

    mov rcx, HIGH_VA + 0x1000
    mov dword [rcx], 0x600d600d
    mov rsi, 0x9000
    mov r10d, [rsi]             ; -> 0x600d600d
    mov rsi, 0x8000
    mov r11d, [rsi]             ; -> 0xdeadbeef, the first page left as it was

    ; a 128-bit sse access through the high address, which is the shape windows zeroes memory
    ; with. This is a separate matter from the walk above: the operand is resolved at full width
    ; but the access itself has to be too, and delegating it to a 32-bit implementation would
    ; truncate the address back down.
    mov rdx, 0x0123456789abcdef
    movq xmm0, rdx
    movlhps xmm0, xmm0
    movups [rbx], xmm0          ; store sixteen bytes through the high address
    mov rsi, 0x8000
    mov r12, [rsi]              ; -> 0123456789abcdef, seen through the identity mapping
    mov r13, [rsi + 8]          ; -> 0123456789abcdef, the half movlhps filled
    movups xmm1, [rbx]          ; and load it back through the high address
    movq r14, xmm1              ; -> 0123456789abcdef

    hlt

%include "long-mode-epilogue.inc"
