; crc32, the sse4.2 accumulator over the castagnoli polynomial.
;
; Checked against the published check value rather than against a restatement of the same loop:
; crc-32c of the nine bytes "123456789", seeded with all ones and inverted at the end, is
; 0xe3069283 in every table of these. That pins the polynomial, the bit order and the direction of
; the shift at once - get any of them wrong and it is not close.
;
; The 64-bit form is then checked against the byte form over the same eight bytes, which is what
; catches the operand width and the order the bytes are consumed in.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000
    mov rdi, 0x7100

    ; "123456789"
    mov rax, 0x3837363534333231
    mov [rdi], rax
    mov byte [rdi + 8], 0x39

    mov eax, 0xffffffff
    xor rcx, rcx
.check:
    crc32 eax, byte [rdi + rcx]
    inc rcx
    cmp rcx, 9
    jb .check
    not eax
    mov r8d, eax                            ; -> 0xe3069283

    ; the same eight bytes through the 64-bit form and through the byte form, from the same seed
    mov rax, 0x0123456789abcdef
    mov [rdi], rax
    mov rcx, 0xdeadbeef
    crc32 rcx, rax

    mov rdx, 0xdeadbeef
    xor rsi, rsi
.bytes:
    crc32 edx, byte [rdi + rsi]
    inc rsi
    cmp rsi, 8
    jb .bytes

    xor rcx, rdx
    mov r9, rcx                             ; -> 0, the two agree

    ; and the 64-bit destination form clears the upper half like any other 32-bit write
    mov r10, -1
    crc32 r10, rax
    shr r10, 32                             ; -> 0

    hlt

%include "long-mode-epilogue.inc"
