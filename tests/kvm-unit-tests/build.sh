#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CC="gcc"
EXTRA_CFLAGS=""
EXTRA_MAKE_ARGS=()

# These tests are freestanding, so a bare metal i686-elf cross toolchain is enough when the host
# gcc can't target i386 (macos, or any non-x86 host without gcc-multilib).
if ! echo 'int main(void){return 0;}' | gcc -m32 -xc - -o /dev/null >/dev/null 2>&1; then
    if ! command -v i686-elf-gcc >/dev/null; then
        echo "error: gcc cannot target i386 and no i686-elf-gcc found." >&2
        echo "Install gcc-multilib, or an i686-elf cross toolchain (brew install i686-elf-gcc i686-elf-binutils)." >&2
        exit 1
    fi

    CC="i686-elf-gcc"
    # This assembler treats / as the start of a comment by default, which breaks the arithmetic in
    # cstart.S. --divide makes it a division operator instead.
    #
    # -Wno-error=format because these tests predate gcc's stricter format checking and print
    # size-suffixed types with %x
    EXTRA_CFLAGS=" -Wa,--divide -Wno-error=format"
    EXTRA_MAKE_ARGS=(LD=i686-elf-ld OBJCOPY=i686-elf-objcopy AR=i686-elf-ar)
    # libcflat.a is indexed by ar, so a stale one built by a different toolchain won't link
    rm -f lib/libcflat.a
fi

./configure --arch=i386
make CC="$CC -std=gnu11 -mno-sse -mno-sse2 -mno-mmx$EXTRA_CFLAGS" "${EXTRA_MAKE_ARGS[@]}" \
    x86/realmode.flat x86/taskswitch.flat x86/taskswitch2.flat
