# mesa-x86: our Mesa for the x86 guest Valve's FEX tool runs x86 games in

An x86_64 + i686 build of **our** Mesa (Turnip, plus freedreno for GL), from the same tarball and the
same patches as the host driver in [`../mesa`](../mesa). `make mesa-x86` builds it (`build.sh`), and
`rootfs/lib-assemble-x86-mesa.sh` puts it in the OS image at `/usr/lib/retroforge/x86-mesa/root`
with `payload.conf` (the Arch snapshot it was built against, the Mesa version). The guest itself,
FEX's ArchLinux RootFS, is not in the image: a device downloads it (Main menu > Emulators > Steam
Client) and `steam-x86-guest` lays this payload over it whenever it mounts it (the kernel's overlayfs
through root's `steam-x86-guest-kernel`, else `fuse-overlayfs`)
(user decision 2026-10-18: built into the image, so nothing needs hosting). `RETROFORGE_X86_MESA=0`
builds an image without it.

Nothing in this directory is a pacman package or a prebuilt: there is no `source.pin`,
`prebuilt.pin` or `PKGBUILD` here, so `build-overlay.sh` and `customize-base.sh` never see it, and
`tests/test-fex-guest.sh` fails if one appears. The payload reaches the image through the x86-mesa
assembler stage alone.

## Why the guest needs x86 Mesa

Valve's arm64 Steam client runs native x86 Linux games under FEX: it adds FEX to a game as a
dependency, the way it adds Proton (`STEAM_COMPAT_FEX_CONFIG` in `steamclient.so`, see
[`docs/steam-arm64.md`](../../docs/steam-arm64.md)). An emulated x86 process can only load x86
libraries, so the dynamic loader, glibc, the GL and Vulkan loaders and the GPU driver all have to
be x86_64 builds (and i386 ones for 32-bit games). Steam takes that set from a **graphics
provider**: a root filesystem with `/graphics_provider.json` at the top
(steam-runtime-tools' `steam-runtime-graphics-provider.json(5)`), named by
`STEAM_COMPAT_GRAPHICS_PROVIDER`, from which pressure-vessel imports the drivers.

FEX can forward GL and Vulkan calls to the host's arm64 driver instead ("thunks"), but its
`ThunkConfig` defaults to empty (`FEXCore/Source/Interface/Config/Config.json.in`), so by default
nothing is forwarded and **the guest's x86 Mesa is the driver**: it compiles every shader and builds
every command buffer, under emulation. Whether Valve's tool turns thunks on has not been seen;
nothing here assumes it does.

FEX's ArchLinux RootFS already carries a Mesa: FEX's own build of upstream 26.2.0, every driver,
with LLVM. It runs, but it is not ours: none of [`../mesa/patches`](../mesa/patches) (the a830
chip id, `VK_QCOM_rotated_copy_commands`, pre-rotated presents ...), and a different version from
the host. This directory rebuilds the guest's Mesa from `packages/mesa`'s pin, so a host bump is a
guest bump.

## What is built

`build.sh` runs `container-build.sh` in an x86_64 Arch container (`builder.pin`) locked to the Arch
snapshot the guest was made from, so nothing links against a newer library than the guest ships.
The source is `packages/mesa/fetch-source.sh`'s verified tarball and the patches are
`packages/mesa/source.pin`'s, in order. The `VERSION` string is the host's
(`26.2.4-retroforge1.2.1`), so `GL_VERSION` and `libgallium-<version>.so` name the same build on
both sides.

| option | guest | host | why |
|---|---|---|---|
| `vulkan-drivers` | `freedreno` | `freedreno` | Turnip, for Vulkan games and DXVK/VKD3D |
| `gallium-drivers` | `freedreno` | `freedreno` | GL on freedreno, which the `msm` driver name maps to (FEX's own Arch guest Mesa ran x86 GL titles that way). No zink: zink alone, as Valve's `deckard-mesa-linux-x86_64` ships it, left x86 GL titles with no driver inside Steam's Linux Runtime, where it fails with `VK_ERROR_LAYER_NOT_PRESENT` though it works under FEX outside the container (Megabonk, MANGMI Air X, 2026-11-22). |
| `vulkan-layers` | `vram-report-limit` | + device-select, intel-nullhw, overlay, screenshot | the one Valve's guest carries, in its shape: an implicit layer that stays off unless `ENABLE_MESA_VRAM_REPORT_LIMIT=1` (Valve's `steam_launch_wrapper_env_defaults.txt` sets it for games). One manifest with a bare `library_path` serves both arches. |
| `llvm` | disabled | disabled | freedreno and Turnip do not use it |
| `glvnd`, `glx`, `egl`, `gbm` | enabled (`glx=dri`) | same | the guest's GL is libglvnd + libGLX_mesa/libEGL_mesa |
| `display-info`, `spirv-tools`, `lmsensors`, `valgrind`, `libunwind` | disabled | various | the guest does not ship these libraries, and an ICD with a missing `NEEDED` is dropped silently |
| `-march` | `x86-64` | `armv8-a+crc` | the guest's own baseline |

Each arch is checked in the container: the ELF class and machine of every library, the ICD's
`library_path`, and a glibc symbol ceiling no newer than the snapshot's glibc.

freedreno is the one GL driver. zink failed inside Steam's runtime container, where nearly every
native Linux Steam game runs, so it is not built. The payload check in `build.sh` requires
`dri/msm_dri.so` for both arches, so a build without freedreno fails.

## Checking it against a real guest (optional)

The device lays the payload over the guest at mount time; nothing here composes what it ships.
`compose.sh` is the check that the payload works in a guest: it downloads the guest named in
`guest.pin` (sha256-checked), then, in the same container as root (`container-compose.sh`):

1. unpacks it with `unsquashfs`;
2. lays the payload over it (`guest-overlay.py`): each file replaces the guest's at the same path,
   new files take the owner of their directory and a fixed timestamp, and directories keep theirs;
3. proves the guest now uses our Mesa: `/graphics_provider.json` is intact and every directory it
   names exists; each arch's `freedreno_icd.*.json` resolves, inside the guest, to our
   `libvulkan_freedreno.so`; `libEGL_mesa.so.0` and `libGLX_mesa.so.0` resolve to ours; the VRAM
   layer's one manifest finds an x86_64 and an i386 copy of its library;
4. rebuilds `/etc/ld.so.cache` (`ldconfig -X -r`, cache only, links untouched), so the new
   `libgallium-<version>.so` is in it, and checks that the guest's set of file owners is unchanged
   (FEX's image is all uid/gid 1000);
5. runs the guest's own `ld.so` in a chroot over every library we added, with every symbol bound
   (`ldd -r`): a dependency the guest lacks, or a symbol its glibc/libdrm/libxcb is too old for,
   fails here rather than on a device;
6. packs it with FEX's settings (zstd, 128 KiB blocks), the guest's creation time as the timestamp.

Output, in `out/fex-guest/`:

```
retroforge-fex-guest-<version>.sqsh               the image; <version> = <mesa pkgver>-<revision>
retroforge-fex-guest-<version>.sqsh.sha256        sha256sum -c format
retroforge-fex-guest-<version>.sqsh.release       what it was made from (also at
                                                  /usr/share/retroforge/fex-guest.release inside)
retroforge-fex-guest-<version>.sqsh.overlay.txt   every path replaced or added in the guest
```

FEX's paths are all kept, so the image is still a drop-in for FEX's own: the same
`/graphics_provider.json`, the same ICD file names (with Mesa's absolute `library_path`, as both
FEX's rootfs and Valve's guest ship them). FEX's `libgallium-26.2.0.so` stays as well: its VA-API
driver symlinks (`dri/*_drv_video.so`) still point at it, and nothing of ours loads it. Removing
it, Arch's orphaned `libgallium-26.1.6-arch1.1.so` and LLVM would shrink the image; not done, so the
guest stays FEX's in everything but the driver.

## Building it locally

```sh
packages/mesa-x86/build.sh                  # -> work/mesa-x86/out/payload (cached by input hash)
packages/mesa-x86/build.sh --configure-only # meson setup for both arches, then stop
packages/mesa-x86/compose.sh                # -> out/fex-guest/
packages/mesa-x86/compose.sh --print-version   # 26.2.4-1 (also --print-asset, --print-tag)
```

Both need docker (or podman) and run `linux/amd64` containers: native on an x86_64 host, emulated
on an arm64 Mac. Measured on an Apple-silicon Mac under that emulation (2026-10-16): the build took
11 minutes for both arches, the compose 2, and the image is 1305 MiB against FEX's 1297 MiB. `compose.sh` fails if the host cannot run i386 code for the lib32 half of step 5;
`MX86_SKIP_I386_EXEC=1` skips that half for a local dry run only.

## Publishing

`.github/workflows/release-fex-guest.yml`, **manual only** (`workflow_dispatch`; no push, tag or
schedule trigger). It builds and composes on an x86_64 runner, uploads the result as a workflow
artifact, and with **publish** ticked cuts a GitHub Release `fex-guest/v<version>` on the built
commit with the four files above, after checking the image against GitHub's 2 GiB per-asset cap.
The version is not an input: it comes from the tree, so to publish again for the same Mesa, bump
`revision` in `guest.pin` first. An existing release for a version is never replaced.

**The repo is public** (since 2026-11), so a published asset is something a device can fetch with
no GitHub login, and `x86-guest.pin`'s `url` can be its release download url as-is. While the repo
was private it could not be.

## Switching devices to it: `x86-guest.pin`

`rootfs/overlay/usr/share/retroforge/steam/x86-guest.pin` names the guest a device downloads and
mounts, and starts out on FEX's own ArchLinux RootFS (2026-08-11). Our image is the
same kind of file with the same layout, so switching is four fields, all printed in the release
notes:

```
name: retroforge-fex-guest
version: 26.2.4-1
url: <public url of retroforge-fex-guest-26.2.4-1.sqsh>
sha256: <the .sha256 asset's hash>
```

That is an OS change (the pin is in the image), so it ships in the next bundle, and the device
downloads the new guest the first time an x86 game starts after it.

## Bumping

- **Mesa** (`packages/mesa/PKGBUILD` pkgver, its patches): nothing to edit here, it follows. Reset
  `revision` in `guest.pin` to 1, dispatch, then bump `x86-guest.pin`.
- **The FEX rootfs**: a newer dated "ArchLinux (SquashFS)" entry in
  <https://rootfs.fex-emu.gg/RootFS_links.json>. Set `guest.pin`'s version, url and xxh3; download
  it into an empty directory, check `xxhsum -H3` against the index's `Hash`, record its sha256. Move
  `builder.pin` to the same date (snapshot, and the last `archlinux:base-devel` tag before it, with
  its digest); `build.sh` refuses a mismatch. Bump `revision`.
- **This recipe**: bump `revision`.

## Provenance

The recipe (the container build, the `-m32` cross file, pinning the container to the guest's Arch
snapshot and its image to the tag before it, the glibc ceiling gate) is adapted from upstream's
`packages/mesa-x86` (see the acknowledgement in the top-level README). Upstream built Turnip only,
laid it over a system FEX's erofs rootfs at runtime, rewrote the ICDs to bare filenames and bundled
`libxcb-keysyms`. Here the whole guest is composed into one downloadable image, GL included; the
ICDs keep Mesa's absolute paths, as FEX's rootfs and Valve's guest do; and `xcb-keysyms` is simply
not linked.
