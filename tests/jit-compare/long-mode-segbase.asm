; The fs and gs bases, which are the only segmentation long mode keeps.
;
; cs, ds, es and ss read as base zero in 64-bit mode however their descriptors are written, but fs
; and gs keep a base and it widens to 64 bits, held in IA32_FS_BASE and IA32_GS_BASE rather than in
; any descriptor. swapgs exchanges the active gs base with IA32_KERNEL_GS_BASE.
;
; This is not a corner: windows reaches its per-cpu block (the KPCR) through gs, and swaps the base
; on every interrupt and system call, so nothing past the kernel's first instructions runs without
; it.
;
; Covered here: the base reaching a modrm operand, a moffs operand and the source side of a string
; instruction; lea not taking it, since lea ignores a segment prefix; the pair that swapgs
; exchanges; and a base above 4 GiB surviving a round trip through wrmsr and rdmsr, which is the
; whole reason these are not kept in the i32 segment_offsets array.
;
; The expected values are derived rather than measured: wrmsr is ring 0, so the oracle the other
; fixtures use - running the same instructions natively in user space - cannot reach these.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; two blocks for the two bases to point at, each with a value the other does not have
    mov rdi, 0x7100
    mov rax, 0x1122334455667788
    mov [rdi], rax
    mov rdi, 0x7200
    mov rax, 0x99AABBCCDDEEFF00
    mov [rdi], rax

    mov ecx, 0xC0000101                     ; ia32_gs_base
    mov eax, 0x7100
    xor edx, edx
    wrmsr

    mov ecx, 0xC0000100                     ; ia32_fs_base
    mov eax, 0x7200
    xor edx, edx
    wrmsr

    ; a modrm operand with no base register: sib with base=101, which is where an absolute
    ; address in 64-bit mode ends up, plus the gs base
    mov r8, [gs:0]                          ; -> 1122334455667788
    mov r9, [fs:0]                          ; -> 99aabbccddeeff00

    ; lea computes the address and stops there; a segment prefix contributes nothing
    lea r10, [gs:0x10]                      ; -> 10

    ; the moffs form, which carries its address in the instruction and so does not pass through
    ; the modrm path at all
    mov rax, [gs:0]
    mov r11, rax                            ; -> 1122334455667788

    ; the source side of a string instruction takes the prefix; the destination side is es and
    ; cannot be overridden
    xor rsi, rsi
    gs lodsq                                ; reads gs:[0], leaves rsi at 8
    mov r12, rax                            ; -> 1122334455667788

    ; swapgs brings IA32_KERNEL_GS_BASE into use and puts the old base where it was
    mov ecx, 0xC0000102                     ; ia32_kernel_gs_base
    mov eax, 0x7200
    xor edx, edx
    wrmsr
    swapgs
    mov r13, [gs:0]                         ; -> 99aabbccddeeff00
    swapgs
    mov r14, [gs:0]                         ; -> 1122334455667788, the original base is back

    ; a base above 4 GiB, which is why these are not kept in the 32-bit segment base array. Only
    ; the low 2 MiB is mapped, so this is written and read back rather than dereferenced.
    mov ecx, 0xC0000101
    mov eax, 0x89ABCDEF
    mov edx, 0x01234567
    wrmsr
    xor eax, eax
    xor edx, edx
    rdmsr
    shl rdx, 32
    or rdx, rax
    mov r15, rdx                            ; -> 123456789abcdef

    hlt

%include "long-mode-epilogue.inc"
