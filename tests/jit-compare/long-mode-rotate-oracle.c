// Ground truth for tests/jit-compare/long-mode-rotate.asm, run on a real x86-64 (via rosetta).
// Executes the same sequence the fixture does and prints the values it leaves behind, so the
// .expected file is what the hardware does rather than what I worked out it should do.
//
// Each case captures the result and then the arithmetic flags, masked to cf|pf|af|zf|sf|of. The
// store between the two does not touch flags.
#include <stdio.h>
#include <stdint.h>

#define FLAGS(slot) "pushfq\n\tpopq %%rax\n\tandq $0x801, %%rax\n\tmovq %%rax, " slot "(%0)\n\t"

int main(void)
{
    uint64_t o[14];
    __asm__ volatile(
        // A: rol by an immediate, 64-bit
        "movabsq $0x123456789abcdef0, %%rax\n\t"
        "rolq $5, %%rax\n\t"
        "movq %%rax, 0(%0)\n\t" FLAGS("8")

        // B: ror by an immediate, 64-bit
        "movabsq $0x123456789abcdef0, %%rax\n\t"
        "rorq $4, %%rax\n\t"
        "movq %%rax, 16(%0)\n\t" FLAGS("24")

        // C: rcl by one with cf clear, rotating the top bit out into cf
        "movabsq $0x8000000000000000, %%rax\n\t"
        "clc\n\t"
        "rclq $1, %%rax\n\t"
        "movq %%rax, 32(%0)\n\t" FLAGS("40")

        // D: the 32-bit form, which must zero extend like any other 32-bit write
        "movabsq $0xffffffff12345678, %%rax\n\t"
        "roll $8, %%eax\n\t"
        "movq %%rax, 48(%0)\n\t" FLAGS("56")

        // E: rcr by a large count with cf set, a cycle 65 bits wide
        "movabsq $0x0123456789abcdef, %%rax\n\t"
        "stc\n\t"
        "rcrq $63, %%rax\n\t"
        "movq %%rax, 64(%0)\n\t" FLAGS("72")

        // F: the 8-bit form, whose count is taken modulo the operand width
        "movabsq $0x12, %%rax\n\t"
        "rolb $9, %%al\n\t"
        "movq %%rax, 80(%0)\n\t" FLAGS("88")
        // G: sf, zf and pf are not outputs of a rotate and must survive it. xor sets zf and pf,
        // the mov between does not touch flags, and the rotate must not publish its own result.
        "xorq %%rax, %%rax\n\t"
        "movq $1, %%rax\n\t"
        "rolq $1, %%rax\n\t"
        "movq %%rax, 96(%0)\n\t"
        "pushfq\n\tpopq %%rax\n\tandq $0x8d5, %%rax\n\tmovq %%rax, 104(%0)\n\t"
        :
        : "r"(o)
        : "rax", "memory", "cc");

    static const char *name[] = {
        "A rol rax,5      ", "A flags", "B ror rax,4      ", "B flags",
        "C rcl rax,1 cf=0 ", "C flags", "D rol eax,8      ", "D flags",
        "E rcr rax,63 cf=1", "E flags", "F rol al,9       ", "F flags",
        "G rol rax,1 preserve", "G flags",
    };
    for(int i = 0; i < 14; i++) printf("%s = %016llx\n", name[i], (unsigned long long)o[i]);
    return 0;
}
