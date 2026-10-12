; The cpuid answers a 64-bit guest refuses to boot without.
;
; Every one of these cost a run to find, because the guest does not say which bit it wanted - it
; reads a leaf, decides the processor is unsuitable and stops, and the only evidence is a bugcheck
; code that names none of them. Windows checks most of leaf 1 in a single masked comparison, so a
; missing bit there is indistinguishable from any other missing bit.
;
; The widths in 0x80000008 matter for a different reason: windows reads them to find out where its
; address range ends, and four-level paging makes a linear address 48 bits wide whatever the
; physical memory behind it.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; leaf 1: the masked comparison windows makes. Machine check is in it, which is the one that
    ; looks least like a cpu feature and stopped the boot for longest.
    mov eax, 1
    xor ecx, ecx
    cpuid
    mov r8d, edx
    ; The mask windows requires, less bit 9. Apic is only advertised when acpi is enabled, which
    ; this harness does not do and a real boot does - so including it here would fail for a reason
    ; that has nothing to do with the processor.
    and r8d, 0x0789f1fd
    xor r8d, 0x0789f1fd                     ; -> 0 when every required bit is present
    mov r9d, ecx
    shr r9d, 13
    and r9d, 1                              ; -> 1, cmpxchg16b

    ; leaf 0x80000001: long mode itself, and the three windows 8.1 and later check for
    mov eax, 0x80000001
    xor ecx, ecx
    cpuid
    mov r10d, edx
    shr r10d, 29
    and r10d, 1                             ; -> 1, lm
    mov r11d, edx
    shr r11d, 11
    and r11d, 1                             ; -> 1, syscall
    mov r12d, edx
    shr r12d, 20
    and r12d, 1                             ; -> 1, nx
    mov r13d, ecx
    and r13d, 0x101                         ; -> 0x101, lahf and prefetchw

    ; and the address widths
    mov eax, 0x80000008
    xor ecx, ecx
    cpuid
    movzx r14, al                           ; -> 0x20, 32 physical address bits
    mov r15d, eax
    shr r15d, 8
    movzx r15, r15b                         ; -> 0x30, 48 linear address bits

    hlt

%include "long-mode-epilogue.inc"
