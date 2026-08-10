#include <stdio.h>
#include <stdint.h>
int main(void)
{
    uint64_t o[12];
    __asm__ volatile(
        "movabsq $0x0000100000000100, %%rbx\n\t"
        "movq $0xdead, %%rax\n\t"
        "bsfq %%rbx, %%rax\n\t"
        "movq %%rax, 0(%0)\n\t"
        "movq $0xdead, %%rax\n\t"
        "bsrq %%rbx, %%rax\n\t"
        "movq %%rax, 8(%0)\n\t"

        // a zero source: zf set and the destination left alone
        "xorq %%rbx, %%rbx\n\t"
        "movabsq $0x1234567812345678, %%rax\n\t"
        "bsfq %%rbx, %%rax\n\t"
        "movq %%rax, 16(%0)\n\t"
        "pushfq\n\tpopq %%rcx\n\tandq $0x40, %%rcx\n\tmovq %%rcx, 24(%0)\n\t"

        // the 32-bit form, which zero extends its result into the full register
        "movq $0x00080000, %%rbx\n\t"
        "movabsq $0xffffffffffffffff, %%rax\n\t"
        "bsfl %%ebx, %%eax\n\t"
        "movq %%rax, 32(%0)\n\t"
        : : "r"(o) : "rax","rbx","rcx","memory","cc");
    const char *n[] = {"bsf 64","bsr 64","bsf zero dest","bsf zero zf","bsf 32"};
    for(int i = 0; i < 5; i++) printf("%-14s = %016llx\n", n[i], (unsigned long long)o[i]);
    return 0;
}
