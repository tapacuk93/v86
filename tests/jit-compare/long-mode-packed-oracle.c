#include <stdio.h>
#include <stdint.h>
int main(void)
{
    static uint64_t o[16];
    __asm__ volatile(
        "movabsq $0x00000002fffffffe, %%rax\n\t"
        "movq %%rax, %%xmm1\n\t"
        "movabsq $0x0000000500000003, %%rax\n\t"
        "movq %%rax, %%xmm6\n\t"
        "movlhps %%xmm6, %%xmm6\n\t"

        "paddd %%xmm6, %%xmm1\n\t"          // packed add of dwords
        "movups %%xmm1, 0(%0)\n\t"

        "movabsq $0x00000002fffffffe, %%rax\n\t"
        "movq %%rax, %%xmm2\n\t"
        "pcmpgtd %%xmm6, %%xmm2\n\t"        // signed compare, dword lanes
        "movups %%xmm2, 16(%0)\n\t"

        "movabsq $0x00ff00ff00ff00ff, %%rax\n\t"
        "movq %%rax, %%xmm3\n\t"
        "movabsq $0x0f0f0f0f0f0f0f0f, %%rax\n\t"
        "movq %%rax, %%xmm4\n\t"
        "pand %%xmm4, %%xmm3\n\t"
        "movups %%xmm3, 32(%0)\n\t"

        // and one with a memory source, which is the path that had to widen
        "movabsq $0x1111111122222222, %%rax\n\t"
        "movq %%rax, 64(%0)\n\t"
        "movq %%rax, 72(%0)\n\t"
        "movq %%rax, %%xmm5\n\t"
        "movlhps %%xmm5, %%xmm5\n\t"
        "paddd 64(%0), %%xmm5\n\t"
        "movups %%xmm5, 48(%0)\n\t"
        : : "r"(o) : "rax","xmm1","xmm2","xmm3","xmm4","xmm5","xmm6","memory","cc");
    const char *n[] = {"paddd lo","paddd hi","pcmpgtd lo","pcmpgtd hi",
                       "pand lo","pand hi","paddd mem lo","paddd mem hi"};
    for(int i = 0; i < 8; i++) printf("%-13s = %016llx\n", n[i], (unsigned long long)o[i]);
    return 0;
}
