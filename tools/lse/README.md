# LSE atomics on ARMv8.0 CPUs

Valve's arm64 Steam client (and anything else built for ARMv8.1+ without outline atomics) issues
LSE atomics unconditionally. The SM6115's Cortex-A73/A53 (every A53/A55-class SoC) has none, so
such a binary dies with SIGILL on its first atomic. The fix is `kernel/patches/0025`
(`CONFIG_ARM64_LSE_EMULATION`); these are the tools around it. See `docs/steam-arm64.md`.

`kernel/patches/0026` stops a site trapping: after emulating it, the kernel rewrites the
instruction into a B to a native LDXR/STXR stub in an `[lse_stubs]` mapping (LDAPR into LDAR), so
a trap's ~280 ns (A73) / ~490 ns (A53) becomes a few instructions. The mapping goes in free space
within branch reach, or, where there is none (Valve's FEX reserves all of it), in the PROT_NONE
padding between two segments of the site's own ELF file. `kernel/patches/0027` waits for a site's
4th emulation (`/proc/sys/abi/lse_patch_after`, 1-255; 1 patches at the first, as 0026 alone
does): a patch costs ~32 µs and a private copy of the site's text page, and 37% of the sites
Proton's wineboot emulated ran once (MANGMI Air X, 2026-11-21). 0027 also has each process
remember the arenas its stubs went into last, so a site near one skips the search for a slot.
`/proc/sys/abi/lse_patch` (1) turns patching off; `abi/lse_patched` counts patched sites and
`abi/lse_patch_failed` attempts that could not patch. Sites in JIT code and SP-based forms keep
trapping.

- **`lsetest.c`** — checks an LSE implementation: every LDADD/LDCLR/LDEOR/LDSET/LD{S,U}{MAX,MIN},
  SWP, CAS, CASP form at every size and ordering, over edge values, against a C reference
  (55,288 checks), plus 4-thread contended LDADDAL and CAS-lock counters that must come out exact.
  On native LSE hardware it passes; on an ARMv8.0 kernel without 0025 it dies with SIGILL; with
  0025 (or the shim below) it must pass.

  ```sh
  gcc -O2 -march=armv8.1-a -pthread -static -o lsetest lsetest.c
  ```

- **`lse_shim.c`** — the userspace twin of 0025, for a kernel without it: an `LD_PRELOAD` SIGILL
  handler with the same decoder and LDXR/STXR loops. It keeps itself first for SIGILL (interposes
  `sigaction`/`signal`, chains to the application's handler) and never lets a thread block SIGILL
  (a CPU-raised SIGILL in a thread that blocks it is fatal; libpulse starts its threads that way).
  `RETROFORGE_LSE_STATS=1` prints the emulation count per process. Slower than the kernel path
  (0.86 us per emulated atomic on an A73, measured) and per-process only; a stopgap.

  ```sh
  gcc -O2 -march=armv8-a -fPIC -shared -o lse_shim.so lse_shim.c -ldl
  ```
