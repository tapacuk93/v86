// Ground truth for tests/jit-compare/long-mode-string.asm, run on a real x86-64 (via rosetta:
// clang -arch x86_64 -O0 -o oracle long-mode-string-oracle.c).
//
// The buffer doubles as scratch for the string operations and as the output, so the offsets below
// are shared with the fixture: 0..63 is the working area, 64 on is where results are recorded.
#include <stdio.h>
#include <stdint.h>

int main(void)
{
    static uint64_t o[24];
    __asm__ volatile(
        "cld\n\t"
        // rep stosb over 16 bytes, then read two of them back
        "leaq 0(%0), %%rdi\n\t"
        "movq $16, %%rcx\n\t"
        "movb $0xab, %%al\n\t"
        "rep stosb\n\t"
        "movq 0(%0), %%rax\n\t"
        "movq %%rax, 64(%0)\n\t"
        "movq %%rdi, 72(%0)\n\t"          // rdi advanced by 16
        "movq %%rcx, 80(%0)\n\t"          // rcx drained to 0

        // rep movsq: copy those 16 bytes up to offset 32
        "leaq 0(%0), %%rsi\n\t"
        "leaq 32(%0), %%rdi\n\t"
        "movq $2, %%rcx\n\t"
        "rep movsq\n\t"
        "movq 32(%0), %%rax\n\t"
        "movq %%rax, 88(%0)\n\t"

        // repne scasb for a byte that is not there, so it runs the count out
        "leaq 0(%0), %%rdi\n\t"
        "movq $16, %%rcx\n\t"
        "movb $0x99, %%al\n\t"
        "repne scasb\n\t"
        "movq %%rcx, 96(%0)\n\t"
        "pushfq\n\tpopq %%rax\n\tandq $0x40, %%rax\n\tmovq %%rax, 104(%0)\n\t"

        // repne scasb for one that is, so it stops early
        "leaq 0(%0), %%rdi\n\t"
        "movq $16, %%rcx\n\t"
        "movb $0xab, %%al\n\t"
        "repne scasb\n\t"
        "movq %%rcx, 112(%0)\n\t"

        // std, then stosb downwards, to show df is honoured
        "std\n\t"
        "leaq 48(%0), %%rdi\n\t"
        "movq $4, %%rcx\n\t"
        "movb $0x77, %%al\n\t"
        "rep stosb\n\t"
        "cld\n\t"
        "movq %%rdi, 120(%0)\n\t"         // walked backwards
        "movq 40(%0), %%rax\n\t"
        "movq %%rax, 128(%0)\n\t"
        : : "r"(o) : "rax","rcx","rsi","rdi","memory","cc");

    static const char *name[] = {
        "stosb filled    ", "stosb rdi       ", "stosb rcx       ",
        "movsq copied    ", "scasb miss rcx  ", "scasb miss zf   ",
        "scasb hit rcx   ", "std stosb rdi   ", "std stosb bytes ",
    };
    for(int i = 0; i < 9; i++) printf("%s = %016llx\n", name[i], (unsigned long long)o[8 + i]);
    return 0;
}
