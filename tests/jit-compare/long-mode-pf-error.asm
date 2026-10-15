; The error code a page fault pushes, which is the only thing the guest's handler has to go on.
;
; Windows reads all five bits and branches on them: present says whether the mapping exists or the
; address is simply not there, write and user say what the access was, reserved says the entry is
; malformed rather than absent, and instruction-fetch says the fault was nx. Getting one wrong
; sends the memory manager down the wrong path with no complaint - a demand page treated as a
; protection violation, or an nx violation treated as a page that needs to be faulted in.
;
; Five faults are taken here and each error code recorded, along with cr2, in a table the handler
; keeps. The handler does not repair anything: each test leaves the address it wants to resume at
; in r15, which the handler stores over the frame's rip, so a fault that the architecture would
; restart forever runs exactly once.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x8000

    ; an idt whose entry for #pf (vector 14) points at the handler below
    mov rax, handler
    mov word [0x20000 + 14*16 + 0], ax          ; offset 15:0
    mov word [0x20000 + 14*16 + 2], 0x08        ; selector, the 64-bit code segment
    mov byte [0x20000 + 14*16 + 4], 0           ; ist 0
    mov byte [0x20000 + 14*16 + 5], 0x8E        ; present, dpl 0, interrupt gate
    shr rax, 16
    mov word [0x20000 + 14*16 + 6], ax          ; offset 31:16
    shr rax, 16
    mov dword [0x20000 + 14*16 + 8], eax        ; offset 63:32
    lidt [idtr64]

    ; A page table for virtual 0x400000 onwards, which is the pd entry after the large page the
    ; prologue mapped. Four entries, each malformed in a different way.
    mov qword [0x12000 + 2*8], 0x13000 | 3
    mov qword [0x13000 + 0*8], 0                ; 0x400000: not present at all
    mov qword [0x13000 + 1*8], 0x31000 | 1      ; 0x401000: present, read only
    mov rax, 0x32000 | 3
    bts rax, 63                                 ; nx
    mov qword [0x13000 + 2*8], rax              ; 0x402000: present, no execute
    mov rax, 0x33000 | 3
    bts rax, 63                                 ; the same bit, which is reserved while nxe is off
    mov qword [0x13000 + 3*8], rax              ; 0x403000

    ; An unwritten slot reads back as this, so a fault that never happened cannot be mistaken for
    ; an error code of zero - which is what the first test expects.
    mov rax, 0xFF
    mov [0x30000 + 0*8], rax
    mov [0x30000 + 1*8], rax
    mov [0x30000 + 2*8], rax
    mov [0x30000 + 3*8], rax
    mov [0x30000 + 4*8], rax

    xor rbx, rbx                                ; how many faults the handler has seen

    ; Without cr0.wp a supervisor write to a read only page is allowed, so the read only test needs
    ; it set. Windows runs with it set.
    mov rax, cr0
    or rax, 1 << 16                             ; cr0.wp
    mov cr0, rax

    ; 1: read an address with no mapping. Nothing is present, so no bit is set.
    mov r15, t2
    mov eax, [0x400000]
t2:
    ; 2: write the same address. Still absent, and now the write bit.
    mov r15, t3
    mov dword [0x400000], 1
t3:
    ; 3: write a present read only page. Present and write, and not reserved: the entry is fine,
    ; the access is not.
    mov r15, t4
    mov dword [0x401000], 1
t4:
    ; 4: execute from an nx page, with nxe on so that bit 63 means no execute rather than being
    ; reserved. Present and instruction fetch.
    mov ecx, 0xC0000080                         ; ia32_efer
    rdmsr
    or eax, 1 << 11                             ; nxe
    wrmsr
    mov r15, t5
    mov rax, 0x402000
    jmp rax
t5:
    ; 5: read an entry with bit 63 set while nxe is off, which makes it malformed rather than
    ; absent. Present and reserved, and no instruction fetch bit: the access was a read, and with
    ; nxe off there is no nx to violate.
    mov ecx, 0xC0000080
    rdmsr
    and eax, ~(1 << 11)                         ; nxe off
    wrmsr
    mov r15, t6
    mov eax, [0x403000]
t6:
    mov r8,  [0x30000 + 0*8]
    mov r9,  [0x30000 + 1*8]
    mov r10, [0x30000 + 2*8]
    mov r11, [0x30000 + 3*8]
    mov r12, [0x30000 + 4*8]
    mov r13, [0x30100 + 4*8]                    ; cr2 of the last fault
    mov r14, rbx                                ; and how many there were
    hlt

; The frame of a fault with an error code is the code, then rip, cs, rflags, rsp, ss. The error
; code has to come off before iret, which expects rip where the code is.
handler:
    mov rax, [rsp]
    mov [0x30000 + rbx*8], rax
    mov rax, cr2
    mov [0x30100 + rbx*8], rax
    inc rbx
    mov [rsp+8], r15
    add rsp, 8
    o64 iret

align 8
idtr64:
    dw 256*16 - 1
    dq 0x20000

%include "long-mode-epilogue.inc"
