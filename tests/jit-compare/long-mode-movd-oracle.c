// Ground truth for tests/jit-compare/long-mode-movd.asm, run on a real x86-64 (via rosetta on an
// arm mac: clang -arch x86_64 -O0 -o oracle long-mode-movd-oracle.c).
//
// Results are stored to memory as they are produced, so the oracle need not clobber the registers
// the compiler reserves; the fixture parks them wherever it likes.
#include <stdio.h>
#include <stdint.h>

int main(void)
{
    uint64_t o[6];
    __asm__ volatile(
        // movq xmm, r64 and back again, the widened forms of movd
        "movabsq $0x0123456789abcdef, %%rdx\n\t"
        "movq %%rdx, %%xmm0\n\t"
        "movq %%xmm0, %%rax\n\t"
        "movq %%rax, 0(%0)\n\t"

        // movd over a register that already holds something: the 32-bit form keeps the low four
        // bytes and clears the rest of the xmm register rather than merging
        "movabsq $0xffffffffdeadbeef, %%rcx\n\t"
        "movq %%rcx, %%xmm1\n\t"
        "movd %%ecx, %%xmm1\n\t"
        "movq %%xmm1, %%rax\n\t"
        "movq %%rax, 8(%0)\n\t"

        // movlhps then a 16-byte store, which is how windows spreads a value to zero memory with
        "movq %%rdx, %%xmm2\n\t"
        "movlhps %%xmm2, %%xmm2\n\t"
        "movups %%xmm2, 16(%0)\n\t"

        // movd out of an xmm register writes 32 bits, so the top half of rax is cleared
        "movd %%xmm0, %%eax\n\t"
        "movq %%rax, 32(%0)\n\t"

        // and the 64-bit form out, to a memory operand rather than a register
        "movq %%xmm0, 40(%0)\n\t"
        :
        : "r"(o)
        : "rax", "rcx", "rdx", "xmm0", "xmm1", "xmm2", "memory", "cc");

    static const char *name[] = {
        "movq xmm,r64 -> r64 ", "movd over a live reg", "movlhps store low   ",
        "movlhps store high  ", "movd xmm -> r32     ", "movq xmm -> m64     ",
    };
    for(int i = 0; i < 6; i++) printf("%s = %016llx\n", name[i], (unsigned long long)o[i]);
    return 0;
}
