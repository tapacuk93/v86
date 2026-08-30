; The debug registers in long mode.
;
; dr0 to dr3 hold addresses and are 64 bits wide here. v86 keeps them in an i32 array, which made a
; read-back wrong and made writing a breakpoint above 4 GiB an assertion failure rather than a
; value - and nothing in the emulator acts on them, so it was taking itself down over a number it
; would never look at again.
;
; dr6 and dr7 are not addresses: their reserved bits read back fixed whatever is written.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; an address above 4 GiB, which is where a kernel's breakpoints would be
    mov rax, 0x8140001234
    mov dr0, rax
    xor rax, rax
    mov rax, dr0
    mov r8, rax                             ; -> 8140001234

    ; and one in the high half of the canonical address space
    mov rax, 0xFFFF800000001000
    mov dr3, rax
    xor rax, rax
    mov rax, dr3
    mov r9, rax                             ; -> ffff800000001000

    ; dr7's bit 10 always reads set
    mov rax, 0x400
    mov dr7, rax
    xor rax, rax
    mov rax, dr7
    mov r10, rax                            ; -> 400

    ; and dr6's reserved bits read back fixed even when zero is written
    xor rax, rax
    mov dr6, rax
    mov rax, dr6
    mov r11, rax                            ; -> ffff0ff0

    hlt

%include "long-mode-epilogue.inc"
