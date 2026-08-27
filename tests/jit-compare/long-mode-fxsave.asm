; fxsave, fxrstor and the mxcsr pair in 64-bit mode.
;
; These are not the 32-bit instructions with a wider address. The 32-bit forms save eight xmm
; registers, and 64-bit mode has sixteen; the eight they would miss are not scratch, since windows
; saves and restores fpu state with these across every thread switch. Getting it wrong would corrupt
; xmm8 to xmm15 silently, which is the worst way for it to be wrong.
;
; Both encodings are exercised: fxsave64 carries rex.w and fxrstor does not, and they have to reach
; the same state.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    ; one register from each of the three groups that could be handled differently
    mov rax, 0x0102030405060708
    movq xmm0, rax
    mov rax, 0xAABBCCDDEEFF0011
    movq xmm8, rax
    mov rax, 0x1122334455667788
    movq xmm15, rax

    ; a mxcsr that is not the reset value, so that restoring it is visible
    mov dword [0x7200], 0x1FC0
    ldmxcsr [0x7200]

    fxsave64 [0x7400]

    ; clobber everything the save should have captured
    xorps xmm0, xmm0
    xorps xmm8, xmm8
    xorps xmm15, xmm15
    mov dword [0x7200], 0x1F80
    ldmxcsr [0x7200]

    fxrstor [0x7400]                        ; the form without rex.w, which must agree

    movq r8, xmm0                           ; -> 0102030405060708
    movq r9, xmm8                           ; -> aabbccddeeff0011
    movq r10, xmm15                         ; -> 1122334455667788

    mov dword [0x7200], 0
    stmxcsr [0x7200]
    mov r11d, [0x7200]                      ; -> 1fc0

    hlt

%include "long-mode-epilogue.inc"
