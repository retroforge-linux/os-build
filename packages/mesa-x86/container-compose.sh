#!/usr/bin/env bash
# mesa-x86 compose, container half: runs INSIDE the ./builder.pin image as root, started by
# ./compose.sh. Unpacks the guest, lays the payload over it, proves the guest now uses our Mesa,
# and packs it again.
#
# Expects: the repo read-only at /repo, the verified guest image at /guest.sqsh, the payload
# read-only at /payload, a writable /out, and in the environment
#   SNAPSHOT, ASSET, VERSION, MESA_VERSION, PATCHES, BASE_NAME, BASE_VERSION, BASE_URL, BASE_SHA256,
#   HOST_UID, HOST_GID, and optionally SOURCE_DATE_EPOCH.
#
# Root because unsquashfs and mksquashfs must keep the guest's owners and modes exactly, and
# because the closure check below runs the guest's own dynamic loader in a chroot.
set -euo pipefail

: "${SNAPSHOT:?}" "${ASSET:?}" "${VERSION:?}" "${MESA_VERSION:?}" "${BASE_SHA256:?}"
: "${HOST_UID:?}" "${HOST_GID:?}"
ROOTFS=/work/root
trap 'chown -R "$HOST_UID:$HOST_GID" /out 2>/dev/null || true' EXIT

log()  { printf '[fex-guest] %s\n' "$*" >&2; }
fail() { echo "ERROR: fex-guest: $*" >&2; exit 1; }

/repo/packages/mesa-x86/pacman-snapshot.sh "$SNAPSHOT"
pacman -S --noconfirm --needed squashfs-tools python

# --- unpack -----------------------------------------------------------------------------------
rm -rf /work && mkdir -p /work
log "unsquashfs $BASE_NAME $BASE_VERSION"
unsquashfs -no-progress -d "$ROOTFS" /guest.sqsh >/dev/null

# One timestamp for everything we write, so the same guest and payload give the same image.
# Default: the guest's own creation time, which the guest pin fixes.
# Held in EPOCH and removed from the environment: mksquashfs refuses SOURCE_DATE_EPOCH together
# with -mkfs-time, even set to the same value.
EPOCH="${SOURCE_DATE_EPOCH:-}"
unset SOURCE_DATE_EPOCH
if [ -z "$EPOCH" ]; then
  created="$(unsquashfs -s /guest.sqsh | sed -n 's/^Creation or last append time //p')"
  EPOCH="$(date -u -d "$created" +%s)" || fail "cannot read the guest's creation time"
fi
log "timestamp $EPOCH ($(date -u -d "@$EPOCH" '+%F %T') UTC)"

# --- overlay + prove --------------------------------------------------------------------------
# Who owns what in the guest (FEX's image: everything uid/gid 1000). Nothing we write may add an
# owner to that set; checked again after the cache rebuild below.
owners() { find "$ROOTFS" -printf '%U:%G\n' | sort -u | tr '\n' ' '; }
owners_before="$(owners)"

# A record inside the image of what it is, for whoever is looking at a mounted guest on a device.
cat >/work/fex-guest.release <<EOF
RETROFORGE_FEX_GUEST_VERSION=$VERSION
MESA_VERSION=$MESA_VERSION
MESA_PATCHES="$PATCHES"
BASE_NAME=$BASE_NAME
BASE_VERSION=$BASE_VERSION
BASE_URL=$BASE_URL
BASE_SHA256=$BASE_SHA256
EOF
python3 -I /repo/packages/mesa-x86/guest-overlay.py "$ROOTFS" /payload \
  --epoch "$EPOCH" \
  --add usr/share/retroforge/fex-guest.release=/work/fex-guest.release \
  --add usr/share/drirc.d/02-retroforge-turnip-autotune.conf=/repo/rootfs/overlay/usr/share/drirc.d/02-retroforge-turnip-autotune.conf \
  --report /work/overlay.txt

# --- the guest's library cache ----------------------------------------------------------------
# libgallium-<version>.so is a new soname. glibc would find it in /usr/lib(32) without a cache
# entry, but a graphics provider is expected to carry an ld.so.cache that knows its libraries
# (pressure-vessel reads it). -X: rebuild the cache only. Without it ldconfig would also re-point
# soname links at the newest file it finds, e.g. FEX's libdrm.so.2 -> 2.133.0 at Arch's 2.134.0.
# ldconfig writes a new file as root; it keeps the old cache's owner and mode (FEX's image is all
# uid 1000), so the image's id table stays the guest's.
etc_mtime="$(stat -c %Y "$ROOTFS/etc")"
cache_owner="$(stat -c %u:%g "$ROOTFS/etc/ld.so.cache")"
cache_mode="$(stat -c %a "$ROOTFS/etc/ld.so.cache")"
ldconfig -X -r "$ROOTFS"
chown "$cache_owner" "$ROOTFS/etc/ld.so.cache"
chmod "$cache_mode" "$ROOTFS/etc/ld.so.cache"
touch -d "@$EPOCH" "$ROOTFS/etc/ld.so.cache"
touch -d "@$etc_mtime" "$ROOTFS/etc"
for lib in lib lib32; do
  ldconfig -p -C "$ROOTFS/etc/ld.so.cache" | grep -q "libgallium-$MESA_VERSION.so .*=> /usr/$lib/libgallium-$MESA_VERSION.so\$" \
    || fail "the rebuilt ld.so.cache has no /usr/$lib/libgallium-$MESA_VERSION.so"
done

[ "$(owners)" = "$owners_before" ] \
  || fail "the guest's owners changed from [ $owners_before] to [ $(owners)]"

# --- every library we added loads in the guest ------------------------------------------------
# The guest's own ld.so, chrooted, with every symbol bound now (ldd -r): a NEEDED the guest does
# not ship, or a symbol its glibc/libdrm/libxcb is too old for, fails here instead of making the
# Vulkan loader drop the ICD without a word on a device.
#
# i386 code must be executable for the lib32 half. It is on an x86_64 host (CI), and it was under
# Docker Desktop's amd64 emulation on an Apple-silicon Mac (2026-10-16). Where it is not,
# MX86_SKIP_I386_EXEC=1 skips that half, loudly, for a local dry run.
check_loads() {  # <loader> <guest path>
  local out
  out="$(chroot "$ROOTFS" /usr/bin/env -i LD_TRACE_LOADED_OBJECTS=1 LD_WARN=yes LD_BIND_NOW=yes \
           "$1" "$2" 2>&1)" || { printf '%s\n' "$out" >&2; fail "$2 does not load in the guest"; }
  if grep -E 'not found|undefined symbol|version .* not found' <<<"$out" >&2; then
    fail "$2 does not load in the guest (above)"
  fi
}
i386_ok=1
if ! chroot "$ROOTFS" /usr/lib32/ld-linux.so.2 --version >/dev/null 2>&1; then
  if [ "${MX86_SKIP_I386_EXEC:-0}" = 1 ]; then
    i386_ok=0
    log "WARNING: this host cannot run i386 code; the lib32 closure check is SKIPPED (MX86_SKIP_I386_EXEC=1)"
  else
    fail "this host cannot run the guest's i386 loader, so the lib32 half cannot be checked. Run on an x86_64 host, or set MX86_SKIP_I386_EXEC=1 for a local dry run."
  fi
fi
checked=0
while IFS= read -r -d '' so; do
  rel="/${so#/payload/}"
  case "$rel" in
    /usr/lib/*)   check_loads /usr/lib/ld-linux-x86-64.so.2 "$rel" ;;
    /usr/lib32/*) [ "$i386_ok" = 1 ] || continue; check_loads /usr/lib32/ld-linux.so.2 "$rel" ;;
    *) continue ;;
  esac
  checked=$((checked + 1))
done < <(find /payload -type f -name '*.so*' -print0 | sort -z)
[ "$checked" -gt 0 ] || fail "no library in the payload was checked"
log "$checked libraries load in the guest with every symbol bound"

# --- pack ---------------------------------------------------------------------------------------
# FEX's own settings (zstd, 128 KiB blocks, no xattrs), and the fixed timestamp for the superblock.
# The output is a function of the guest and the payload: mksquashfs is reproducible given the same
# tree, and every time in the tree is the guest's own or EPOCH.
mkdir -p /out
rm -f "/out/$ASSET" "/out/$ASSET.part"
log "mksquashfs -> $ASSET"
mksquashfs "$ROOTFS" "/out/$ASSET.part" -noappend -comp zstd -b 131072 -no-xattrs \
  -mkfs-time "$EPOCH" -quiet -no-progress
mv "/out/$ASSET.part" "/out/$ASSET"
(cd /out && sha256sum "$ASSET" >"$ASSET.sha256")
cp /work/fex-guest.release "/out/$ASSET.release"
cp /work/overlay.txt "/out/$ASSET.overlay.txt"
cat "/out/$ASSET.sha256" >&2
