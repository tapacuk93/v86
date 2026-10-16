; The scalar conversions between an integer register and a float.
;
; cvtsi2ss and cvtsi2sd go one way, cvttss2si/cvttsd2si and cvtss2si/cvtsd2si come back - the
; first pair truncating, the second rounding the way mxcsr says, which by default is to nearest
; with ties to even. Compiled floating point code is full of them at every boundary where a number
; stops being an integer or starts being one again.
;
; What makes them their own shape is that rex.w widens the *integer* side rather than the float
; one: the float side is chosen by the f3 or f2 prefix. So cvtsi2sd takes a 32-bit source without
; rex.w and a 64-bit one with it, and cvttsd2si writes a 32-bit register or a 64-bit one from the
; same 64-bit double. A 32-bit implementation cannot express either half of that.
;
; Out of range is the other thing worth pinning down: x86 does not wrap. A nan, an infinity or
; anything past the destination's range gives the "integer indefinite" value, which is the most
; negative integer of that width - and the width is the destination register's, not the source's.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; cvtsi2sd with a 64-bit integer source
    mov rax, 2
    cvtsi2sd xmm0, rax
    movq r8, xmm0                           ; -> 2.0

    ; cvtsi2ss with a 64-bit integer source, which writes only the low 32 bits of the register
    mov rax, 2
    cvtsi2ss xmm1, rax
    movd r9d, xmm1                          ; -> 2.0f

    ; cvtsi2sd with a 32-bit source out of memory, which is the form without rex.w
    mov dword [0x30000], 5
    cvtsi2sd xmm2, dword [0x30000]
    movq r10, xmm2                          ; -> 5.0

    ; the two directions back from the same double, 3.5, which is exactly between two integers:
    ; truncation gives 3 and rounding to nearest even gives 4, so the pair tells 2c from 2d
    mov rax, 0x400C000000000000             ; 3.5
    mov [0x30008], rax
    cvttsd2si r11, qword [0x30008]          ; -> 3
    cvtsd2si r12, qword [0x30008]           ; -> 4

    ; cvttss2si from a single, into a 32-bit register, which zero extends like every 32-bit write
    mov dword [0x30010], 0xC0300000         ; -2.75f
    cvttss2si r13d, dword [0x30010]         ; -> -2, as 32 bits

    ; past the range of a 64-bit destination
    mov rax, 0x7FF0000000000000             ; +infinity
    mov [0x30018], rax
    cvttsd2si r14, qword [0x30018]          ; -> the 64-bit integer indefinite

    ; and past the range of a 32-bit one, from a value a 64-bit destination would have taken
    mov rax, 0x4270000000000000             ; 2^40
    mov [0x30020], rax
    cvttsd2si r15d, qword [0x30020]         ; -> the 32-bit integer indefinite, zero extended

    hlt

%include "long-mode-epilogue.inc"
