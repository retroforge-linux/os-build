#!/usr/bin/env bash
# Compose the downloadable FEX guest: FEX's ArchLinux RootFS (./guest.pin) with our x86 Mesa
# (./build.sh's payload) laid over it.
#
#   packages/mesa-x86/compose.sh [--payload DIR] [--guest FILE] [--out DIR]
#   packages/mesa-x86/compose.sh --print-version | --print-asset | --print-tag
#
#   --payload DIR   tree to lay over the guest (default: work/mesa-x86/out/payload, from build.sh)
#   --guest FILE    a local copy of the guest image; still checked against guest.pin's sha256
#                   (default: downloaded once into work/mesa-x86/guest/<version>/)
#   --out DIR       where the result goes (default: out/fex-guest)
#
# Writes, in --out:
#   retroforge-fex-guest-<version>.sqsh            the image (name from ./lib.sh)
#   retroforge-fex-guest-<version>.sqsh.sha256     `sha256sum -c` format
#   retroforge-fex-guest-<version>.sqsh.release    what it was made from (also in the image, at
#                                                  /usr/share/retroforge/fex-guest.release)
#   retroforge-fex-guest-<version>.sqsh.overlay.txt  every path replaced or added in the guest
#
# The work happens in ./container-compose.sh, in the ./builder.pin image, as root; the overlay and
# its checks are ./guest-overlay.py. It refuses to write an image whose ICDs or GL libraries do
# not resolve to our build, or one of our libraries that does not load in the guest.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$MX86_ROOT"

PAYLOAD="$ROOT/work/mesa-x86/out/payload"
GUEST=""
OUTDIR="$ROOT/out/fex-guest"
while [ $# -gt 0 ]; do
  case "$1" in
    --payload) PAYLOAD="${2:?}"; shift ;;
    --guest) GUEST="${2:?}"; shift ;;
    --out) OUTDIR="${2:?}"; shift ;;
    --print-version) mx86_version; exit 0 ;;
    --print-asset) mx86_asset; exit 0 ;;
    --print-tag) mx86_tag; exit 0 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

. "$ROOT/build/lib-container.sh"

PIN="$MX86_DIR/guest.pin"
BASE_NAME="$(mx86_field "$PIN" name)"
BASE_VERSION="$(mx86_field "$PIN" version)"
BASE_URL="$(mx86_field "$PIN" url)"
BASE_SHA256="$(mx86_field "$PIN" sha256)"
: "${BASE_NAME:?guest.pin: name}" "${BASE_VERSION:?guest.pin: version}"
: "${BASE_URL:?guest.pin: url}" "${BASE_SHA256:?guest.pin: sha256}"
IMAGE="$(mx86_field "$MX86_DIR/builder.pin" image)"
SNAPSHOT="$(mx86_field "$MX86_DIR/builder.pin" snapshot)"
VERSION="$(mx86_version)"
ASSET="$(mx86_asset)"
MESA_VERSION="$(mx86_mesa_version_string)"

[ -d "$PAYLOAD/usr/lib" ] && [ -d "$PAYLOAD/usr/lib32" ] || {
  echo "ERROR: no payload at $PAYLOAD -- run packages/mesa-x86/build.sh first" >&2; exit 1; }

# Compared by hand rather than with `sha256sum --check --status`, which macOS's sha256sum lacks.
verify_guest() { [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$BASE_SHA256" ]; }

# --- the guest image, sha256-checked whichever way it arrives -------------------------------
if [ -z "$GUEST" ]; then
  GUEST="$ROOT/work/mesa-x86/guest/$BASE_VERSION/${BASE_URL##*/}"
  if [ -s "$GUEST" ] && verify_guest "$GUEST"; then
    echo "[fex-guest] $BASE_NAME $BASE_VERSION already present and verified" >&2
  else
    mkdir -p "$(dirname "$GUEST")"
    echo "[fex-guest] downloading $BASE_URL (source-mirror first)" >&2
    "$ROOT/tools/source-mirror/rf-fetch" --sha256 "$BASE_SHA256" "$GUEST" "$BASE_URL" \
      || { echo "ERROR: could not fetch $BASE_URL" >&2; exit 1; }
  fi
fi
verify_guest "$GUEST" || {
  echo "ERROR: $GUEST does not match guest.pin's sha256 ($BASE_SHA256)." >&2
  echo "       Got: $(sha256sum "$GUEST" | cut -d' ' -f1)" >&2
  exit 1; }

ctr_require "composing the FEX guest"
mkdir -p "$OUTDIR"
GUEST_ABS="$(cd "$(dirname "$GUEST")" && pwd)/$(basename "$GUEST")"
PAYLOAD_ABS="$(cd "$PAYLOAD" && pwd)"
OUT_ABS="$(cd "$OUTDIR" && pwd)"

ctr run --rm --platform linux/amd64 \
  -v "$ROOT":/repo:ro \
  -v "$GUEST_ABS":/guest.sqsh:ro \
  -v "$PAYLOAD_ABS":/payload:ro \
  -v "$OUT_ABS":/out \
  -e SNAPSHOT="$SNAPSHOT" -e ASSET="$ASSET" -e VERSION="$VERSION" -e MESA_VERSION="$MESA_VERSION" \
  -e PATCHES="$(mx86_patches)" \
  -e BASE_NAME="$BASE_NAME" -e BASE_VERSION="$BASE_VERSION" -e BASE_URL="$BASE_URL" \
  -e BASE_SHA256="$BASE_SHA256" \
  -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}" -e MX86_SKIP_I386_EXEC="${MX86_SKIP_I386_EXEC:-0}" \
  -e HOST_UID="$(ctr_host_owner | cut -d: -f1)" -e HOST_GID="$(ctr_host_owner | cut -d: -f2)" \
  "$IMAGE" bash /repo/packages/mesa-x86/container-compose.sh

# --- the publishing limit -------------------------------------------------------------------------
# The image is published as a GitHub Release asset, and GitHub refuses one of 2 GiB or more. Say
# so here, in words, rather than as an HTTP error at upload time.
size="$(wc -c <"$OUT_ABS/$ASSET" | tr -d ' ')"
limit=$((2 * 1024 * 1024 * 1024))
echo "[fex-guest] $ASSET: $((size / 1048576)) MiB of the $((limit / 1048576)) MiB release-asset cap" >&2
if [ "$size" -ge "$limit" ]; then
  echo "ERROR: $ASSET is $size bytes, over GitHub's 2 GiB per-asset cap." >&2
  exit 1
fi
echo "[fex-guest] -> $OUT_ABS/$ASSET" >&2
