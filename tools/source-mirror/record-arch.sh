#!/usr/bin/env bash
# Record every Arch Linux Archive file the x86 Mesa builder's pacman fetches, for the lock's arch
# rows, then rewrite mirror/sources.lock with them.
#
#   tools/source-mirror/record-arch.sh
#
# Runs what packages/mesa-x86/container-build.sh and container-compose.sh install, in the same
# pinned image (packages/mesa-x86/builder.pin, linux/amd64) with the same snapshot, through
# pacman-snapshot.sh's XferCommand (rf-fetch) with RF_FETCH_RECORD set: so the rows are exactly
# the database and package files a build downloads, each with the sha256 it had. Re-run after a
# builder.pin bump or a change to either container script's package list.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/build/lib-container.sh"
IMAGE="$(sed -n 's/^image:[[:space:]]*//p' "$ROOT/packages/mesa-x86/builder.pin")"
SNAPSHOT="$(sed -n 's/^snapshot:[[:space:]]*//p' "$ROOT/packages/mesa-x86/builder.pin")"
# The builder's deps=( ... ) and the compose step's own install, read from the scripts that run them.
DEPS="$(awk '/^deps=\(/ { f = 1; next } f && /^\)/ { exit } f' "$ROOT/packages/mesa-x86/container-build.sh" | tr '\n' ' ')"
COMPOSE="$(sed -n 's/^pacman -S --noconfirm --needed //p' "$ROOT/packages/mesa-x86/container-compose.sh")"
[ -n "$DEPS" ] && [ -n "$COMPOSE" ] || { echo "could not read the package lists" >&2; exit 1; }

OUT="$ROOT/work/source-mirror"; mkdir -p "$OUT"; rm -f "$OUT/arch-record.txt"
ctr_require "recording the x86 builder's pacman downloads"
ctr run --rm --platform linux/amd64 \
  -v "$ROOT":/repo:ro -v "$OUT":/out \
  -e RF_FETCH_RECORD=/out/arch-record.txt -e RF_MIRROR="${RF_MIRROR:-on}" \
  "$IMAGE" bash -c "
    set -e
    /repo/packages/mesa-x86/pacman-snapshot.sh '$SNAPSHOT'
    pacman -S --noconfirm --needed $DEPS
    pacman -S --noconfirm --needed $COMPOSE
  "
# Only what came from the archive (a .sig the archive lacks is simply not recorded).
grep " https://archive.archlinux.org/repos/$SNAPSHOT/" "$OUT/arch-record.txt" | sort -u -k3 > "$OUT/arch-record.sorted"
echo "[record-arch] $(wc -l < "$OUT/arch-record.sorted") archive files" >&2
python3 "$ROOT/tools/source-mirror/lock.py" --arch-record "$OUT/arch-record.sorted"
