#!/usr/bin/env bash
# Offline check for source-mirror's fetchers (tools/source-mirror/rf-fetch and rf-seed) and its
# lock (mirror/sources.lock).
#
#   tests/test-source-mirror.sh
#
# WHY THIS EXISTS. The mirror sits in front of every pinned download of the build, mirror first.
# Its whole safety argument is that it is checked, never trusted: a copy that does not hash to
# the pin is refused, whichever host served it. A fetcher that stopped checking would turn the
# mirror into the one place a build input could be swapped, silently; one that stopped falling
# back would turn a GitHub outage into a dead build. Both fail quietly, so both are pinned here,
# against a fake mirror and a fake upstream on file:// URLs.
#
# Runs on the host with no root, no device, no build and no network.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FETCH="$ROOT/tools/source-mirror/rf-fetch"
SEED="$ROOT/tools/source-mirror/rf-seed"
LOCK="$ROOT/mirror/sources.lock"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
hash_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/mirror" "$T/up" "$T/out"
export RF_MIRROR_BASE="file://$T/mirror" RF_MIRROR_LOCK="$T/lock"
: >"$T/lock"
put_mirror() {  # put_mirror FILE RELEASE/ASSET: store FILE where the lock row says, as sync.sh does
  mkdir -p "$(dirname "$T/mirror/$2")"; cp "$1" "$T/mirror/$2"
}
echo "good bytes" >"$T/up/a.tar"; A="$(hash_of "$T/up/a.tar")"
echo "evil bytes" >"$T/evil"
UA="file://$T/up/a.tar"
row() { echo "$A file $UA sources/a-1.tar test" >"$T/lock"; }

echo "rf-fetch"
row; put_mirror "$T/up/a.tar" sources/a-1.tar; mv "$T/up/a.tar" "$T/up/a.away"
"$FETCH" "$T/out/1" "$UA" 2>/dev/null && [ "$(hash_of "$T/out/1")" = "$A" ] \
  && ok "a locked file comes from its named copy (sources/a-1.tar), upstream untouched" || bad "mirror fetch"
mv "$T/up/a.away" "$T/up/a.tar"
"$FETCH" --sha256 "$A" "$T/out/1b" "$UA" 2>/dev/null && [ "$(hash_of "$T/out/1b")" = "$A" ] \
  && ok "--sha256 that agrees with the row: the same copy" || bad "--sha256 agreeing"
rm -rf "$T/mirror"/*
"$FETCH" "$T/out/2" "$UA" 2>/dev/null && [ "$(hash_of "$T/out/2")" = "$A" ] \
  && ok "not on the mirror: upstream, checked" || bad "upstream fallback"
put_mirror "$T/evil" sources/a-1.tar
"$FETCH" "$T/out/3" "$UA" 2>"$T/err" && [ "$(hash_of "$T/out/3")" = "$A" ] \
  && grep -q 'refused' "$T/err" && ok "a mirror copy with the wrong bytes is refused, upstream used" \
  || bad "wrong mirror bytes: $(cat "$T/err")"
cp "$T/evil" "$T/up/b.tar"
! "$FETCH" --sha256 "$A" "$T/out/4" "file://$T/up/b.tar" 2>/dev/null && [ ! -e "$T/out/4" ] && [ ! -e "$T/out/4.rf-part" ] \
  && ok "both wrong: exit 1, nothing left behind" || bad "both wrong"
rm -rf "$T/mirror"/*
! RF_MIRROR=only "$FETCH" "$T/out/5" "$UA" 2>/dev/null \
  && ok "RF_MIRROR=only does not fall back" || bad "RF_MIRROR=only fell back"
put_mirror "$T/evil" sources/a-1.tar
RF_MIRROR=off "$FETCH" "$T/out/6" "$UA" 2>"$T/err" && ! grep -q refused "$T/err" \
  && ok "RF_MIRROR=off never asks the mirror" || bad "RF_MIRROR=off"
rm -rf "$T/mirror"/*; put_mirror "$T/up/a.tar" sources/a-1.tar
echo "$(hash_of "$T/evil") file $UA sources/a-1.tar stale" >"$T/lock"
"$FETCH" --sha256 "$A" "$T/out/7" "$UA" 2>/dev/null && [ "$(hash_of "$T/out/7")" = "$A" ] && \
  ! RF_MIRROR=only "$FETCH" --sha256 "$A" "$T/out/7b" "$UA" 2>/dev/null \
  && ok "a lock row that disagrees with --sha256 (stale lock) is ignored: upstream, checked" || bad "stale row"
echo "$A arch file://$T/locked/p-1:2-x86_64.pkg.tar.zst archlinux-2026.08.11-core/p-1_2-x86_64.pkg.tar.zst 11" >"$T/lock"
put_mirror "$T/up/a.tar" archlinux-2026.08.11-core/p-1_2-x86_64.pkg.tar.zst
"$FETCH" "$T/out/8" "file://$T/locked/p-1:2-x86_64.pkg.tar.zst" 2>/dev/null && [ "$(hash_of "$T/out/8")" = "$A" ] \
  && ok "an arch row (epoch ':' as '_' in the asset) serves pacman's URL" || bad "arch row lookup"
: >"$T/lock"
"$FETCH" "$T/out/9" "file://$T/up/b.tar" 2>/dev/null && [ "$(hash_of "$T/out/9")" = "$(hash_of "$T/evil")" ] \
  && ok "an unpinned URL is fetched as it is (as before the mirror)" || bad "unpinned fetch"
RF_FETCH_RECORD="$T/rec" "$FETCH" --sha256 "$A" "$T/out/10" "$UA" 2>/dev/null
[ "$(cat "$T/rec" 2>/dev/null)" = "$A 11 $UA" ] \
  && ok "RF_FETCH_RECORD logs sha256, bytes and URL" || bad "record: $(cat "$T/rec" 2>&1)"
! "$FETCH" --sha256 nothex "$T/out/11" "$UA" 2>/dev/null \
  && ok "a malformed sha256 is an error" || bad "malformed sha256 accepted"

echo "rf-seed"
S="$T/stage"; mkdir -p "$S"
cat >"$S/PKGBUILD" <<EOF
pkgname=demo
source=("demo-1.tar::file://$T/up/a.tar"
        "git+file://$T/repo.git#tag=v1"
        "local.patch")
sha256sums=('$A' 'SKIP' 'SKIP')
EOF
git init -q "$T/work" && git -C "$T/work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one &&
  git -C "$T/work" tag v1 && git clone -q --bare "$T/work" "$T/repo.git"
C="$(git -C "$T/work" rev-parse HEAD)"
git -C "$T/work" update-ref refs/heads/rf-mirror "$C"
git -C "$T/work" bundle create -q "$T/bundle" refs/heads/rf-mirror refs/tags/v1 2>/dev/null
put_mirror "$T/bundle" "git/repo-v1-${C:0:12}.bundle"
echo "$C git file://$T/repo.git git/repo-v1-${C:0:12}.bundle repo tag=v1 demo" >"$T/lock"
"$SEED" "$S" aarch64 2>"$T/err"
[ "$(hash_of "$S/demo-1.tar" 2>/dev/null)" = "$A" ] && ok "a tarball is seeded under makepkg's filename (name::url)" \
  || bad "tarball not seeded: $(cat "$T/err")"
[ "$(git -C "$S/repo" config --get remote.origin.url 2>/dev/null)" = "file://$T/repo.git" ] &&
  [ "$(git -C "$S/repo" rev-parse 'v1^{commit}' 2>/dev/null)" = "$C" ] && grep -q "from the mirror" "$T/err" \
  && ok "a git source becomes makepkg's bare clone from the bundle, origin = the source URL" \
  || bad "git seed: $(cat "$T/err")"
S2="$T/stage2"; mkdir -p "$S2"; sed "s/tag=v1/tag=v2/" "$S/PKGBUILD" >"$S2/PKGBUILD"
"$SEED" "$S2" aarch64 2>/dev/null; [ ! -e "$S2/repo" ] \
  && ok "a fragment the lock does not pin is left to makepkg" || bad "seeded an unlocked fragment"
S3="$T/stage3"; mkdir -p "$S3"; sed "s/'$A'/'$(hash_of "$T/evil")'/" "$S/PKGBUILD" >"$S3/PKGBUILD"
! "$SEED" "$S3" aarch64 2>/dev/null && ok "a tarball nothing serves with its sha256 stops the build" \
  || bad "a mismatched tarball was let through to makepkg's --skipinteg"
S4="$T/stage4"; mkdir -p "$S4"; sed "s/'$A'/'SKIP'/" "$S/PKGBUILD" >"$S4/PKGBUILD"
"$SEED" "$S4" aarch64 2>/dev/null && [ ! -e "$S4/demo-1.tar" ] \
  && ok "a source with no sha256 and no lock row is left to makepkg" || bad "no-sha source"

echo "the lock"
if [ -f "$LOCK" ]; then
  bad_rows="$(grep -v '^#' "$LOCK" | awk '
    $1 !~ /^[0-9a-f]+$/ || $4 !~ /^[a-z0-9.-]+\/[A-Za-z0-9._-]+$/ { print; next }
    ($2 == "file" || $2 == "arch") && (length($1) != 64 || NF != 5) { print; next }
    $2 == "git" && (length($1) != 40 || NF != 7) { print; next }
    $2 != "file" && $2 != "arch" && $2 != "git" { print }')"
  [ -z "$bad_rows" ] && ok "every row is <hash> <kind> <url> <release>/<asset> <...>, asset names GitHub keeps" \
    || bad "malformed rows: $bad_rows"
  dup="$(grep -v '^#' "$LOCK" | awk '{ print $4, $1 }' | sort -u | awk '{ print $1 }' | uniq -d)"
  [ -z "$dup" ] && ok "no release asset is wanted with two different hashes" || bad "contested assets: $dup"
  k="$(awk '/^[^#]/ && $3 ~ /linux-[0-9.]+\.tar\.xz$/ { print $1 }' "$LOCK")"
  [ "$k" = "$(sed -n 's/^sha256:[[:space:]]*//p' "$ROOT/kernel/SOURCE.pin")" ] \
    && ok "the kernel row is kernel/SOURCE.pin's sha256 (lock.py is current for it)" || bad "kernel row: $k"
else
  bad "no mirror/sources.lock"
fi
for f in kernel/build.sh packages/mesa/fetch-source.sh packages/mesa-x86/compose.sh rootfs/customize-base.sh \
         packages/build-overlay.sh packages/mesa-x86/pacman-snapshot.sh; do
  grep -q 'tools/source-mirror/rf-' "$ROOT/$f" && ok "$f fetches through source-mirror" || bad "$f bypasses source-mirror"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
