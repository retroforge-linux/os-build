#!/usr/bin/env bash
# Upload to source-mirror every file and git commit of the lock that it does not have yet.
#
#   tools/source-mirror/sync.sh [--dry-run] [--repo OWNER/NAME] [LOCK]
#
# Needs gh, authenticated with write access to the repo's releases: GH_TOKEN in CI (os-build's
# source-mirror job before every build, and the mirror repo's own daily workflow). Defaults:
# retroforge-linux/source-mirror, mirror/sources.lock.
#
# Each row names its <release>/<asset> (see tools/source-mirror/lock.py): releases by kind
# (sources, prebuilt, fex-rootfs, git, archlinux-<date>-<repo>), assets under their own names. A
# release the lock needs and the repo lacks is created. Every upload is checked first: a file must
# hash to its row, a bundle must clone and hold its commit. An upstream that changed under a
# pinned hash is reported and skipped, never uploaded. An asset already there counts only if
# GitHub's sha256 digest for it is the row's (a bundle: if it is there at all, its commit is in
# its name); one that holds other bytes under the row's name is reported, not replaced.
set -uo pipefail

DRY=0; REPO="retroforge-linux/source-mirror"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    -*) echo "usage: $0 [--dry-run] [--repo OWNER/NAME] [LOCK]" >&2; exit 2 ;;
    *) break ;;
  esac
done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="${1:-$HERE/../../mirror/sources.lock}"
[ -f "$LOCK" ] || { echo "no lock: $LOCK" >&2; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
log() { echo "[sync] $*" >&2; }
hash_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
notes() {  # notes RELEASE
  local what
  case "$1" in
    sources)      what="Source tarballs: the kernel, mesa and every PKGBUILD source, under the names makepkg gives them." ;;
    prebuilt)     what="Prebuilt downloads named by packages/*/prebuilt.pin." ;;
    fex-rootfs)   what="The FEX guest RootFS packages/mesa-x86/guest.pin names, as <name>-<version>." ;;
    git)          what="Git sources as bundles, <dir>[-<tag>]-<commit>.bundle: each holds that commit (and tag)." ;;
    archlinux-*)  what="Arch Linux Archive files the x86 Mesa builder's pacman installs from snapshot ${1#archlinux-} (an epoch's ':' is '_' in the asset name)." ;;
    *)            what="Build inputs." ;;
  esac
  echo "$what Copies of retroforge-linux/os-build's build inputs, listed in its mirror/sources.lock with their sha256 (git: commit); os-build's tools/source-mirror/rf-fetch checks every file it takes from here. See tools/source-mirror/README.md there."
}

# Every release the lock needs, and what each holds: asset name -> sha256 digest (may be empty).
declare -A HAVE=()
for rel in $(awk '$1 !~ /^#/ && NF >= 4 { split($4, a, "/"); print a[1] }' "$LOCK" | sort -u); do
  if ! id="$(gh api "repos/$REPO/releases/tags/$rel" -q .id 2>/dev/null)"; then
    if [ "$DRY" = 1 ]; then log "would create release $rel"; continue; fi
    gh release create "$rel" --repo "$REPO" --title "$rel" --notes "$(notes "$rel")" >/dev/null ||
      { log "could not create release $rel"; exit 1; }
    id="$(gh api "repos/$REPO/releases/tags/$rel" -q .id)"
  fi
  while read -r name digest; do
    [ -n "$name" ] && HAVE["$rel/$name"]="${digest:-?}"
  done < <(gh api --paginate "repos/$REPO/releases/$id/assets?per_page=100" -q '.[] | .name + " " + ((.digest // "") | sub("^sha256:"; ""))')
done
log "the mirror holds ${#HAVE[@]} of the lock's release assets' names"

upload() {  # upload FILE RELEASE/ASSET
  local rel="${2%%/*}" name="${2#*/}" up="$WORK/up/${2#*/}"
  mkdir -p "$WORK/up"; mv -f "$1" "$up"
  gh release upload "$rel" "$up" --repo "$REPO" >/dev/null && { log "uploaded $2"; uploaded=$((uploaded + 1)); }
  local rc=$?; rm -f "$up"; return $rc
}

bundle() {  # bundle COMMIT URL FRAG OUT
  local commit="$1" url="$2" frag="$3" out="$4" src="$WORK/src" tag="" refs
  rm -rf "$src"
  git clone --quiet --mirror "$url" "$src" || return 1
  git -C "$src" cat-file -e "$commit^{commit}" 2>/dev/null || { log "$url has no $commit"; return 1; }
  git -C "$src" update-ref refs/heads/rf-mirror "$commit"
  git -C "$src" symbolic-ref HEAD refs/heads/rf-mirror
  refs=(HEAD refs/heads/rf-mirror)
  case "$frag" in
    tag=*|commit=*)
      tag="${frag#*=}"
      git -C "$src" show-ref --verify -q "refs/tags/$tag" && refs+=("refs/tags/$tag") ;;
  esac
  git -C "$src" bundle create "$out" "${refs[@]}" 2>/dev/null || return 1
  rm -rf "$src"
  # The check rf-seed makes: it clones, and holds the commit (and the tag resolves to it).
  git clone --quiet --mirror "$out" "$src" && git -C "$src" cat-file -e "$commit^{commit}" || return 1
  if [ -n "$tag" ] && [ "$(git -C "$src" rev-parse -q --verify "$tag^{commit}")" != "$commit" ]; then
    log "$url: $tag is not $commit"; return 1
  fi
  rm -rf "$src"
}

missing=0; failed=0; uploaded=0
while read -r key kind url loc rest; do
  case "$key" in ''|\#*) continue ;; esac
  case "$kind" in file|arch|git) ;; *) log "unknown row kind $kind for $url"; failed=$((failed + 1)); continue ;; esac
  case "$loc" in */*) ;; *) log "row for $url has no <release>/<asset>"; failed=$((failed + 1)); continue ;; esac
  have="${HAVE[$loc]:-}"
  if [ -n "$have" ]; then
    [ "$kind" = git ] || [ "$have" = "?" ] || [ "$have" = "$key" ] && continue
    log "FAILED: $loc holds sha256 $have, the lock wants $key ($url): left as it is"
    failed=$((failed + 1)); continue
  fi
  missing=$((missing + 1))
  if [ "$DRY" = 1 ]; then log "missing: $loc ($url)"; continue; fi
  tmp="$WORK/obj"
  if [ "$kind" = git ]; then
    frag="$(awk '{ print $2 }' <<<"$rest")"
    bundle "$key" "$url" "$frag" "$tmp" && upload "$tmp" "$loc" || { log "FAILED: $url @ $key"; failed=$((failed + 1)); }
  else
    if ! curl --fail --location --silent --show-error --connect-timeout 20 --retry 3 \
         --retry-connrefused --output "$tmp" "$url"; then
      log "FAILED: could not fetch $url"; failed=$((failed + 1)); continue
    fi
    got="$(hash_of "$tmp")"
    if [ "$got" != "$key" ]; then
      log "FAILED: $url hashes to $got, not the locked $key: not uploaded"; failed=$((failed + 1))
      rm -f "$tmp"; continue
    fi
    upload "$tmp" "$loc" || { log "FAILED: upload of $loc"; failed=$((failed + 1)); }
  fi
done <"$LOCK"
if [ "$DRY" = 1 ]; then log "$missing missing"
else log "$missing missing, $uploaded uploaded, $failed failed"; fi
[ "$failed" -eq 0 ]
