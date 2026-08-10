// Ground truth for tests/jit-compare/long-mode-muldiv.asm, run on a real x86-64 (via rosetta on an
// arm mac: clang -arch x86_64 -O0 -o oracle long-mode-muldiv-oracle.c). It performs the same
// arithmetic the fixture does and prints what the hardware leaves behind, so the .expected file
// records measured behaviour rather than a reading of the manual.
//
// Results are stored to memory as they are produced rather than held in registers, so that the
// oracle does not have to clobber the ones the compiler reserves; the fixture is free to park them
// wherever it likes. Flags are captured only for the multiplies, which are the only ones of the
// four that define any.
#include <stdio.h>
#include <stdint.h>

#define CF_OF "pushfq\n\tpopq %%rax\n\tandq $0x801, %%rax\n\t"

int main(void)
{
    uint64_t o[12];
    __asm__ volatile(
        // 1: mul, unsigned and wide enough to fill both halves
        "movabsq $0xdeadbeefcafebabe, %%rax\n\t"
        "movabsq $0x0123456789abcdef, %%rbx\n\t"
        "mulq %%rbx\n\t"
        "movq %%rax, 0(%0)\n\t"
        "movq %%rdx, 8(%0)\n\t"
        CF_OF "movq %%rax, 16(%0)\n\t"

        // 2: imul with a negative operand, whose product does not fit the low half
        "movabsq $0x123456789abcdef0, %%rax\n\t"
        "movq $-3, %%rbx\n\t"
        "imulq %%rbx\n\t"
        "movq %%rax, 24(%0)\n\t"
        "movq %%rdx, 32(%0)\n\t"
        CF_OF "movq %%rax, 40(%0)\n\t"

        // 3: the 32-bit form, which must zero extend both halves of the result. rax and rdx start
        // as all ones so that a stale top half would show.
        "movq $-1, %%rax\n\t"
        "movq $-1, %%rdx\n\t"
        "movabsq $0xffffffff00001234, %%rbx\n\t"
        "mull %%ebx\n\t"
        "movq %%rax, 48(%0)\n\t"
        "movq %%rdx, 56(%0)\n\t"

        // 4: div of a true 128-bit dividend, 2^64 over 3
        "movq $1, %%rdx\n\t"
        "movq $0, %%rax\n\t"
        "movq $3, %%rbx\n\t"
        "divq %%rbx\n\t"
        "movq %%rax, 64(%0)\n\t"
        "movq %%rdx, 72(%0)\n\t"

        // 5: idiv with a negative dividend, where the quotient truncates toward zero and the
        // remainder takes the sign of the dividend
        "movq $-1, %%rdx\n\t"
        "movq $-100, %%rax\n\t"
        "movq $7, %%rbx\n\t"
        "idivq %%rbx\n\t"
        "movq %%rax, 80(%0)\n\t"
        "movq %%rdx, 88(%0)\n\t"
        :
        : "r"(o)
        : "rax", "rbx", "rdx", "memory", "cc");

    static const char *name[] = {
        "1 mul rbx      rax", "1 mul rbx      rdx", "1 mul          cf|of",
        "2 imul rbx     rax", "2 imul rbx     rdx", "2 imul         cf|of",
        "3 mul ebx      rax", "3 mul ebx      rdx",
        "4 div rbx      rax", "4 div rbx      rdx",
        "5 idiv rbx     rax", "5 idiv rbx     rdx",
    };
    for(int i = 0; i < 12; i++) printf("%s = %016llx\n", name[i], (unsigned long long)o[i]);
    return 0;
}
