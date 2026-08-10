; The lock prefix and the fence group.
;
; Both order memory against other cpus, of which there are none here: one instruction runs at a
; time, so the atomicity lock asks for is already the case and the fences have nothing to order.
; That makes them no-ops - but only once they are decoded at all, and a prefix that is not
; recognised takes the opcode with it.
;
; Windows uses `lock or dword [rsp], 0` on a throwaway operand as a full barrier, which is how
; winload reached this: the operand is discarded but the instruction still has to execute.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x7000

    ; a locked read-modify-write still does the work, prefix or no prefix
    mov rax, 0x00000000f0f0f0f0
    mov [rsp], rax
    lock or dword [rsp], 0x0f
    mov r8, [rsp]               ; -> 00000000f0f0f0ff

    ; and one that returns a value, to show the prefix does not swallow the result
    mov rbx, 0x1111111111111111
    mov [rsp + 8], rbx
    mov rcx, 0x2222222222222222
    lock xadd [rsp + 8], rcx
    mov r9, [rsp + 8]           ; -> 3333333333333333, the sum
    mov r10, rcx                ; -> 1111111111111111, the old value

    ; the fences themselves, which must decode and do nothing
    lfence
    mfence
    sfence
    mov r11, 0x600d             ; -> reached, so none of them trapped

    hlt

%include "long-mode-epilogue.inc"
