#include <stdio.h>
#include <stdint.h>
int main(void)
{
    uint64_t o[8];
    __asm__ volatile(
        // inc on a byte that wraps, with carry set beforehand to show it survives
        "movabsq $0x11223344556677ff, %%rax\n\t"
        "stc\n\t"
        "incb %%al\n\t"
        "movq %%rax, 0(%0)\n\t"
        "pushfq\n\tpopq %%rcx\n\tandq $0x8d5, %%rcx\n\tmovq %%rcx, 8(%0)\n\t"
        // dec across zero
        "movabsq $0x1122334455667700, %%rax\n\t"
        "clc\n\t"
        "decb %%al\n\t"
        "movq %%rax, 16(%0)\n\t"
        "pushfq\n\tpopq %%rcx\n\tandq $0x8d5, %%rcx\n\tmovq %%rcx, 24(%0)\n\t"
        : : "r"(o) : "rax","rcx","memory","cc");
    const char *n[] = {"inc al wrap","inc flags","dec al wrap","dec flags"};
    for(int i = 0; i < 4; i++) printf("%-12s = %016llx\n", n[i], (unsigned long long)o[i]);
    return 0;
}
