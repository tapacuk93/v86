#include <stdio.h>
#include <stdint.h>
int main(void)
{
    uint64_t o[8];
    __asm__ volatile(
        "movabsq $0x0123456789abcdef, %%rax\n\t"
        "movq %%rax, %%xmm2\n\t"
        "movlhps %%xmm2, %%xmm2\n\t"
        "psrldq $8, %%xmm2\n\t"
        "movups %%xmm2, 0(%0)\n\t"
        "movq %%rax, %%xmm3\n\t"
        "movlhps %%xmm3, %%xmm3\n\t"
        "pslldq $4, %%xmm3\n\t"
        "movups %%xmm3, 16(%0)\n\t"
        "movq %%rax, %%xmm4\n\t"
        "psrlq $8, %%xmm4\n\t"
        "movups %%xmm4, 32(%0)\n\t"
        : : "r"(o) : "rax","xmm2","xmm3","xmm4","memory","cc");
    const char *n[] = {"psrldq lo","psrldq hi","pslldq lo","pslldq hi","psrlq lo","psrlq hi"};
    for(int i = 0; i < 6; i++) printf("%-10s = %016llx\n", n[i], (unsigned long long)o[i]);
    return 0;
}
