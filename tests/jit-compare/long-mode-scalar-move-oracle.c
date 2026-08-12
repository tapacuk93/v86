#include <stdio.h>
#include <stdint.h>
int main(void)
{
    static uint64_t o[16];
    __asm__ volatile(
        "movabsq $0x1122334455667788, %%rax\n\t"
        "movq %%rax, %%xmm0\n\t"
        "movabsq $0xDEADBEEFDEADBEEF, %%rax\n\t"
        "movq %%rax, %%xmm1\n\t"
        "movlhps %%xmm1, %%xmm0\n\t"        // xmm0 = deadbeefdeadbeef:1122334455667788

        // movsd stores 64 bits, leaving the qword after the destination alone
        "movabsq $0xAAAAAAAAAAAAAAAA, %%rax\n\t"
        "movq %%rax, 0(%0)\n\t"
        "movq %%rax, 8(%0)\n\t"
        "movsd %%xmm0, 0(%0)\n\t"

        // movss stores 32
        "movq %%rax, 16(%0)\n\t"
        "movss %%xmm0, 16(%0)\n\t"

        // a scalar load zeroes the rest of the register
        "movabsq $0x0102030405060708, %%rax\n\t"
        "movq %%rax, 24(%0)\n\t"
        "movabsq $0xFFFFFFFFFFFFFFFF, %%rax\n\t"
        "movq %%rax, %%xmm2\n\t"
        "movlhps %%xmm2, %%xmm2\n\t"
        "movsd 24(%0), %%xmm2\n\t"
        "movups %%xmm2, 32(%0)\n\t"

        "movq %%rax, %%xmm3\n\t"
        "movlhps %%xmm3, %%xmm3\n\t"
        "movss 24(%0), %%xmm3\n\t"
        "movups %%xmm3, 48(%0)\n\t"

        // the register form merges rather than zeroing
        "movq %%rax, %%xmm4\n\t"
        "movlhps %%xmm4, %%xmm4\n\t"
        "movabsq $0x0102030405060708, %%rax\n\t"
        "movq %%rax, %%xmm5\n\t"
        "movsd %%xmm5, %%xmm4\n\t"
        "movups %%xmm4, 64(%0)\n\t"
        : : "r"(o) : "rax","xmm0","xmm1","xmm2","xmm3","xmm4","xmm5","memory","cc");
    const char *n[] = {"movsd store", "the qword after it", "movss store",
                       "movsd load lo", "movsd load hi", "movss load lo", "movss load hi",
                       "movsd reg lo", "movsd reg hi"};
    const int idx[] = {0, 1, 2, 4, 5, 6, 7, 8, 9};
    for(int i = 0; i < 9; i++)
        printf("%-19s = %016llx\n", n[i], (unsigned long long)o[idx[i]]);
    return 0;
}
