; A gigabyte page: the size bit at the page directory pointer level, which ends the walk two
; levels early instead of one.
;
; Kernels map physical memory with these - one entry where a thousand would otherwise be - so a
; guest that uses them at all uses them for everything it maps that way. Until now the walk
; asserted they did not exist, which turns a guest doing something ordinary into a dead emulator.
;
; Three things have to be right and are easy to get wrong separately: the walk has to stop at this
; level rather than read the entry below as if it were a table; thirty bits of the address are the
; offset within the page, not twenty-one; and the accessed and dirty bits belong on this entry,
; since no lower one was read.
;
; The page is based at physical zero, because that is the only gigabyte boundary a small machine
; has, and reached through a second pml4 entry so that nothing here disturbs the identity mapping
; the fixture's own code runs from.
%include "long-mode.inc"

BASE equ 0x8000000000                       ; pml4[1], and not sign extended: top index 1 is in
                                            ; the low half of the address space

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; one pdpt, whose first entry maps the whole first gigabyte
    mov rdi, 0x14000
    mov rcx, 0x1000 / 8
    xor rax, rax
    rep stosq
    mov qword [0x14000], 0x83               ; present, writable, and the size bit
    mov qword [0x10000 + 1*8], 0x14000 | 3  ; pml4[1] -> that pdpt

    ; The prologue identity maps only the first 2 MiB, and the far address below is outside it.
    ; A second large page puts it within reach of the identity mapping too, so that what is
    ; written there can be checked against what the gigabyte page reads.
    mov qword [0x12000 + 2*8], 0x400000 | 0x83

    mov rax, cr3
    mov cr3, rax                            ; nothing cached from before it existed

    ; something to find at two physical addresses, one of them far enough into the gigabyte to
    ; catch an offset computed with the wrong number of bits
    mov dword [0x30000], 0xDEADBEEF
    mov dword [0x400000], 0xCAFEF00D

    ; read both through the gigabyte page
    mov rax, BASE + 0x30000
    mov r8d, [rax]                          ; -> 0xdeadbeef
    mov rax, BASE + 0x400000
    mov r9d, [rax]                          ; -> 0xcafef00d

    ; the entry should now say it was used, and not yet written through
    mov r10, [0x14000]                      ; -> 0xa3: present, writable, size, accessed

    ; write through the page, and see it at the physical address
    mov rax, BASE + 0x31000
    mov dword [rax], 0x12345678
    mov r11d, [0x31000]                     ; -> 0x12345678

    ; and the write should have set dirty on the same entry
    mov r12, [0x14000]                      ; -> 0xe3, dirty as well

    ; the last page of the gigabyte is still inside it: offset 0x3ffff000 from a base of zero is
    ; physical 0x3ffff000, which this machine does not have, so only the arithmetic is checked -
    ; an offset masked to twenty-one bits would wrap to somewhere that does exist and read it
    mov rax, BASE + 0x3FFFF000
    mov rbx, rax
    shr rbx, 12
    and rbx, 0x3FFFF                        ; what the page number within the page should be
    mov r13, rbx                            ; -> 0x3ffff

    hlt

%include "long-mode-epilogue.inc"
