; Read-modify-write with a memory operand and a displacement. Resolving the modrm twice - once to
; read and again to write back - consumes the displacement twice and leaves the decoder inside the
; next instruction, so what this really checks is that the instructions after it still execute.
%include "long-mode.inc"

BITS 64
long_mode:
    mov rsp, 0x8000
    mov rbp, 0x40000

    mov dword [rbp+0x17], 0x1000
    or  dword [rbp+0x17], 0x1a000       ; the shape that desynchronised the decoder
    mov eax, [rbp+0x17]                 ; expect 0x1b000

    mov qword [rbp+0x20], 0x100
    add qword [rbp+0x20], 0x23          ; 64-bit read modify write
    mov rbx, [rbp+0x20]                 ; expect 0x123

    mov dword [rbp+0x30], 8
    shl dword [rbp+0x30], 2             ; shift with a memory operand
    mov ecx, [rbp+0x30]                 ; expect 0x20

    mov dword [rbp+0x40], 5
    neg dword [rbp+0x40]                ; group 3 with a memory operand
    mov edx, [rbp+0x40]                 ; expect -5

    ; if any of the above consumed the wrong number of bytes, this marker never runs
    mov r15, 0x600DF00D

    hlt

%include "long-mode-epilogue.inc"
