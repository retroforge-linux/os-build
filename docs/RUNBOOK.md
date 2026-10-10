# Runbook — flash, reach, update, recover

The operational path, end to end. Design rationale lives elsewhere: [`remote-access.md`](remote-access.md)
for why SSH is shaped the way it is, [`ota.md`](ota.md) for the update server, and the header comments
of the scripts named below for why each step is shaped the way it is.

Every `make` invocation below runs from the repo root. A dev build needs its environment sourced
**before every one of them** (`set -a; . ./dev.env; set +a`) — see the README's Building section.

## Prerequisite: the device already runs the ROCKNIX ABL

**qforge ships no bootloader.** A card boots because the device is already running the custom
ABL from [ROCKNIX](https://github.com/ROCKNIX/abl) — an Android bootloader replacement that can
chainload a UEFI payload off an ESP. On a stock Android ABL a qforge card does nothing, and
nothing on the card can change that: writing the image is not the first step, flashing that ABL
is. We consume it and cannot build it — it ships as a signed, per-device ELF.

Install it by ROCKNIX's own procedure — their `update.sh` writes the signed
`abl_signed-<HW_DEVICE>.elf` to both `abl_a` and `abl_b`, and it needs an unlocked bootloader.
That process is theirs to own and keep current; it is not reproduced here.

Two properties of it govern everything below:

- **It has two modes, Android or Linux, and the choice persists in the `devinfo` partition** — so
  set it in ABL's own menu. qforge never writes `devinfo`: it is in the installer's deny list,
  the format is ABL-private, and on Qualcomm parts that partition also carries unlock and verity
  state. With Linux mode selected, **Volume-Up is a one-time override back to Android** — it
  chooses a mode, not a medium.
- **Linux mode tries internal storage first**, falling through to the card only when no internal
  ESP carries `/EFI/BOOT/bootaa64.efi` or `/KERNEL`. On a device with nothing installed to
  internal that is invisible — the card simply boots. On one that has something, the card needs
  "force external"; see [Recovery](#recovery-when-it-does-not-boot).

A pre-existing ROCKNIX *installation* is the second case, not just a pre-existing ABL: ROCKNIX
installed to internal storage keeps winning the boot until you force external, which reads like a
dead card. That is a setting, not a fault.

## The disk it all operates on

<!-- AUTO-GENERATED from image/partition-table.txt — regenerate with /ecc:update-docs -->

| # | Partition | Size | FS | Label |
|---|---|---|---|---|
| 1 | `esp` | 256M | vfat | `QFORGE-ESP` |
| 2 | `efi-a` | 128M | vfat | `qforge-efi-A` |
| 3 | `efi-b` | 128M | vfat | `qforge-efi-B` |
| 4 | `rootfs-a` | 2G | btrfs | `qforge-root-A` |
| 5 | `rootfs-b` | 2G | btrfs | `qforge-root-B` |
| 6 | `var-a` | 256M | ext4 | `qforge-var-A` |
| 7 | `var-b` | 256M | ext4 | `qforge-var-B` |
| 8 | `home` | rest | ext4 | `qforge-home` |

<!-- END AUTO-GENERATED -->

`image/partition-table.txt` is the single source of truth for sizes, typecodes and labels;
`image/genpart.sh` emits the `sgdisk` script from it. Three facts drive most of what follows:

- **The shared ESP carries the bootconf, not a kernel.** SteamOS/conf/{A,B}.conf on the ESP decide
  which image boots and how many failed attempts it is allowed; the stage-1 steamcl (as
  `/EFI/BOOT/bootaa64.efi`) is what ABL chainloads. Each slot's *own* efi partition (efi-a/efi-b)
  carries that slot's stage-2 GRUB and its identity partset (`SteamOS/partsets/self`). ABL reads
  partition 1 only.
- **`/var` is per-slot, and `/etc` rides on it** (an overlayfs whose upper dir is
  `/var/lib/overlays/etc/upper`). A slot switch therefore carries `/etc` with it.
- **`/home` is shared and survives everything** — including the paired SSH keys in
  `/home/player/.ssh`, and the offloaded `/var/log`. This is why an OTA does not lock you out.

## Get a release card

**A release card is published only by CI**, because the R2 credentials live there — but `make
sdcard` on a dev box (no `QFORGE_DEV`) builds the same kind of image, which is how a release image's first boot gets
tested on hardware without waiting for a run.

Cards are served from Cloudflare R2, not from a GitHub release asset — GitHub caps an asset at 2 GiB,
and the card measured well over that on the reference build (`ota/publish-card.sh` carries the
figures; re-measure now that the root no longer carries an x86 stack). The GitHub Release for a `card/v*` tag carries the checksums, the
package lock the card was built from, and the link:

```sh
curl -LO https://<R2_PUBLIC_BASE>/cards/v1.3.0/sdcard.img.gz
curl -LO <the card/v1.3.0 GitHub Release>/sha256sums.txt
sha256sum -c sha256sums.txt                   # do this BEFORE writing the image to a card
gzip -dc sdcard.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

`.gz` rather than `.zst` on purpose: the payload is already compressed (both btrfs roots carry
`compress=zstd`), so every wrapper lands at about the same size and the choice is a compatibility
one, not a size one, and `.gz` is what balenaEtcher and Raspberry Pi Imager open.

To cut a card: tag `card/vX.Y.Z`. To cut an update instead, tag `ota/vX.Y.Z` — the two ship on
independent cadences and a bundle is expected far more often than a card. There is nothing to line
up first: the release run compiles the overlay from the sources in the commit it is building
(~34 min on top of the image), so a tag is never waiting on a separate pipeline to have published
anything.

The version and commit a card was built from are stamped into `/etc/qforge-release` on the device
(`QFORGE_VERSION`, `QFORGE_GIT`), so a running system can name where it came from.

## Build and flash a dev card

```sh
set -a; . ./dev.env; set +a                   # QFORGE_DEV=1 + optional Wi-Fi creds
make sdcard                                   # -> out/images/sdcard.img
make verify-card                              # GPT, ESP, per-slot filesystem identities
sudo dd if=out/images/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
```

**Editing an overlay package needs no CI round trip, in either mode.** `make overlay` compiles it
locally and both the dev and release paths install what is in `work/repo/<arch>/` — patch, build,
flash, repeat is entirely local. Only the package you touched is rebuilt: `build-overlay.sh` keys
each one on `packages/inputhash.sh` over its committed inputs and skips the rest.

```sh
make overlay                                  # rebuild whatever moved (a warm tree: no-op)
packages/build-overlay.sh --only gamescope    # force one package
cat work/repo/aarch64/.stamps/gamescope.hash  # what was built, vs. inputhash.sh on the dir
```

`make-sdcard.sh` lays the **full** GPT — ESP + root-A/-B + var-A/-B + home, with `/home` carrying an
empty `player` home (`image/lib-homestage.sh`, shared with the internal installer) that grows to fill
the card on first boot. Each `efi-*` partition carries that slot's stage-2 GRUB, its `grub.cfg` and
the partsets that identify it.

**Whether slot B is populated follows the build mode**, and `QFORGE_SLOT_B=0|1` overrides it:

* **Dev card** (`QFORGE_DEV=1`): B is populated, carrying a distinct btrfs fsid, because a slot
  switch cannot be proven against a slot that does not boot. Set `QFORGE_SLOT_B=0` for a faster
  local loop, at the cost of a card whose first slot switch can only exercise the failover path.
* **Release card**: B is left empty **and no `B.conf` is written**. B would be a byte-identical copy
  of an already-compressed root, surviving release compression whole — a second root's worth of
  download for a failover window that closes the first time RAUC writes the slot. Omitting the conf is what keeps steamcl from
  offering the empty slot as a boot candidate; see the seeding site in `image/make-sdcard.sh` for
  the `SUPERMAX_BOOT_FAILURES` path it closes. The first update writes B in full and creates its
  conf.

Run `verify-card` before you commit a card to a device — it asserts the built image rather than
the source tree, which is the only place the GPT, the ESP contents and the per-slot filesystem
identities are checked at all.

**The first boot stops at the stage-2 board menu and waits.** One image serves every supported
board (the README's table is the roster), so the DTB is the one thing the card cannot know. The
choice is written to `/EFI/steamos/grubenv` on the shared ESP, and every boot after that takes it
automatically behind a 3-second visible menu — including across a slot switch and an update, since
the grubenv is on the ESP rather than in a slot. Picking the wrong board gives a card that does
not come up; the menu stays visible (rather than hidden) precisely so there is a way back on a
device with no keyboard.

To install a freshly built stage-1 steamcl onto an already-flashed card's ESP without rebuilding
the image:

```sh
make deploy ESP=/run/media/$USER/QFORGE
```

## Reach the device

**These devices have no UART.** If you cannot reach a device over the network, your only
instrument is the offline card mount — see [Recovery](#recovery-when-it-does-not-boot).

### Release image

sshd ships **always-on and key-only**, with no host keys baked in and no account with a password.
Access is granted at runtime by whoever is holding the device:

1. The pairing daemon (`qforge-pairingd`, port 32000) is **always on** for now — there is no
   on-screen switch yet, so anyone on the same network can register a key.
2. From the machine you want to connect from:
   ```sh
   curl -X POST --data-binary @~/.ssh/id_ed25519.pub http://<device>:32000/register
   ```
3. `ssh player@<device>` — immediately, no password. Installed keys live on `/home` and survive
   updates, so an already-paired machine never re-pairs.

Pairing is separate from sshd, which is always on and key-only. Full protocol notes, the Windows
invocations and what persists across an update: [`remote-access.md`](remote-access.md).

### Dev card

`dev.env` bakes `QFORGE_SSH_PUBKEY` into `root`'s `authorized_keys` and generates a throwaway
identity for it:

```sh
ssh -i work/dev-ssh/id_ed25519 root@<device>
```

That key survives `make distclean`, so your `known_hosts` entry keeps working across rebuilds. A
dev card built with no Wi-Fi credentials (or `QFORGE_WIFI=0`) has no network and no SSH by
design — that is the shipping first-boot condition, and the only honest way to exercise it.

### Over the USB cable, with no network at all

Every build presents the device to whatever is on its USB-C cable as a **CDC NCM network adapter**
(`usr/lib/qforge/usb-gadget`, started by udev the moment the Type-C controller switches the port to
the device role). The device side is `usb0` at **10.42.0.1/30**; systemd-networkd runs a one-address
DHCP server on it, so the workstation's new adapter gets 10.42.0.2 with no router and no DNS
(nothing routes through the link). Then:

```sh
ssh -i work/dev-ssh/id_ed25519 root@10.42.0.1     # dev card
ssh root@10.42.0.1                                # release card, after pairing (above)
```

macOS and Linux need no driver; Windows 10 1703+ binds its NCM class driver through the gadget's
OS descriptor. `qforge.local` resolves over the link too (avahi answers on it). This is the debug
path for a device whose display is dead but which booted: the home partition grows and sshd is up
long before anything is painted.

Only a board whose USB controller is dual-role exposes a UDC: the MANGMI Air X / Air Y Pro, the
SM8250 boards and the SM8650 AYANEOs declare `dr_mode = "otg"` with a role switch; the SM8550
trees (AYANEO Pocket family, AYN Odin 2 / Thor) do not yet, so their port stays a host port and
the gadget never binds there. `journalctl -u qforge-usb-gadget` says which case you are in.

## Ship an update

### Build and sign a bundle

```sh
QFORGE_VERSION=<version> PKIDIR=$HOME/qforge-pki make bundle
```

**The version has to be set before the rootfs is built, not at bundling time.** `QFORGE_VERSION`
is stamped into the image's `/etc/qforge-release`, and `genbundle.sh` reads it back out of the
image to name the bundle — so the bundle can never claim a version its payload does not carry. That
equality is what the device's update check compares, so it is not cosmetic. Changing the version
re-assembles the rootfs (a few minutes; not a base or kernel rebuild).

Omit it and the image calls itself `dev`; the bundle is then named after its build timestamp, which
is still unique per build but is not a release. There is no separate bundle-version knob — the old
`VERSION=` was removed on 2026-08-03 precisely because it could disagree with the image.

`PKIDIR` is not optional for anything a device will accept. Without it `genbundle.sh` mints an
**ephemeral 7-day dev cert**, deleted with its tempdir, which the device keyring rejects on
signature — that reads as a rauc failure and is not one. The PKI lives outside the repo and is
invisible to the build container unless `PKIDIR` mounts it.

There is a second target, `make sign-bundle`, which wraps an **existing** `out/images/rootfs.img`
instead of building one — same signing, no `$(ROOTFS)` prerequisite. CI uses it to split the release
into build → sign → publish so the image build does not queue behind someone approving the signing
environment; locally it is what you want when the image came from somewhere else (a CI artifact, or
another machine) and rebuilding it would defeat the point. It fails rather than building a
replacement if the image is not there. Use plain `make bundle` on a dev box: the prerequisite is the
feature, keeping the bundle honest about the tree it came from.

**`make bundle` does not verify its own output.** rauc logs `No keyring given, skipping signature
verification` at creation, so a green `make` is not evidence the bundle is validly signed. Check
it yourself, **through the shipped config**:

```sh
rauc --conf=rootfs/overlay/etc/rauc/system.conf info out/images/qforge-<version>.raucb
```

Do not use `rauc info --keyring <ca>` — that applies rauc's default `smimesign` purpose, which
accepts only `emailProtection` or no EKU, and therefore rejects our `codeSigning` release cert
with `unsuitable certificate purpose`. It is a false red. The shipped `system.conf` sets
`check-purpose=codesign`.

### Publish it

```sh
QFORGE_OTA_HOST=<host> QFORGE_OTA_SSH_KEY=~/.ssh/<key> ota/publish-bundle.sh out/images/qforge-<version>.raucb
```

Puts the bundle on the update server and flips the channel pointer at it. **There is no QForge
server yet** — the default host, `updates.qforge.invalid`, is a placeholder that never resolves, and
`qforge-update` on the device currently reports "no update" regardless (it still gates on a Steam
login file that QForge never creates; see `docs/ota.md`). Until both are resolved, install by hand. **Install it on a device first** (below) — nothing on the device ends an unconfirmed
trial boot, so a bundle that comes up to a black screen costs ~6 manual power-cycles to recover on
hardware with no serial console. Every published bundle gets a hardware install before it ships.

The publisher verifies the signature against the CA baked into every device's keyring before it moves
a byte, and there is no override: a bundle built without `PKIDIR` carries an ephemeral 7-day cert and
would be a ~4 GB download the fleet discards at the last step. Server contract, retention, rollback
and cert renewal are in **`docs/ota.md`**.

### Install it

Drive the install **as `player` over SSH** — rauc's D-Bus service authorizes it with no `sudo` on the
box and no password anywhere. (The mechanism is rauc's *open bus policy*, not polkit: 1.15.2 ships
no polkit policy, and its `de.pengutronix.rauc.conf` allows any local user to call the installer. The
signature is the gate. See `docs/ota.md` — it was accepted as a design choice.)

```sh
ssh player@<device> rauc install /path/to/qforge-<version>.raucb
```

Not as `root`: `/root` is on the read-only root and does not survive the slot write. Watch for
`Verifying signature done` (~20%) — that is the device's own keyring accepting the bundle.

Every install writes the whole slot today (`[image.rootfs]` names `rootfs.img` and nothing else),
so budget minutes of SD-card writes for a one-package bump.

The post-install hook makes the freshly written slot bootable: it re-randomises the target's btrfs
fsid (both slots otherwise share an fsid *and* `devid=1`, and mounting one can hand you the other),
copies `/var` across, installs this build's stage-2 GRUB + grub.cfg + font onto the target's efi
partition and re-points its partsets, refreshes the shared ESP's stage-1 steamcl if it changed, and
finally arms the target for its trial boot through steamos-bootconf. Reboot to land on the new slot.

## Read and steer the boot state

```sh
qforge-bootctl status               # what booted, and what the ESP/efi say
qforge-bootctl get-state B          # is slot B fit to boot? (good|bad)
qforge-bootctl set-primary B        # boot slot B next (starts its trial boot)
qforge-bootctl set-state B bad      # demote B; the next boot goes to the other slot
qforge-bootctl mark-good            # confirm THIS boot — ends its trial, clears boot-attempts
```

**All of these need root, and a release image ships no `sudo`.** As `player` the tool cannot answer
any of it. On a dev card, `ssh -i work/dev-ssh/id_ed25519 root@<device>`; on a release device,
read the state off the card offline (below). `rauc install` is the deliberate exception — it goes
through rauc's D-Bus service and its open bus policy, which is why it works as `player`.

These are Valve's SteamOS semantics, surfaced through the same steamos-bootconf that RAUC uses, so
`qforge-bootctl` and `rauc status` agree by construction. The state that decides a boot lives in
the ESP conf of each image:

- **`image-invalid`** — a hard demote. `set-state <slot> bad` sets it (and the boot-health unit's
  failure path does exactly that, via `qforge-boot-bad.service`); only a completed install clears
  it, because the post-install hook is the only place that knows an install completed. **This is
  the only rollback trigger that is live today.**
- **`boot-attempts`** — the trial counter. The stage-2 `qforge` module bumps it on every kernel
  boot (`qforge_bootattempts <slot>` in the generated `grub.cfg`), `mark-good` clears it after a
  healthy session, and steamcl's failsafe offers a menu at ≥3 and auto-picks the other slot at ≥6.
  **HW-validated 2026-08-02.** Two traps when checking it by hand: a healthy boot runs `set-mode
  booted`, which *clears* the counter — so mask `qforge-boot-good.{path,service}` before the test
  reboot or a working counter and a dead one both read `0`. And GRUB prints
  `qforge: A boot-attempts 0 -> 1` just before the board menu paints over it, so on a 3s boot you
  will usually miss it; the conf is the evidence, not the panel.

> **What that means in practice.** A slot that boots but comes up broken IS demoted — the health
> unit fails and the next boot goes to the other slot. A slot that never gets far enough to run
> systemd at all is demoted by the counter above, at ≥6 attempts. Recovery is the stage-2 board
> menu, which is why
> it stays visible rather than hidden.

Three traps, each of which has inverted a conclusion on real hardware:

- **`rauc status` cannot tell promoted from still-on-trial.** It reports the slot `good` in both
  states. Only the ESP conf distinguishes them — and while `boot-attempts` is unwired, not even
  that does: read `image-invalid` and whether the health unit succeeded this boot
  (`systemctl status qforge-boot-good`).
- **A slot that never booted answers `good`.** `get-state` reads `boot-attempts ≥ 1` or
  `image-invalid > 0`; a freshly installed slot has neither, so it is indistinguishable from a
  confirmed one until its first boot. That is by design — a new slot must not report bad before it
  has ever tried.
- **A trial that is never confirmed does not revert on its own.** With the counter unwired, the
  automatic revert is the health unit failing and demoting the running image. If the session never
  comes up at all, nothing fires; `set-primary` back to the good slot by hand.

`set-primary` is the manual equivalent of the old `try`: it arms the other slot for its trial boot.
There is no manual `rollback` — `set-primary` back to the good slot is it. `self` is accepted anywhere an image name is, and resolves to
the booted image; that is what the boot-health unit's failure path uses to demote (`set-state self
bad`).

## Recovery: when it does not boot

There is no serial console. Power off, pull the card, and read it on your workstation.

**If the device has an internal Linux install, an inserted card will NOT boot — pick "force
external" in the bootloader.** ABL's Linux mode tries internal storage first and only falls
through to the card when no internal ESP carries `/EFI/BOOT/bootaa64.efi` or `/KERNEL`. So on a
device installed to internal storage — ours, or **ROCKNIX**, or another distribution's —
inserting a card and rebooting changes nothing, which reads exactly like a dead card or a bricked
machine. Select force external in ABL and the card boots normally. This is the recovery path for
an interrupted or broken internal install, and it is the only one short of EDL.

Since the ABL itself comes from ROCKNIX, a device that already had ROCKNIX installed to internal
is the most likely version of this, and it is not a qforge fault to debug — it is the
[boot-order rule](#prerequisite-the-device-already-runs-the-rocknix-abl) working as designed.

Nothing on the SD-card-only path is affected: with no internal ESP present, ABL falls through to
the card unaided and no option needs setting.

**The installer medium is the recovery medium.** Force external boots it the same way it boots a
normal card, and re-running an install is the designed recovery for one that died partway — it takes
no backups precisely because "run it again" has to work. Its own log comes out on its FAT partition
as `qforge-install.log`, readable on any computer, and it is written when the installer's unit
STOPS: a device sitting on a failed screen has not produced one yet, so power-cycle before pulling
the card. Full procedure, including what an install destroys and what it refuses:
[install-internal.md](install-internal.md).

**The journal is not on the slot's `/var`.** `/var/log` is bind-mounted onto
`/home/.qforge/offload/var/log`, so it lives on the shared **home** partition and survives both
slots:

```sh
sudo mount /dev/sdX8 /mnt                     # qforge-home
sudo journalctl -D /mnt/.qforge/offload/var/log/journal -e
```

**Do not trust `-b -1` on these devices.** The RTC comes up stale, so the boot index is unreliable
and relative boot offsets silently select the wrong boot. List the boot IDs and query one
explicitly instead:

```sh
sudo journalctl -D /mnt/.qforge/offload/var/log/journal --list-boots
sudo journalctl -D /mnt/.qforge/offload/var/log/journal _BOOT_ID=<id>
```

The ESP carries the bootconf that decided the boot, and the booted slot's efi partition carries
its identity:

```sh
sudo mount /dev/sdX1 /mnt-esp                 # QFORGE-ESP
cat /mnt-esp/SteamOS/conf/A.conf /mnt-esp/SteamOS/conf/B.conf
sudo mount /dev/sdX2 /mnt-efi                 # qforge-efi-A (the booted slot's efi)
cat /mnt-efi/SteamOS/partsets/self            # which image this efi partition IS
```

`image-invalid: 1` on the conf of the image that just failed means it was demoted — by the health
unit's failure path, by hand, or by an interrupted install. `boot-attempts:` will read 0 whatever
happened, until the stage-2 counter is wired up.
`steamos-bootconf` is the authoritative tool; `tests/test-bootctl.sh` documents the semantics.

The initramfs is written to **degrade loudly rather than brick**: if it cannot assemble the
`/etc` overlay it falls back to a writable un-overlaid root and says so via `/dev/kmsg`. A device
that boots to a shell with a strange `/etc` is that path, not a corrupt image.

A torn write to the ESP or to a slot's efi partition — a lost partset, a missing stage-2 GRUB — is
a **reflash**; the post-install hook refuses to update a card whose booted efi has no partsets.
That is the acknowledged failure mode of the design, not a bug to work around.

## Before a push

```sh
make verify-lock                # lock's qforge rows vs packages/ (seconds)
make test                       # every offline suite under tests/
make test-signing               # RAUC signing self-test (container)
```

CI runs `make test`, the installer disk suites (`test-select-target`, `test-carve`) and
`make test-signing` on every push and pull request. A pull request that
touches a package also gets a compile pass over the packages it changed
(`.github/workflows/overlay.yml`). `make test` needs no
build, no container, no root and no device — it executes the shipped artifacts against a sandbox.
