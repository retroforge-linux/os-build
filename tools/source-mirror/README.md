# source-mirror

A copy of every file and git commit the build downloads, kept on GitHub in
[retroforge-linux/source-mirror](https://github.com/retroforge-linux/source-mirror) and read
**before** upstream. One host going down (archive.archlinux.org on 2026-11-21, archive.mesa3d.org
on 2026-08-23, freedesktop GitLab now and then) no longer stops a build.

## What it holds

`mirror/sources.lock`, generated, one row per object: its hash, kind, upstream URL and where the
mirror keeps it (`<release>/<asset>`).

| release | holds | from |
|---|---|---|
| `sources` | `linux-7.3.5.tar.xz`, `mesa-26.3.1.tar.xz`, every PKGBUILD source tarball under the name makepkg gives it (`qrtr-1.2.tar.gz`), holo PKGBUILDs as `holo-<pkg>-<ref>.PKGBUILD` | `kernel/SOURCE.pin`, `packages/*/source.pin` |
| `prebuilt` | `pygame_ce-2.5.8-...whl` | `packages/*/prebuilt.pin` |
| `fex-rootfs` | `ArchLinux-2026-08-11.sqsh` | `packages/mesa-x86/guest.pin` |
| `git` | `gamescope-3.17.0-e6674a98118c.bundle`, `wlroots-d783533489e1.bundle`: a bundle that holds the commit (and tag) | makepkg `git+` sources, `#tag=`/`#commit=` resolved; gamescope's unpinned submodules take the commits gamescope records |
| `archlinux-2026.08.11-core`, `-extra`, `-multilib` | the snapshot's database and package files under pacman's names (an epoch's `:` is `_`) | what the x86 Mesa builder's pacman really downloads, recorded by `record-arch.sh` |

Asset names keep `[A-Za-z0-9._-]`; anything else becomes `_`, as GitHub would rename it anyway.
The names are for people: what a build trusts is the hash in the row, checked on every download
(GitHub also shows each asset's sha256). 2 GiB per file is GitHub's limit; the FEX guest is 1.4 GB.

## How the build reads it

`tools/source-mirror/rf-fetch [--sha256 H] OUT URL` looks URL up in the lock, takes the mirror's
copy, else URL, and refuses anything that does not hash to the row's sha256 (or `--sha256`, the
caller's own pin), whichever host served it. A URL the lock does not name is fetched as it is,
unchecked, as before; a row that disagrees with `--sha256` (a lock not refreshed after a bump) is
ignored, so that file comes from upstream until the lock is.

| fetch | how |
|---|---|
| kernel tarball | `kernel/build.sh` |
| mesa tarball | `packages/mesa/fetch-source.sh` (Fedora's lookaside stays a third source) |
| FEX guest RootFS | `packages/mesa-x86/compose.sh` |
| prebuilts | `rootfs/customize-base.sh` |
| holo PKGBUILDs | `packages/build-overlay.sh` |
| PKGBUILD sources | `tools/source-mirror/rf-seed`, from `packages/build-overlay.sh`: tarballs checked against the lock or the PKGBUILD's sha256sums (makepkg itself runs `--skipinteg`), git sources restored from their bundle as makepkg's own bare clone |
| Arch snapshot | pacman's `XferCommand`, set by `packages/mesa-x86/pacman-snapshot.sh` |

A git bundle is checked by its commit after the clone (and the tag, for a `#tag=`); one that is
missing or wrong is dropped and makepkg clones upstream.

`RF_MIRROR=off` goes back to upstream only, `RF_MIRROR=only` takes nothing but the mirror (to check
it is complete), `RF_MIRROR_BASE` points elsewhere (a local copy, a `file://` tree).

## Keeping it full

```sh
make mirror-lock                 # after a pin or PKGBUILD-source change (network: ls-remote, hashing)
make mirror-lock RECORD_ARCH=1   # after a builder.pin bump or an x86 builder package-list change
make mirror-sync                 # upload what the mirror lacks (gh, write access to source-mirror)
```

`sync.sh` checks every object before it uploads it: a file must hash to its row, a bundle must
clone and hold its commit. An upstream that changed under a pinned hash is reported, not uploaded,
and so is an asset that already holds other bytes under a row's name.

**CI fills it before every build.** `.github/workflows/source-mirror.yml` runs `sync.sh` ahead of
the image builds (`image.yml`, so nightly, release bundle and release card) and the overlay
package builds (`overlay.yml`), so a lock change is mirrored by the first build that needs it. It
uses the `SOURCE_MIRROR_TOKEN` secret (fine-grained, `retroforge-linux/source-mirror` only,
Contents: read and write); without it, or if the sync fails, it warns and the build goes on,
fetching what the mirror lacks from upstream. The mirror repo's own daily `sync` workflow (its
`GITHUB_TOKEN`, against os-build `main`) is the second line.

The lock is not part of `rootfs/manifest.lock` or any input hash: refreshing it rebuilds nothing.
