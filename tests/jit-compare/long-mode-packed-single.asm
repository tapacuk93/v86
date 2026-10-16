; The packed single family, which is the one with no mandatory prefix at all.
;
; Each of these opcodes names four instructions: the bare form works on four singles, a 0x66 makes
; it two doubles, and an f3 or f2 makes it one of either. The table the 128-bit family is reached
; through is keyed by opcode alone, so it can only hold one of the four - it holds the 0x66 ones,
; which left the bare forms missing although they are the oldest sse there is.
;
; Windows reaches them in kernel code: this is what a compiler emits for arithmetic on a vector of
; floats, and the boot gets through thirteen address spaces before one turns up.
%include "long-mode.inc"

BITS 64
DEFAULT ABS
long_mode:
    mov rsp, 0x7000

    mov rax, 0x400000003F800000             ; 1.0f 2.0f
    mov [0x30000], rax
    mov rax, 0x4100000040800000             ; 4.0f 8.0f
    mov [0x30008], rax
    mov rax, 0x4000000040000000             ; 2.0f in all four lanes
    mov [0x30010], rax
    mov [0x30018], rax
    mov rax, 0x4180000040800000             ; 4.0f 16.0f
    mov [0x30020], rax
    mov rax, 0x3F8000003F800000             ; 1.0f 1.0f
    mov [0x30028], rax

    ; addps
    movaps xmm0, [0x30000]
    addps xmm0, [0x30010]
    movaps [0x30030], xmm0
    mov r8, [0x30030]                       ; -> 3.0f 4.0f

    ; mulps
    movaps xmm1, [0x30000]
    mulps xmm1, [0x30010]
    movaps [0x30040], xmm1
    mov r9, [0x30040]                       ; -> 2.0f 4.0f

    ; divps
    movaps xmm2, [0x30000]
    divps xmm2, [0x30010]
    movaps [0x30050], xmm2
    mov r10, [0x30050]                      ; -> 0.5f 1.0f

    ; subps
    movaps xmm3, [0x30000]
    subps xmm3, [0x30010]
    movaps [0x30060], xmm3
    mov r11, [0x30060]                      ; -> -1.0f 0.0f

    ; minps, which takes the smaller of each pair
    movaps xmm4, [0x30000]
    minps xmm4, [0x30010]
    movaps [0x30070], xmm4
    mov r12, [0x30070]                      ; -> 1.0f 2.0f

    ; sqrtps
    movaps xmm5, [0x30020]
    sqrtps xmm5, xmm5
    movaps [0x30080], xmm5
    mov r13, [0x30080]                      ; -> 2.0f 4.0f

    ; xorps against itself clears the register, which is how compiled code makes a zero
    movaps xmm6, [0x30000]
    xorps xmm6, xmm6
    movaps [0x30090], xmm6
    mov r14, [0x30090]                      ; -> 0

    ; cvtps2pd widens the low two singles into two doubles, so it reads 64 bits
    cvtps2pd xmm7, qword [0x30000]
    movaps [0x300A0], xmm7
    mov r15, [0x300A0]                      ; -> 1.0

    hlt

%include "long-mode-epilogue.inc"
