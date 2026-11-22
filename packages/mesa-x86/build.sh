#!/usr/bin/env bash
# Build the x86_64 + i686 Mesa (Turnip, freedreno and zink GL) for the FEX guest.
#
#   packages/mesa-x86/build.sh                     build, or reuse a build of the same inputs
#   packages/mesa-x86/build.sh --configure-only    meson setup for both arches, then stop
#   packages/mesa-x86/build.sh --arch x86_64       one arch only (a partial build is never cached)
#
# Runs ./container-build.sh in the pinned x86_64 Arch image (./builder.pin). Native on an x86_64
# host (CI, the build box); emulated, and much slower, on an arm64 one. The result is a plain file
# tree that rootfs/lib-assemble-x86-mesa.sh puts in the OS image at /usr/lib/retroforge/x86-mesa/root,
# and steam-x86-guest lays over the guest a device downloads (./compose.sh can also lay it over the
# pinned guest and check it there, without shipping anything):
#
#   work/mesa-x86/out/payload/usr/lib/...      x86_64: libvulkan_freedreno.so, libgallium-*.so,
#                                              libEGL_mesa, libGLX_mesa, libgbm, gbm/, dri/
#   work/mesa-x86/out/payload/usr/lib32/...    the same for i686
#   work/mesa-x86/out/payload/usr/share/...    ICDs, the VRAM layer manifest, drirc.d, glvnd
#
#   work/mesa-x86/out/payload.conf             snapshot=<the Arch snapshot, YYYY-MM-DD>, mesa=<version>
#
# Nothing here is a pacman package: no source.pin or prebuilt.pin lives in this directory, so
# build-overlay.sh and customize-base.sh never see it. `make mesa-x86` runs this.
#
# CACHED like build-overlay.sh's stamps: work/mesa-x86/out/.inputs.sha256 holds the digest of the
# committed inputs, and a matching digest with a complete payload is a no-op.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$MX86_ROOT"
. "$ROOT/build/lib-container.sh"

STAGE=build
ARCHES="x86_64 i686"
while [ $# -gt 0 ]; do
  case "$1" in
    --configure-only) STAGE=configure ;;
    --arch) ARCHES="${2:?--arch needs x86_64 or i686}"; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

WORKDIR="$ROOT/work/mesa-x86/out"
MARKER="$WORKDIR/.inputs.sha256"

IMAGE="$(mx86_field "$MX86_DIR/builder.pin" image)"
SNAPSHOT="$(mx86_field "$MX86_DIR/builder.pin" snapshot)"
GUEST_VERSION="$(mx86_field "$MX86_DIR/guest.pin" version)"
: "${IMAGE:?builder.pin: missing image}" "${SNAPSHOT:?builder.pin: missing snapshot}"
: "${GUEST_VERSION:?guest.pin: missing version}"

# The snapshot and the guest are one decision (see builder.pin): refuse to build a driver against
# a different library generation from the one it will load next to.
if [ "$SNAPSHOT" != "${GUEST_VERSION//-//}" ]; then
  echo "ERROR: builder.pin snapshot '$SNAPSHOT' is not guest.pin version '$GUEST_VERSION'." >&2
  echo "       Move builder.pin (snapshot AND image) together with guest.pin." >&2
  exit 1
fi

PATCHES="$(mx86_patches)"
for p in $PATCHES; do
  [ -f "$MX86_MESA/patches/$p" ] || {
    echo "ERROR: missing patch $MX86_MESA/patches/$p (declared in packages/mesa/source.pin)" >&2; exit 1; }
done
MESA_VERSION="$(mx86_mesa_version_string)"

# Committed inputs, in a fixed order, hashed by content only (path-independent, the same rule as
# packages/inputhash.sh). guest.pin is not one of them: its version is pinned to builder.pin's
# snapshot above, and a revision bump changes no built byte.
inputs=("$MX86_DIR/build.sh" "$MX86_DIR/container-build.sh" "$MX86_DIR/pacman-snapshot.sh" "$MX86_DIR/lib.sh"
        "$MX86_DIR/builder.pin" "$MX86_MESA/PKGBUILD" "$MX86_MESA/source.pin")
for p in $PATCHES; do inputs+=("$MX86_MESA/patches/$p"); done
HASH="$(sha256sum "${inputs[@]}" | cut -d' ' -f1 | sha256sum | cut -c1-64)"

complete() {
  local d f
  for d in lib lib32; do
    for f in libvulkan_freedreno.so libEGL_mesa.so.0 libGLX_mesa.so.0 "libgallium-$MESA_VERSION.so" dri/msm_dri.so; do
      [ -e "$WORKDIR/payload/usr/$d/$f" ] || return 1
    done
  done
  [ -s "$WORKDIR/payload/usr/share/vulkan/icd.d/freedreno_icd.x86_64.json" ] &&
  [ -s "$WORKDIR/payload/usr/share/vulkan/icd.d/freedreno_icd.i686.json" ] &&
  [ -s "$WORKDIR/payload.conf" ]
}

full=0
[ "$STAGE" = build ] && [ "$ARCHES" = "x86_64 i686" ] && full=1
if [ "$full" = 1 ] && [ "$(cat "$MARKER" 2>/dev/null)" = "$HASH" ] && complete; then
  echo "[mesa-x86] cached (inputs unchanged): $WORKDIR/payload" >&2
  exit 0
fi

ctr_require "the x86 guest Mesa build"
echo "[mesa-x86] $STAGE ($ARCHES) mesa $MESA_VERSION in $IMAGE, snapshot $SNAPSHOT" >&2
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

ctr run --rm --platform linux/amd64 \
  -v "$ROOT":/repo:ro \
  -v "$WORKDIR":/out \
  -e SNAPSHOT="$SNAPSHOT" -e PATCHES="$PATCHES" -e MESA_VERSION="$MESA_VERSION" \
  -e STAGE="$STAGE" -e ARCHES="$ARCHES" \
  -e HOST_UID="$(ctr_host_owner | cut -d: -f1)" -e HOST_GID="$(ctr_host_owner | cut -d: -f2)" \
  "$IMAGE" bash /repo/packages/mesa-x86/container-build.sh

[ "$STAGE" = build ] || exit 0
if [ "$full" = 1 ]; then
  # What steam-x86-guest reads: it lays the payload only over a guest no older than this snapshot.
  printf 'snapshot=%s\nmesa=%s\n' "${SNAPSHOT//\//-}" "$MESA_VERSION" >"$WORKDIR/payload.conf"
  complete || { echo "ERROR: the container reported success but the payload is incomplete" >&2; exit 1; }
  printf '%s\n' "$HASH" >"$MARKER"
fi
echo "[mesa-x86] built -> $WORKDIR/payload" >&2
