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
  # Only our drivers in the guest's driver folders. Before every x86 game, pressure-vessel resolves
  # each DRI driver and Vulkan ICD the guest has, through the x86 ld.so under FEX: FEX's guest ships
  # 66 DRI names and 9 Vulkan drivers per arch, and those probes cost ~5 s of Megabonk's start
  # (MANGMI Air X, 2026-11-23: its window 38-39 s after the launch instead of 43-45 s with only ours).
  # The msm kernel driver's name picks msm_dri.so (kgsl_dri.so on a KGSL kernel); the other names
  # Mesa installs with freedreno are display-only kmsro ones these SoCs never load. An opaque marker
  # (.wh..wh..opq, which fuse-overlayfs honours in a lower layer; steam-x86-guest-kernel turns each one
  # into the kernel overlayfs's opaque xattr) hides the guest's own entries in those folders behind
  # ours; a guest mounted without our layer keeps all of its own.
  x86_root="$stage/usr/lib/retroforge/x86-mesa/root"
  for d in usr/lib/dri usr/lib32/dri usr/share/vulkan/icd.d; do
    [ -d "$x86_root/$d" ] || continue
    case "$d" in
      */dri) find "$x86_root/$d" -mindepth 1 -maxdepth 1 ! -name msm_dri.so ! -name kgsl_dri.so \
               ! -name libdril_dri.so -exec rm -rf {} + ;;
    esac
    : >"$x86_root/$d/.wh..wh..opq"
  done
  unset x86_root d
  install -m 0644 "$x86_mesa/payload.conf" "$stage/usr/lib/retroforge/x86-mesa/payload.conf"
  chown -R 0:0 "$stage/usr/lib/retroforge/x86-mesa"
  unset x86_mesa
fi
