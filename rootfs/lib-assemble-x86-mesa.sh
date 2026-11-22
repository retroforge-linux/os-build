#!/usr/bin/env bash
# retroforge read-only root assembler — stages `x86-mesa`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed.
#
# Runs on EVERY build, release included, unless RETROFORGE_X86_MESA=0.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs).
# STAGE x86-mesa — /usr/lib/retroforge/x86-mesa/{root/,payload.conf}: our Mesa (Turnip, freedreno, the GL
# front ends, the VRAM layer) built for x86_64 and i686 by packages/mesa-x86 from packages/mesa's own
# pin and patches. It is the image's one x86 payload, and it runs nothing on the host: steam-x86-guest
# lays root/ over the x86 guest it downloads for Valve's FEX tool (fuse-overlayfs, read-only), so x86
# games under FEX use our driver instead of the guest's stock one. payload.conf names the Arch
# snapshot it was built against (steam-x86-guest skips a guest older than that) and the Mesa version.
#
# Built by `make mesa-x86` (a $(ROOTFS) prerequisite unless RETROFORGE_X86_MESA=0). Missing means a
# stale invocation bypassed make; fail rather than ship an image whose x86 games quietly fall back to
# the guest's Mesa.
if [ "${RETROFORGE_X86_MESA:-1}" = 0 ]; then
  echo "  x86 Mesa: RETROFORGE_X86_MESA=0, not in this image (x86 games use the FEX guest's own Mesa)"
else
  x86_mesa="$ROOT/work/mesa-x86/out"
  [ -d "$x86_mesa/payload/usr" ] && [ -s "$x86_mesa/payload.conf" ] || {
    echo "x86 Mesa payload missing: ${x86_mesa#"$ROOT"/}/payload (run: make mesa-x86, or RETROFORGE_X86_MESA=0)" >&2
    exit 1
  }
  echo "  injecting our x86 Mesa -> /usr/lib/retroforge/x86-mesa ($(tr '\n' ' ' <"$x86_mesa/payload.conf"))"
  rm -rf "$stage/usr/lib/retroforge/x86-mesa"
  mkdir -p "$stage/usr/lib/retroforge/x86-mesa/root"
  cp -a "$x86_mesa/payload/." "$stage/usr/lib/retroforge/x86-mesa/root/"
  install -m 0644 "$x86_mesa/payload.conf" "$stage/usr/lib/retroforge/x86-mesa/payload.conf"
  chown -R 0:0 "$stage/usr/lib/retroforge/x86-mesa"
  unset x86_mesa
fi
