; rip relative addressing counts from the address of the *next* instruction, which is past any
; immediate the instruction carries. Getting that wrong shifts the access by the immediate's
; length, which is silent: it lands on a neighbouring variable instead of faulting.
;
; The slots below are adjacent, so a displacement that is four bytes short writes slot_a instead of
; slot_b and the difference is visible. Real labels are used rather than absolute addresses, since
; nasm only emits rip relative addressing for the former.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000

    ; mov dword [rip+disp], imm32 carries a four byte immediate after the displacement
    mov dword [rel slot_b], 0xaaaaaaaa
    mov eax, [rel slot_a]           ; -> 0x11111111, must be untouched
    mov ebx, [rel slot_b]           ; -> 0xaaaaaaaa, the intended slot
    mov ecx, [rel slot_c]           ; -> 0x33333333, must be untouched

    ; mov byte [rip+disp], imm8 carries a one byte immediate
    mov byte [rel byte_b], 0x99
    movzx edx, byte [rel byte_a]    ; -> 0x55, must be untouched
    movzx esi, byte [rel byte_b]    ; -> 0x99, the intended slot

    ; a plain rip relative load, no immediate, which was always correct and must stay so
    mov rdi, [rel qslot]            ; -> 0x123456789abcdef0

    ; and a rip relative read-modify-write with an immediate: add dword [rip+disp], imm8
    add dword [rel slot_c], 1       ; slot_c -> 0x33333334
    mov r9d, [rel slot_c]
    mov r10d, [rel slot_b]          ; -> 0xaaaaaaaa still, not incremented instead

    hlt

align 8
slot_a: dd 0x11111111
slot_b: dd 0x22222222
slot_c: dd 0x33333333
byte_a: db 0x55
byte_b: db 0x66
align 8
qslot:  dq 0x123456789abcdef0

%include "long-mode-epilogue.inc"
