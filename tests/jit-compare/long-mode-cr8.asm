; cr8, the task priority register.
;
; rex.r on `mov cr, r` selects cr8 rather than extending the register field, which is why the
; 64-bit table refused it: the control register number came out as 8 and nothing matched. cr8 is
; four bits wide and is the top nibble of the local apic's task priority register.
;
; Windows on x64 maps irql straight onto it - KeRaiseIrql and KeLowerIrql are a write to cr8 and
; nothing else - so the kernel reaches this within its first instructions, and it gates interrupt
; delivery while it is raised.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    mov rax, 0xD
    mov cr8, rax
    xor rax, rax
    mov rax, cr8
    mov r8, rax                             ; -> d

    ; the highest value it takes
    mov rax, 0xF
    mov cr8, rax
    mov rax, 0xFFFFFFFFFFFFFFFF             ; dirtied, so a read that merges rather than replaces shows
    mov rax, cr8
    mov r9, rax                             ; -> f

    ; and back to zero, which is the level everything is allowed to interrupt
    xor rax, rax
    mov cr8, rax
    mov rax, cr8
    mov r10, rax                            ; -> 0

    ; cr0 is still cr0: without rex.r the same opcode names it, and paging is on
    mov rax, cr0
    shr rax, 31
    and rax, 1
    mov r11, rax                            ; -> 1, cr0.pg

    hlt

%include "long-mode-epilogue.inc"
