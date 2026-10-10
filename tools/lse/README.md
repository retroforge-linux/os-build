# LSE atomics on ARMv8.0 CPUs

Valve's arm64 Steam client (and anything else built for ARMv8.1+ without outline atomics) issues
LSE atomics unconditionally. The SM6115's Cortex-A73/A53 (every A53/A55-class SoC) has none, so
such a binary dies with SIGILL on its first atomic. The fix is `kernel/patches/0025`
(`CONFIG_ARM64_LSE_EMULATION`); these are the tools around it. See `docs/steam-arm64.md`.

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
  `QFORGE_LSE_STATS=1` prints the emulation count per process. Slower than the kernel path
  (0.86 us per emulated atomic on an A73, measured) and per-process only; a stopgap.

  ```sh
  gcc -O2 -march=armv8-a -fPIC -shared -o lse_shim.so lse_shim.c -ldl
  ```
