// The absolute address form of mov. Its address is an immediate rather than a register, so the
// oracle keeps its buffer at a fixed address of its own to write the same instructions the fixture
// does; a static array is not at a known address, so the address is taken at run time and the
// instructions are assembled by hand with it patched in.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>

// mov rax, imm64 ; the moffs instruction ; mov [rsi], rax ; ret - built for one case at a time
static uint64_t run(uint64_t rax_in, const uint8_t *moffs_op, int op_len, uint64_t addr,
                    uint64_t *out)
{
    uint8_t code[64];
    int n = 0;
    code[n++] = 0x48; code[n++] = 0xB8;             // movabs rax, rax_in
    memcpy(code + n, &rax_in, 8); n += 8;
    memcpy(code + n, moffs_op, op_len); n += op_len;
    memcpy(code + n, &addr, 8); n += 8;             // the absolute address it carries
    code[n++] = 0x48; code[n++] = 0x89; code[n++] = 0x07;   // mov [rdi], rax
    code[n++] = 0xC3;                               // ret

    void *page = mmap(0, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                      MAP_PRIVATE | MAP_ANON, -1, 0);
    memcpy(page, code, n);
    ((void (*)(uint64_t *))page)(out);
    munmap(page, 4096);
    return *out;
}

int main(void)
{
    static uint64_t mem[4], out;
    const uint64_t at = (uint64_t)&mem[0];
    const uint8_t st64[] = {0x48, 0xA3}, st32[] = {0xA3}, st8[] = {0xA2};
    const uint8_t ld64[] = {0x48, 0xA1}, ld32[] = {0xA1}, ld8[] = {0xA0};

    mem[0] = mem[1] = 0xEEEEEEEEEEEEEEEEull;
    run(0x1122334455667788ull, st64, 2, at, &out);
    printf("%-22s = %016llx\n", "store 64", (unsigned long long)mem[0]);

    mem[0] = 0xEEEEEEEEEEEEEEEEull;
    run(0x99999999AABBCCDDull, st32, 1, at, &out);
    printf("%-22s = %016llx\n", "store 32", (unsigned long long)mem[0]);

    mem[0] = 0xEEEEEEEEEEEEEEEEull;
    run(0x5Aull, st8, 1, at, &out);
    printf("%-22s = %016llx\n", "store 8", (unsigned long long)mem[0]);

    mem[0] = 0x0102030405060708ull;
    printf("%-22s = %016llx\n", "load 64", (unsigned long long)run(0, ld64, 2, at, &out));
    printf("%-22s = %016llx\n", "load 32 into all ones",
           (unsigned long long)run(0xFFFFFFFFFFFFFFFFull, ld32, 1, at, &out));
    printf("%-22s = %016llx\n", "load 8 into all ones",
           (unsigned long long)run(0xFFFFFFFFFFFFFFFFull, ld8, 1, at, &out));
    return 0;
}
