; ret imm16, which takes the return address and then drops the caller's arguments.
;
; The immediate is read before the pop rather than after, so that a fault taking the return address
; leaves rsp where it was rather than half adjusted.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x7000

    ; two argument slots the callee will drop on its way out
    mov rax, 0x1111
    push rax
    push rax
    call target
    mov r8, rsp                 ; -> 7000, both slots gone along with the return address
    mov r9, 0x600d              ; -> reached, so the return went where it should have
    hlt

target:
    ret 0x10

%include "long-mode-epilogue.inc"
