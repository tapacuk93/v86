; Which paging entries the cpu writes back, and what it writes into them.
;
; Accessed says a translation went through this entry; dirty says the page it describes was
; written. Both are how a kernel decides what to reclaim: windows trims by age, and an entry that
; never records being used looks like one that can go. Dirty decides whether a page has to be
; written out before it is dropped, so a page that was written and does not say so is lost data.
;
; The rules are per level. Accessed belongs on every entry the walk went through, all four of them.
; Dirty belongs only on the entry that describes the page itself - the page table entry, or the
; page directory entry of a large page - and never on the levels above it, which describe tables
; rather than data and are not what was written.
;
; The test region hangs off pml4[1], with its own tables, so that nothing here shares a level with
; the identity mapping this code runs from - whose entries are marked accessed and dirty by the
; fixture's own instructions long before the first check.
;
;   0x14000  pdpt      0x15000  page directory      0x16000  page table
%include "long-mode.inc"

BASE equ 0x8000000000                       ; 1 << 39, the whole of pml4[1]

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    mov rdi, 0x14000
    mov rcx, 0x3000 / 8
    xor rax, rax
    rep stosq

    ; Present and writable, and nothing else: no accessed, no dirty. Anything found in them later
    ; was put there by the walk.
    mov qword [0x14000 + 0*8], 0x15000 | 3  ; pdpt[0] -> pd
    mov qword [0x15000 + 0*8], 0x16000 | 3  ; pd[0]   -> pt
    mov qword [0x16000 + 0*8], 0x30000 | 3  ; pt[0]   -> physical 0x30000
    mov qword [0x16000 + 1*8], 0x31000 | 3  ; pt[1]   -> physical 0x31000
    mov qword [0x15000 + 1*8], 0x200000 | 0x83  ; pd[1] -> a 2 MiB page at physical 0x200000
    mov qword [0x10000 + 1*8], 0x14000 | 3  ; pml4[1] -> pdpt

    mov rax, cr3
    mov cr3, rax                            ; nothing cached from before the entries existed

    ; a read, which should mark all four levels accessed and none of them dirty
    mov rax, BASE
    mov ebx, [rax]

    mov r8,  [0x10000 + 1*8]                ; pml4[1]
    mov r9,  [0x14000 + 0*8]                ; pdpt[0]
    mov r10, [0x15000 + 0*8]                ; pd[0]
    mov r11, [0x16000 + 0*8]                ; pt[0]

    ; a write through a second entry of the same page table, which is the only one of the four that
    ; should come back dirty
    mov rax, BASE + 0x1000
    mov dword [rax], 0x1234
    mov r12, [0x16000 + 1*8]                ; pt[1]

    ; the same question one level up: a large page's directory entry describes the page itself, so
    ; it takes dirty where a directory entry pointing at a table never would
    mov rax, BASE + 0x200000
    mov ebx, [rax]
    mov dword [rax], 0x5678
    mov r13, [0x15000 + 1*8]                ; pd[1], the large page

    ; and the level above it, which the large page's walk also went through, is accessed and still
    ; not dirty - two pages below it have now been written
    mov r14, [0x14000 + 0*8]                ; pdpt[0] again

    hlt

%include "long-mode-epilogue.inc"
