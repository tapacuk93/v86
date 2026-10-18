; The features this processor claims that were added to make it more like real hardware, each
; checked here as a claim and proved elsewhere as a behaviour.
;
; The two halves matter equally and are easy to let drift apart. A bit set without the instruction
; behind it is the worse direction - a guest uses a feature because the bit says it may, and finds
; nothing - and that is how the unsupported-processor bugcheck was reached once already. A working
; instruction with the bit clear is the other direction: harmless, and invisible, because nothing
; will ever use it.
;
; So: gigabyte pages are proved by long-mode-gigabyte-page, the fs and gs base instructions and
; rdtscp by long-mode-fsgsbase-rdtscp, and the invariant counter is a statement about this
; emulator rather than an instruction - the counter is derived from a monotonic source, has no
; power states to change rate with, and never stops.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; the extended leaves have to reach far enough for the two consulted below to exist
    mov eax, 0x80000000
    xor ecx, ecx
    cpuid
    cmp eax, 0x80000007
    setae r8b
    movzx r8, r8b                           ; -> 1

    mov eax, 0x80000001
    xor ecx, ecx
    cpuid
    mov r9d, edx
    shr r9d, 26
    and r9d, 1                              ; -> 1, gigabyte pages
    mov r10d, edx
    shr r10d, 27
    and r10d, 1                             ; -> 1, rdtscp

    ; fsgsbase lives in the leaf that holds everything newer than the original feature words
    mov eax, 7
    xor ecx, ecx
    cpuid
    mov r11d, ebx
    and r11d, 1                             ; -> 1, fsgsbase

    mov eax, 0x80000007
    xor ecx, ecx
    cpuid
    mov r12d, edx
    shr r12d, 8
    and r12d, 1                             ; -> 1, the counter runs at a constant rate

    ; And one the other way, to show the claims are not simply all ones: this processor has no
    ; three byte opcode families, so it does not claim sse4.1 either.
    mov eax, 1
    xor ecx, ecx
    cpuid
    mov r13d, ecx
    shr r13d, 19
    and r13d, 1                             ; -> 0, sse4.1 is not claimed

    ; Claiming a constant rate is not free: windows reads IA32_TSC_ADJUST as soon as it is told
    ; the counter has one, to check that nothing has shifted it. Reading an msr this emulator does
    ; not know is fatal, so the claim above and this register have to arrive together - which they
    ; did not, and a boot died at it.
    mov ecx, 0x3B
    rdmsr
    mov r14d, eax
    or r14d, edx                            ; -> 0, nothing has shifted the counter

    ; and it is a real register, not a hole that reads zero: what is written comes back
    mov ecx, 0x3B
    mov eax, 0x55667788
    mov edx, 0x11223344
    wrmsr
    mov ecx, 0x3B
    rdmsr
    shl rdx, 32
    or rdx, rax
    mov r15, rdx                            ; -> 0x1122334455667788

    hlt

%include "long-mode-epilogue.inc"
