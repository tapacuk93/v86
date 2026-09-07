; Every general register, and the flags, survive an interrupt and the iretq that returns from it.
;
; The other interrupt fixtures check the frame the cpu builds - which selectors and pointers land on
; the stack, and which stack they land on. None of them checks the thing every guest silently
; depends on: that the sixteen registers come back exactly as they were.
;
; That matters more than it sounds. A kernel takes an interrupt between any two instructions, so a
; register the emulator disturbs there becomes a wrong value inside code that never went near an
; interrupt. Windows then saves the disturbed set into a trap frame and copies it into a CONTEXT,
; where it surfaces much later, somewhere else, as a bad pointer or a bad count - and nothing about
; the eventual failure points back here.
;
; The handler does nothing but return, and writes its marker with an immediate to an absolute
; address so that it needs no register to do it. Anything that differs afterwards is the cpu's.

%define IDT     0x9000
%define KSTACK  0x6000
%define BUF     0xA000

%include "long-mode.inc"

BITS 64
DEFAULT ABS

; vector, handler
%macro SET_GATE 2
    mov rdi, IDT + (%1 * 16)
    mov rax, %2
    mov [rdi], ax                           ; offset 15:0
    mov word [rdi + 2], 0x08                ; the ring 0 code selector
    mov byte [rdi + 4], 0                   ; no ist
    mov byte [rdi + 5], 0x8E                ; present, dpl 0, 64-bit interrupt gate
    shr rax, 16
    mov [rdi + 6], ax                       ; offset 31:16
    shr rax, 16
    mov [rdi + 8], eax                      ; offset 63:32
    mov dword [rdi + 12], 0
%endmacro

; slot in BUF, the value it should hold. rax is scratch: it has already been saved.
%macro CHECK 2
    mov rax, %2
    cmp [BUF + %1], rax
    je %%ok
    inc r8
%%ok:
%endmacro

long_mode:
    mov rsp, KSTACK

    mov rdi, IDT
    mov rcx, 0x1000 / 8
    xor rax, rax
    rep stosq
    SET_GATE 0x40, handler
    SET_GATE 0x0D, gp_handler
    lidt [idtr]

    mov byte [BUF + 0x88], 0                ; the handlers' markers, neither run yet
    mov byte [BUF + 0x8a], 0

    ; Sixteen values that are all different, all wider than 32 bits, and none of which is what
    ; another becomes when truncated or sign extended - so a register that comes back holding the
    ; wrong thing says which one it got.
    mov rax, 0x1000000000000001
    mov rcx, 0x2000000000000002
    mov rdx, 0x3000000000000003
    mov rbx, 0x4000000000000004
    mov rbp, 0x6000000000000006
    mov rsi, 0x7000000000000007
    mov rdi, 0x8000000000000008
    mov r8,  0x9000000000000009
    mov r9,  0xa00000000000000a
    mov r10, 0xb00000000000000b
    mov r11, 0xc00000000000000c
    mov r12, 0xd00000000000000d
    mov r13, 0xe00000000000000e
    mov r14, 0xf00000000000000f
    mov r15, 0x1100000000000011

    mov [BUF + 0x80], rsp                   ; where rsp should be again afterwards
    stc                                     ; a flag the return has to bring back

    int 0x40

    ; Store the whole set before anything below disturbs it. Absolute addressing takes no base
    ; register, so nothing is clobbered on the way to memory.
    mov [BUF + 0x00], rax
    mov [BUF + 0x08], rcx
    mov [BUF + 0x10], rdx
    mov [BUF + 0x18], rbx
    mov [BUF + 0x20], rsp
    mov [BUF + 0x28], rbp
    mov [BUF + 0x30], rsi
    mov [BUF + 0x38], rdi
    mov [BUF + 0x40], r8
    mov [BUF + 0x48], r9
    mov [BUF + 0x50], r10
    mov [BUF + 0x58], r11
    mov [BUF + 0x60], r12
    mov [BUF + 0x68], r13
    mov [BUF + 0x70], r14
    mov [BUF + 0x78], r15
    setc [BUF + 0x89]                       ; and carry, which iretq restores with the flags

    xor r8, r8                              ; how many came back wrong
    CHECK 0x00, 0x1000000000000001
    CHECK 0x08, 0x2000000000000002
    CHECK 0x10, 0x3000000000000003
    CHECK 0x18, 0x4000000000000004
    CHECK 0x28, 0x6000000000000006
    CHECK 0x30, 0x7000000000000007
    CHECK 0x38, 0x8000000000000008
    CHECK 0x40, 0x9000000000000009
    CHECK 0x48, 0xa00000000000000a
    CHECK 0x50, 0xb00000000000000b
    CHECK 0x58, 0xc00000000000000c
    CHECK 0x60, 0xd00000000000000d
    CHECK 0x68, 0xe00000000000000e
    CHECK 0x70, 0xf00000000000000f
    CHECK 0x78, 0x1100000000000011

    ; rsp is the one the interrupt is entitled to move, and the one iretq has to put back
    mov rax, [BUF + 0x80]
    cmp [BUF + 0x20], rax
    je .rsp_ok
    inc r8
.rsp_ok:

    movzx r9, byte [BUF + 0x88]             ; -> 1, the handler ran
    movzx r10, byte [BUF + 0x89]            ; -> 1, carry came back

    ; The same again through a fault that carries an error code, which is a different frame - one
    ; slot longer - and a different path through the emulator. The address below is the one windows
    ; was seen faulting on: bits 63:48 are 0xfeff where bit 47 is set, so it is in the hole between
    ; the halves and referencing it is #gp(0), not a page fault.
    mov rax, 0x1000000000000001
    mov rcx, 0x2000000000000002
    mov rdx, 0x3000000000000003
    mov rbx, 0x4000000000000004
    mov rbp, 0x6000000000000006
    mov rsi, 0xfeffffffffffffff
    mov rdi, 0x8000000000000008
    mov r11, 0xc00000000000000c
    mov r12, 0xd00000000000000d
    mov r13, 0xe00000000000000e
    mov r14, 0xf00000000000000f
    mov [BUF + 0x80], rsp

    mov rax, [rsi]                          ; #gp: the load never happens, so rax survives
after_gp:
    mov [BUF + 0x00], rax
    mov [BUF + 0x08], rcx
    mov [BUF + 0x10], rdx
    mov [BUF + 0x18], rbx
    mov [BUF + 0x20], rsp
    mov [BUF + 0x28], rbp
    mov [BUF + 0x30], rsi
    mov [BUF + 0x38], rdi
    mov [BUF + 0x58], r11
    mov [BUF + 0x60], r12
    mov [BUF + 0x68], r13
    mov [BUF + 0x70], r14

    CHECK 0x00, 0x1000000000000001
    CHECK 0x08, 0x2000000000000002
    CHECK 0x10, 0x3000000000000003
    CHECK 0x18, 0x4000000000000004
    CHECK 0x28, 0x6000000000000006
    CHECK 0x30, 0xfeffffffffffffff
    CHECK 0x38, 0x8000000000000008
    CHECK 0x58, 0xc00000000000000c
    CHECK 0x60, 0xd00000000000000d
    CHECK 0x68, 0xe00000000000000e
    CHECK 0x70, 0xf00000000000000f

    mov rax, [BUF + 0x80]
    cmp [BUF + 0x20], rax                   ; rsp again, across the longer frame
    je .gp_rsp_ok
    inc r8
.gp_rsp_ok:
    movzx r11, byte [BUF + 0x8a]            ; -> 1, the fault handler ran

    ; The arithmetic flags, all of them rather than just carry. This emulator works them out lazily
    ; from the last operation rather than storing them, so what an interrupt has to preserve is not
    ; a register but a promise to recompute the same answer afterwards - and the frame carries the
    ; materialised flags while the promise stays behind in the interrupted code.
    mov rax, 0x7fffffffffffffff
    add rax, 1                              ; of and sf set, zf clear, cf clear, af set
    pushfq
    pop r12
    int 0x40
    pushfq
    pop rax
    xor rax, r12
    and rax, 0x8d5                          ; cf, pf, af, zf, sf, of
    mov r13, rax                            ; -> 0, every arithmetic flag came back

    ; And the vector registers, which windows uses for almost every copy and compare, so a thread
    ; switch that lost one would show up as arithmetic quietly going wrong rather than as a fault.
    mov rax, 0x0f1e2d3c4b5a6978
    movq xmm0, rax
    mov rax, 0x1122334455667788
    movq xmm8, rax
    mov rax, 0x99aabbccddeeff00
    movq xmm15, rax

    int 0x40

    movq rax, xmm0
    mov rcx, 0x0f1e2d3c4b5a6978
    cmp rax, rcx
    je .x0
    inc r8
.x0:
    movq rax, xmm8
    mov rcx, 0x1122334455667788
    cmp rax, rcx
    je .x8
    inc r8
.x8:
    movq rax, xmm15
    mov rcx, 0x99aabbccddeeff00
    cmp rax, rcx
    je .x15
    inc r8
.x15:

    hlt

handler:
    mov byte [BUF + 0x88], 1
    iretq

; The faulting instruction would run again on return, so the handler moves the return address past
; it. The frame here is one slot longer than the one above: the error code sits below rip.
gp_handler:
    mov byte [BUF + 0x8a], 1
    mov qword [rsp + 8], after_gp
    add rsp, 8                              ; drop the error code
    iretq

idtr:
    dw 0x1000 - 1
    dq IDT

%include "long-mode-epilogue.inc"
