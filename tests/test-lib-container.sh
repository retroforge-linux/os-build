#!/usr/bin/env bash
# Offline tests for build/lib-container.sh — the docker/podman choice every host build script uses.
#
#   tests/test-lib-container.sh
#
# No docker, no podman, no network: a fake runtime on PATH records its argv. Run via `make test`.
#
# WHAT IS AT RISK: under podman a run without label=disable cannot read the bind-mounted checkout
# on an SELinux host, and `import --platform` is not a podman flag; either breaks the build box's
# first stage. The scripts must also never call docker directly, or podman hosts fail there.
set -uo pipefail

ROOT_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_REAL/build/lib-container.sh"

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
for rt in podman docker; do
  printf '#!/bin/sh\necho "%s $*"\n' "$rt" > "$TMP/bin/$rt"; chmod +x "$TMP/bin/$rt"
done

# ctr with a given runtime and PATH; prints what the fake runtime received. PATH holds ONLY the
# fakes (bash by absolute path), so a real docker on the host cannot decide the choice cases.
call() {  # call <QFORGE_CONTAINER or ""> <path> <ctr args...>
  local rt="$1" path="$2"; shift 2
  env -i PATH="$path" QFORGE_CONTAINER="$rt" "$BASH" -c '[ -n "$QFORGE_CONTAINER" ] || unset QFORGE_CONTAINER; . "$1"; shift; ctr "$@"' _ "$LIB" "$@"
}

CASE=podman
out="$(call podman "$TMP/bin" run --rm -v /x:/src img true)"
[ "$out" = "podman run --security-opt label=disable --rm -v /x:/src img true" ] \
  && ok "run disables SELinux labelling" || bad "run: $out"
out="$(call podman "$TMP/bin" import --platform linux/arm64 - qforge/builder-import:x)"
[ "$out" = "podman import --os linux --arch arm64 - qforge/builder-import:x" ] \
  && ok "import --platform becomes --os/--arch" || bad "import: $out"
out="$(call podman "$TMP/bin" image inspect ref)"
[ "$out" = "podman image inspect ref" ] && ok "other subcommands pass through" || bad "pass-through: $out"

CASE=docker
out="$(call docker "$TMP/bin" run --rm img true)"
[ "$out" = "docker run --rm img true" ] && ok "run is unchanged" || bad "run: $out"
out="$(call docker "$TMP/bin" import --platform linux/arm64 - t)"
[ "$out" = "docker import --platform linux/arm64 - t" ] && ok "import is unchanged" || bad "import: $out"

CASE=choice
mkdir -p "$TMP/only-podman"; cp "$TMP/bin/podman" "$TMP/only-podman/"
out="$(call "" "$TMP/only-podman" ps)"
case "$out" in podman*) ok "podman when docker is absent" ;; *) bad "picked: $out" ;; esac
out="$(call "" "$TMP/bin" ps)"
case "$out" in docker*) ok "docker when it is installed" ;; *) bad "picked: $out" ;; esac

CASE=scripts
# Code lines only. The CI workflow runs on GitHub's docker and stays as it is.
direct="$(grep -nE '^[^#]*(^|[^A-Za-z_/$-])docker (run|build|import|commit|rm|rmi|image|volume) ' \
          "$ROOT_REAL"/Makefile "$ROOT_REAL"/build/*.sh "$ROOT_REAL"/rootfs/*.sh "$ROOT_REAL"/installer/*.sh \
          "$ROOT_REAL"/packages/*.sh "$ROOT_REAL"/ota/*.sh "$ROOT_REAL"/kernel/*.sh "$ROOT_REAL"/firmware/*.sh \
          2>/dev/null || true)"
[ -z "$direct" ] && ok "no build script calls docker directly" \
  || bad "direct docker calls: $(printf '%s' "$direct" | cut -c1-120 | tr '\n' ' ')"

printf '\ntest-lib-container.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
