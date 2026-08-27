; cmpxchg16b, and the two flag moves 64-bit mode keeps.
;
; cmpxchg16b is not a wider cmpxchg8b but a separate instruction sharing the opcode, selected by
; rex.w. Windows 8 and later check cpuid for it before they will boot at all, and build their
; interlocked list operations out of it, so it has to be both implemented and advertised.
;
; sahf and lahf are here because 64-bit mode keeps them only conditionally, on the lahf_lm cpuid
; bit, and it would be easy to leave them out of the 64-bit table by accident - which is what had
; happened.
;
; Expected values measured against the architecture: both the matching and the failing case, since
; a failing cmpxchg is the one that writes rdx:rax back and the one an implementation is most
; likely to get wrong.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; the destination pair
    mov rdi, 0x7100
    mov rax, 0x1111111122222222
    mov [rdi], rax
    mov rax, 0x3333333344444444
    mov [rdi + 8], rax

    ; a compare that does not match: zf clear, and rdx:rax take what was there
    mov rax, 0xDEADBEEFDEADBEEF
    mov rdx, 0xFEEDFACEFEEDFACE
    mov rbx, 0x5555555555555555
    mov rcx, 0x6666666666666666
    cmpxchg16b [rdi]
    setnz r8b                               ; -> 1, the compare failed
    movzx r8, r8b
    mov r9, rax                             ; -> 1111111122222222, loaded from memory
    mov r10, rdx                            ; -> 3333333344444444

    ; rax and rdx now hold what is there, so the same compare matches
    cmpxchg16b [rdi]
    setz r12b                               ; -> 1
    movzx r12, r12b
    mov r13, [rdi]                          ; -> 5555555555555555, rbx was swapped in
    mov r14, [rdi + 8]                      ; -> 6666666666666666, and rcx

    ; sahf takes the low byte of the flags from ah, lahf puts it back. Bit 1 always reads set.
    mov ah, 0xD5                            ; every flag sahf can set
    sahf
    lahf
    movzx eax, ah                           ; ah is unreachable from an instruction carrying rex,
    mov r15, rax                            ; so it goes through eax -> d7

    hlt

%include "long-mode-epilogue.inc"
