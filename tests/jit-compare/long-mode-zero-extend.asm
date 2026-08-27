; The instructions that report through eax and edx must clear the upper halves.
;
; In 64-bit mode every 32-bit write to a register clears the upper 32 bits. cpuid, rdtsc and rdmsr
; are delegated to their 32-bit implementations, which write through write_reg32 - and that leaves
; the upper half alone, because in 32-bit mode there is no upper half to speak of. The result is
; not a corrupted corner of the answer but a completely different, much larger number.
;
; Windows reads cpuid before it will boot, so this is not a corner.
;
; Each register is dirtied with a distinctive upper half first, and the check is that shifting the
; result down by 32 leaves nothing - which holds whatever the instruction actually returned.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; cpuid writes all four. eax is its input so it cannot be dirty going in; the other three can.
    mov rbx, 0xBBBBBBBB00000000
    mov rcx, 0xCCCCCCCC00000000
    mov rdx, 0xDDDDDDDD00000000
    mov eax, 0
    cpuid
    mov r8, rbx
    shr r8, 32                              ; -> 0
    mov r9, rcx
    shr r9, 32                              ; -> 0
    mov r10, rdx
    shr r10, 32                             ; -> 0

    ; rdtsc writes edx:eax, whatever the counter happens to be
    mov rax, 0xAAAAAAAA00000000
    mov rdx, 0xDDDDDDDD00000000
    rdtsc
    mov r11, rax
    shr r11, 32                             ; -> 0
    mov r12, rdx
    shr r12, 32                             ; -> 0

    ; rdmsr, where the value is one set here, so the whole register can be checked rather than
    ; just its upper half
    mov ecx, 0xC0000100                     ; ia32_fs_base
    mov eax, 0x1234
    xor edx, edx
    wrmsr
    mov rax, 0xAAAAAAAA00000000
    mov rdx, 0xDDDDDDDD00000000
    mov ecx, 0xC0000100
    rdmsr
    mov r13, rax                            ; -> 1234, not aaaaaaaa00001234
    mov r14, rdx                            ; -> 0

    hlt

%include "long-mode-epilogue.inc"
