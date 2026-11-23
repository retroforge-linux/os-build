#!/usr/bin/env bash
# Offline checks for the downloadable FEX guest (packages/mesa-x86).
#
#   tests/test-fex-guest.sh
#
# WHAT IS AT RISK. The guest is published once and then pinned by sha256 on devices, so a mistake
# ships to every x86 game and is invisible until one runs:
#   - an ICD or a GL library that does not resolve to OUR build means x86 games quietly run FEX's
#     unpatched Mesa (or no Vulkan at all) while the image looks right;
#   - an x86 file reaching the OS image breaks the "downloaded, not shipped" rule
#     (rootfs/guard-rootfs.sh section 9);
#   - a workflow that starts on its own would publish a release nobody asked for.
#
# guest-overlay.py is driven on fabricated trees (fake ELF headers, no real Mesa). The build and
# the compose themselves need docker and the network; they are checked by running them (README).
# Needs python3. No root, no network, no docker.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$ROOT/packages/mesa-x86"
OVERLAY="$D/guest-overlay.py"
WF="$ROOT/.github/workflows/release-fex-guest.yml"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

echo "names and pins"

# lib.sh is sourced by build.sh, compose.sh and the workflow; run it the same way here.
names="$(bash -c '. "$1"; mx86_version; mx86_asset; mx86_tag; mx86_mesa_version_string' _ "$D/lib.sh")"
pkgver="$(bash -c "source '$ROOT/packages/mesa/PKGBUILD' >/dev/null 2>&1; echo \"\$pkgver\"")"
rev="$(field "$D/guest.pin" revision)"
expect="$pkgver-$rev
retroforge-fex-guest-$pkgver-$rev.sqsh
fex-guest/v$pkgver-$rev"
[ "$(printf '%s\n' "$names" | head -3)" = "$expect" ] \
  && ok "version, asset and tag come from the mesa pkgver and guest.pin's revision ($pkgver-$rev)" \
  || bad "lib.sh names: got [$names], want [$expect]"
case "$(printf '%s\n' "$names" | sed -n 4p)" in
  "$pkgver-retroforge"*) ok "the guest's VERSION string is the host build's ($(printf '%s\n' "$names" | sed -n 4p))" ;;
  *) bad "mesa version string: $(printf '%s\n' "$names" | sed -n 4p)" ;;
esac

snap="$(field "$D/builder.pin" snapshot)"; gver="$(field "$D/guest.pin" version)"
[ -n "$snap" ] && [ "$snap" = "${gver//-//}" ] \
  && ok "builder.pin's snapshot is the guest's date ($snap)" \
  || bad "builder.pin snapshot '$snap' does not match guest.pin version '$gver'"
field "$D/builder.pin" image | grep -qE '^archlinux:base-devel-[0-9.]+@sha256:[0-9a-f]{64}$' \
  && ok "the builder image is pinned by tag and digest" \
  || bad "builder.pin image is not archlinux:base-devel-<date>@sha256:<digest>"
field "$D/guest.pin" sha256 | grep -qE '^[0-9a-f]{64}$' \
  && field "$D/guest.pin" url | grep -qE '^https://rootfs\.fex-emu\.gg/.+\.sqsh$' \
  && ok "guest.pin names a FEX squashfs over https with a sha256" \
  || bad "guest.pin url/sha256 malformed"

echo
echo "into the OS image only through the x86-mesa stage"

# customize-base.sh installs every packages/*/prebuilt.pin; build-overlay.sh builds every
# packages/*/source.pin. Either file here would put x86 Mesa (or the guest) into the root by a path
# nobody audits; the payload goes in through rootfs/lib-assemble-x86-mesa.sh alone, and the guest
# never does.
for f in prebuilt.pin source.pin PKGBUILD; do
  [ -e "$D/$f" ] && bad "packages/mesa-x86/$f exists -- the image build would pick it up"
done
[ ! -e "$D/prebuilt.pin" ] && [ ! -e "$D/source.pin" ] && [ ! -e "$D/PKGBUILD" ] \
  && ok "no prebuilt.pin, source.pin or PKGBUILD in packages/mesa-x86"

# One source of truth for the tarball and the patches: the host driver's.
grep -q '/repo/packages/mesa/fetch-source.sh' "$D/container-build.sh" \
  && ok "the source is packages/mesa/fetch-source.sh's verified tarball" \
  || bad "container-build.sh does not fetch through packages/mesa/fetch-source.sh"
grep -q 'mx86_patches' "$D/build.sh" && grep -q 'patches:\|source.pin' "$D/lib.sh" \
  && ok "the patch list is packages/mesa/source.pin's" \
  || bad "build.sh does not take its patches from packages/mesa/source.pin"

# The stage itself, on a fabricated payload: only our drivers, the guest's hidden behind them.
A="$T/assemble"; mkdir -p "$A/repo/work/mesa-x86/out" "$A/stage/usr/lib/retroforge"
P="$A/repo/work/mesa-x86/out/payload"
for lib in lib lib32; do
  mkdir -p "$P/usr/$lib/dri" "$P/usr/$lib/gbm"
  : >"$P/usr/$lib/dri/libdril_dri.so"; : >"$P/usr/$lib/gbm/dri_gbm.so"
  for n in msm kgsl apple rockchip zynqmp-dpsub; do ln -s libdril_dri.so "$P/usr/$lib/dri/${n}_dri.so"; done
done
mkdir -p "$P/usr/share/vulkan/icd.d"
: >"$P/usr/share/vulkan/icd.d/freedreno_icd.x86_64.json"; : >"$P/usr/share/vulkan/icd.d/freedreno_icd.i686.json"
echo "mesa: 26.3.1" >"$A/repo/work/mesa-x86/out/payload.conf"
REPO="$ROOT"
( ROOT="$A/repo"; stage="$A/stage"; OUT="$A/out"; . "$REPO/rootfs/lib-assemble-x86-mesa.sh" ) >/dev/null 2>&1   # chown to root fails unprivileged
X="$A/stage/usr/lib/retroforge/x86-mesa/root"
for lib in lib lib32; do
  [ "$(cd "$X/usr/$lib/dri" 2>/dev/null && ls -A | LC_ALL=C sort | tr '\n' ' ')" = ".wh..wh..opq kgsl_dri.so libdril_dri.so msm_dri.so " ] \
    && ok "usr/$lib/dri: msm, kgsl and libdril only, opaque over the guest's own driver names" \
    || bad "usr/$lib/dri: $(ls -A "$X/usr/$lib/dri" 2>&1 | tr '\n' ' ')"
  [ -e "$X/usr/$lib/gbm/dri_gbm.so" ] && ok "usr/$lib/gbm untouched" || bad "usr/$lib/gbm lost dri_gbm.so"
done
[ -e "$X/usr/share/vulkan/icd.d/.wh..wh..opq" ] && [ -e "$X/usr/share/vulkan/icd.d/freedreno_icd.x86_64.json" ] \
  && ok "the Vulkan ICD folder: ours, opaque over the guest's other drivers" || bad "icd.d: $(ls -A "$X/usr/share/vulkan/icd.d" 2>&1 | tr '\n' ' ')"
[ -L "$P/usr/lib/dri/apple_dri.so" ] && [ ! -e "$P/usr/lib/dri/.wh..wh..opq" ] \
  && ok "the payload itself is unchanged (compose.sh flattens it into a guest that has no overlay)" || bad "the payload was changed"

echo
echo "the workflow starts only by hand"

# Exactly one trigger, workflow_dispatch. Read the `on:` block: every key indented two spaces under
# it is a trigger.
triggers="$(awk '/^on:/{f=1;next} f&&/^[^ #]/{f=0} f&&/^  [a-z_]+:/{sub(/:.*/,"");gsub(/ /,"");print}' "$WF")"
[ "$triggers" = "workflow_dispatch" ] \
  && ok "release-fex-guest.yml has workflow_dispatch and no other trigger" \
  || bad "release-fex-guest.yml triggers: $(echo $triggers)"
awk '/^permissions:/{getline; print; exit}' "$WF" | grep -q 'contents: read' \
  && ok "the workflow's default token is read-only" \
  || bad "release-fex-guest.yml's top-level permissions are not contents: read"
grep -q '2 \* 1024 \* 1024 \* 1024' "$WF" && grep -q '2 \* 1024 \* 1024 \* 1024' "$D/compose.sh" \
  && ok "the 2 GiB release-asset cap is checked before upload" \
  || bad "no 2 GiB size check"

echo
echo "guest-overlay.py"

# A fake ELF: just the header bytes guest-overlay.py reads (class at 4, data at 5, machine at 18).
elf() {  # elf <file> <64|32>
  mkdir -p "$(dirname "$1")"
  if [ "$2" = 64 ]; then
    printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\003\000\076\000%s' "$3" >"$1"
  else
    printf '\177ELF\001\001\001\000\000\000\000\000\000\000\000\000\003\000\003\000%s' "$3" >"$1"
  fi
}
icd() {  # icd <file> <library_path> <32|64>
  mkdir -p "$(dirname "$1")"
  printf '{"ICD": {"api_version": "1.4.354", "library_arch": "%s", "library_path": "%s"}, "file_format_version": "1.0.1"}\n' \
    "$3" "$2" >"$1"
}

# A guest shaped like FEX's ArchLinux RootFS: merged /usr, lib -> usr/lib, FEX's Mesa in place.
mkguest() {
  local r="$1"
  mkdir -p "$r/usr/lib/dri" "$r/usr/lib32/dri" "$r/usr/lib/gconv" "$r/usr/lib32/gconv" "$r/etc"
  ln -s usr/lib "$r/lib"
  cat >"$r/graphics_provider.json" <<'EOF'
{"graphics_provider_v0": {"root": "./", "locales": false, "va_api": false, "vdpau": false,
 "architectures": {
  "x86_64-linux-gnu": {"dri": "/usr/lib/dri", "fallback_library_paths": ["/usr/lib"], "gconv": "/usr/lib/gconv"},
  "i386-linux-gnu": {"dri": "/usr/lib32/dri", "fallback_library_paths": ["/usr/lib32"], "gconv": "/usr/lib32/gconv"}}}}
EOF
  for l in lib:64 lib32:32; do
    d="${l%%:*}"; c="${l##*:}"
    elf "$r/usr/$d/libvulkan_freedreno.so" "$c" fex
    elf "$r/usr/$d/libEGL_mesa.so.0.0.0" "$c" fex
    elf "$r/usr/$d/libGLX_mesa.so.0.0.0" "$c" fex
    ln -s libEGL_mesa.so.0.0.0 "$r/usr/$d/libEGL_mesa.so.0"
    ln -s libGLX_mesa.so.0.0.0 "$r/usr/$d/libGLX_mesa.so.0"
  done
  icd "$r/usr/share/vulkan/icd.d/freedreno_icd.x86_64.json" /usr/lib/libvulkan_freedreno.so 64
  icd "$r/usr/share/vulkan/icd.d/freedreno_icd.i686.json" /usr/lib32/libvulkan_freedreno.so 32
  touch -d '2026-08-11 18:34:00' "$r/usr/lib" "$r/usr/lib32" "$r/usr/share/vulkan/icd.d"
}
mkpayload() {
  local p="$1"
  for l in lib:64 lib32:32; do
    d="${l%%:*}"; c="${l##*:}"
    elf "$p/usr/$d/libvulkan_freedreno.so" "$c" ours
    elf "$p/usr/$d/libEGL_mesa.so.0.0.0" "$c" ours
    elf "$p/usr/$d/libGLX_mesa.so.0.0.0" "$c" ours
    elf "$p/usr/$d/libgallium-26.2.4-retroforge1.2.1.so" "$c" ours
    elf "$p/usr/$d/libVkLayer_MESA_vram_report_limit.so" "$c" ours
    ln -s libEGL_mesa.so.0.0.0 "$p/usr/$d/libEGL_mesa.so.0"
    ln -s libGLX_mesa.so.0.0.0 "$p/usr/$d/libGLX_mesa.so.0"
  done
  icd "$p/usr/share/vulkan/icd.d/freedreno_icd.x86_64.json" /usr/lib/libvulkan_freedreno.so 64
  icd "$p/usr/share/vulkan/icd.d/freedreno_icd.i686.json" /usr/lib32/libvulkan_freedreno.so 32
  layer "$p/usr/share/vulkan/implicit_layer.d/VkLayer_MESA_vram_report_limit.json" libVkLayer_MESA_vram_report_limit.so
}
layer() {  # layer <file> <library_path>
  mkdir -p "$(dirname "$1")"
  printf '{"file_format_version": "1.0.0", "layer": {"name": "VK_LAYER_MESA_vram_report_limit", "library_path": "%s", "enable_environment": {"ENABLE_MESA_VRAM_REPORT_LIMIT": "1"}}}\n' "$2" >"$1"
}
EPOCH=1786473325
run() {  # run <case dir> [extra args]
  local c="$1"; shift
  python3 -I "$OVERLAY" "$c/root" "$c/payload" --epoch "$EPOCH" --report "$c/report" "$@" >"$c/log" 2>&1
}
fresh() { rm -rf "$T/$1"; mkguest "$T/$1/root"; mkpayload "$T/$1/payload"; }

fresh good
printf 'RETROFORGE_FEX_GUEST_VERSION=x\n' >"$T/good/rel"
lib_mtime_before="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$T/good/root/usr/lib")"
if run "$T/good" --add usr/share/retroforge/fex-guest.release="$T/good/rel"; then
  ok "a FEX-shaped guest takes the payload and its ICDs and GL resolve to ours"
else
  bad "the happy path failed: $(cat "$T/good/log")"
fi
cmp -s "$T/good/root/usr/lib32/libvulkan_freedreno.so" "$T/good/payload/usr/lib32/libvulkan_freedreno.so" \
  && ok "the i686 Turnip in the guest is ours" || bad "the i686 Turnip was not replaced"
grep -qx 'add /usr/lib/libgallium-26.2.4-retroforge1.2.1.so' "$T/good/report" \
  && grep -qx 'replace /usr/lib/libvulkan_freedreno.so' "$T/good/report" \
  && grep -qx 'add /usr/share/retroforge/fex-guest.release' "$T/good/report" \
  && ok "the report says what was replaced and what was added" \
  || bad "report: $(tr '\n' ' ' <"$T/good/report" 2>/dev/null)"
[ "$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$T/good/root/usr/lib")" = "$lib_mtime_before" ] \
  && ok "directories written into keep their mtime (same inputs, same image)" \
  || bad "usr/lib's mtime changed"
[ "$(python3 -c 'import os,sys; print(int(os.lstat(sys.argv[1]).st_mtime))' "$T/good/root/usr/lib/libEGL_mesa.so.0")" = "$EPOCH" ] \
  && [ "$(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$T/good/root/usr/lib/libgallium-26.2.4-retroforge1.2.1.so")" = "$EPOCH" ] \
  && ok "every file it writes, symlinks included, carries the epoch" \
  || bad "written files do not carry --epoch"

# Bare library_path (what some guests ship): resolved through the arch's fallback paths.
fresh bare
icd "$T/bare/payload/usr/share/vulkan/icd.d/freedreno_icd.x86_64.json" libvulkan_freedreno.so 64
run "$T/bare" && ok "a bare-filename ICD resolves through fallback_library_paths" \
  || bad "bare ICD rejected: $(cat "$T/bare/log")"

# An absolute path through the guest's own /lib symlink resolves inside the guest, not the host.
fresh vialink
icd "$T/vialink/payload/usr/share/vulkan/icd.d/freedreno_icd.x86_64.json" /lib/libvulkan_freedreno.so 64
run "$T/vialink" && ok "/lib/... in an ICD follows the guest's lib -> usr/lib, not the host's" \
  || bad "symlinked ICD path rejected: $(cat "$T/vialink/log")"

expect_fail() {  # expect_fail <case> <grep pattern> <description>
  if run "$T/$1"; then
    bad "$3: accepted"
  elif grep -q "$2" "$T/$1/log"; then
    ok "$3"
  else
    bad "$3: failed for another reason: $(cat "$T/$1/log")"
  fi
}

fresh wrongicd
icd "$T/wrongicd/payload/usr/share/vulkan/icd.d/freedreno_icd.x86_64.json" /usr/lib/libvulkan_other.so 64
elf "$T/wrongicd/root/usr/lib/libvulkan_other.so" 64 fex
expect_fail wrongicd 'is not our libvulkan_freedreno.so' "an ICD naming any other library is refused"

fresh noicd
rm "$T/noicd/payload/usr/share/vulkan/icd.d/freedreno_icd.i686.json" "$T/noicd/root/usr/share/vulkan/icd.d/freedreno_icd.i686.json"
expect_fail noicd 'freedreno_icd.i686.json is missing' "a guest left without the i686 ICD is refused"

fresh dangling
icd "$T/dangling/payload/usr/share/vulkan/icd.d/freedreno_icd.i686.json" /usr/lib32/missing.so 32
expect_fail dangling 'does not resolve in the guest' "an ICD whose library does not exist is refused"

fresh wrongclass
elf "$T/wrongclass/payload/usr/lib32/libvulkan_freedreno.so" 64 ours
expect_fail wrongclass 'is not ELF32 i386' "an x86_64 library in lib32 is refused"

fresh noprovider
rm "$T/noprovider/root/graphics_provider.json"
expect_fail noprovider 'graphics_provider.json is missing' "a guest with no /graphics_provider.json is refused"

fresh noi386
python3 - "$T/noi386/root/graphics_provider.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
del d["graphics_provider_v0"]["architectures"]["i386-linux-gnu"]
json.dump(d, open(p, "w"))
EOF
expect_fail noi386 'does not list i386-linux-gnu' "a provider without i386-linux-gnu is refused"

fresh clobber
printf '{}\n' >"$T/clobber/payload/graphics_provider.json"
expect_fail clobber 'replaced /graphics_provider.json' "the payload may not replace graphics_provider.json"

fresh abslink
ln -sf /usr/lib/libEGL_mesa.so.0.0.0 "$T/abslink/payload/usr/lib/libEGL_mesa.so.0"
expect_fail abslink 'absolute symlink' "an absolute symlink in the payload is refused"

fresh dirclash
mkdir -p "$T/dirclash/root/usr/lib/libgallium-26.2.4-retroforge1.2.1.so"
expect_fail dirclash 'would replace the directory' "a payload file never replaces a guest directory"

fresh glx
rm "$T/glx/payload/usr/lib/libGLX_mesa.so.0"
expect_fail glx 'payload has no usr/lib/libGLX_mesa.so.0' "a payload without libGLX_mesa.so.0 is refused"

# One layer manifest serves both arches, so its library must exist, in the right class, on both.
fresh layer32
rm "$T/layer32/payload/usr/lib32/libVkLayer_MESA_vram_report_limit.so"
expect_fail layer32 'has no ELF32 i386 copy' "a layer whose library is missing for i386 is refused"

fresh layerpath
layer "$T/layerpath/payload/usr/share/vulkan/implicit_layer.d/VkLayer_MESA_vram_report_limit.json" \
  /usr/lib/libVkLayer_MESA_vram_report_limit.so
expect_fail layerpath 'needs a bare file name' "a layer manifest with a path cannot serve both arches"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
