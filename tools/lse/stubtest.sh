#!/bin/sh
# Build and run stubtest.c against the lse_stub.h in kernel patch 0026, so the test checks exactly
# what the kernel builds. Needs arm64 Linux on a CPU with LSE, gcc, and binutils for the decode
# check. Args go to stubtest (case count). STUBTEST_SHOW=1 prints the sample stubs' disassembly.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
patch=$(ls "$here"/../../kernel/patches/0026-*.patch)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

awk '/^\+\+\+ b\/arch\/arm64\/kernel\/lse_stub\.h$/ { f = 1; next }
     f && /^diff / { f = 0 }
     f && /^@@/ { next }
     f { sub(/^\+/, ""); print }' "$patch" >"$tmp/lse_stub.h"
gcc -O2 -Wall -pthread -I"$tmp" -o "$tmp/stubtest" "$here/stubtest.c"
"$tmp/stubtest" "$@"

"$tmp/stubtest" dump "$tmp/stubs.bin"
objdump -D -b binary -m aarch64 "$tmp/stubs.bin" >"$tmp/stubs.txt"
if grep -E '\.inst|undefined|unallocated' "$tmp/stubs.txt"; then
	echo "sample stub words objdump cannot decode" >&2
	exit 1
fi
echo "sample stubs decode cleanly ($(grep -cE '^ +[0-9a-f]+:' "$tmp/stubs.txt") words)"
[ -z "${STUBTEST_SHOW:-}" ] || cat "$tmp/stubs.txt"
