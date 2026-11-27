# launch_formats — how retroforge-launch runs each kind of download (emulator.json's "format"):
# appimage and appimage-sharun are mounted for the run, scripts and binary run in place. Each is a
# class with prepare() (-> the root the definition's binary is relative to), env() and release()
# (never raises). The AppImage rules (never exec AppRun, the runtime's ignored SIGTERM, the sweep of
# a dead mount) are in retroforge-launch's header.
#
# The scripts format (PortMaster) is a folder retroforge-emu unpacked under $HOME, never mounted: --gui
# runs <root>/<binary> in place, and a game card's ROM is ITSELF a script -- a port's own launch
# script, which PortMaster installed beside its folder -- run with bash (args, "{rom}" = the
# script), never with exec: its mode is whatever the port's zip carried. Not installed (exit 3,
# `not-installed`) when <root>/<binary> is not executable, for a game too: every port script sources
# PortMaster's control files. When the run ends, every runtime a port left mounted is released: the
# mounts RetroForge's port `mount` stand-in (/usr/lib/retroforge/portmaster/bin/mount) records in
# $RETROFORGE_PM_MOUNTS (default $XDG_RUNTIME_DIR/retroforge-portmaster-mounts), whose squashfuse daemons
# outlive the port's session when OGUI's Exit skips the port's own umount.
#
# The binary format (hakuX's standalone build ships this way) is a download that is ONE
# plain executable: retroforge-emu names it
# <tag>.AppImage all the same (the name is only a name; nothing checks the file is an AppImage) and
# points `current` at it. It runs in place, nothing to mount: the definition's binary is `current`
# itself, relative to the emulator's folder.

import errno
import os
import re
import secrets
import select
import signal
import subprocess
import time

from launch_common import ENV, Exit, log

MOUNTS = ENV.get("RETROFORGE_MOUNTS", "/proc/mounts")
TMP_LINK_DIR = ENV.get("RETROFORGE_TMP_LINK_DIR", "/tmp")
PM_MOUNTS = ENV.get("RETROFORGE_PM_MOUNTS",
                    os.path.join(ENV.get("XDG_RUNTIME_DIR") or "/tmp", "retroforge-portmaster-mounts"))
SYSTEM_VULKAN_ICD = "/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json"
UNMOUNT_TRIES = 50   # x 0.1 s for the runtime to let go of the mount after SIGHUP
MOUNT_TIMEOUT = 30   # s for the AppImage runtime to print its mount point
MOUNT_TRIES = 3      # mounts of an image whose files cannot be read (prepare_readable)
PROBE_BYTES = 1 << 20
# What a read gets from a mount whose daemon has failed or gone, not from a missing file.
UNREADABLE = (errno.EIO, errno.ENOTCONN, errno.ESTALE)


def fusermount(*args):
    """fusermount3 <args>: True when it succeeded. A missing or failing helper never stops us."""
    try:
        return subprocess.run(["fusermount3", *args], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, check=False).returncode == 0
    except OSError as err:
        log(f"fusermount3 {' '.join(args)}: {err}")
        return False


def read_line(fd, timeout):
    """The first line written to fd within timeout s ("" on timeout or EOF). Raw reads: a
    buffered readline() would block past the deadline on a partial line."""
    deadline, data = time.monotonic() + timeout, b""
    while b"\n" not in data:
        left = deadline - time.monotonic()
        if left <= 0 or not select.select([fd], [], [], left)[0]:
            return ""
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        data += chunk
    return data.split(b"\n", 1)[0].decode(errors="replace").strip()


def prepare_readable(package, emulator, binary):
    """package.prepare(), again when the program in the mount cannot be read: -> the root.
    The pkgforge runtime's DwarFS daemon at times fails its block checks on the first read of a
    big file ("block data integrity check failed"), and then answers every read of it with EIO for
    as long as it runs: the emulator's loader could not read its binary and the launch ended in 2 s
    (Azahar, MANGMI Air X, 2026-11-27: twice in ~35 starts, both the first game of a session, with
    the Steam client starting beside it; the image itself read back intact each time, and the
    next start, a new daemon, worked). So the start of the program is read here first, and a mount
    that fails it is released and mounted again. Exit(3) when MOUNT_TRIES mounts all fail."""
    why = ""
    for attempt in range(1, MOUNT_TRIES + 1):
        root = package.prepare()
        why = package.unreadable(root, binary)
        if not why:
            return root
        log(f"{emulator}: its mount cannot be read ({why}); mounting it again "
            f"({attempt} of {MOUNT_TRIES})")
        package.release()
    raise Exit(3, f"{emulator}'s files cannot be read: {why}")


def mount_table():
    try:
        with open(MOUNTS) as f:
            return [line.split() for line in f]
    except OSError:
        return []


class AppImage:
    """An AppImage, mounted for the run (`<image> --appimage-mount`), its binary run from the mount."""

    def __init__(self, emulator, image):
        self.emulator, self.image = emulator, image
        self.runtime = None
        self.mnt = None

    def sweep_stale(self):
        # A mount of OUR AppImage: the classic runtime names its FUSE filesystem after the file
        # `current` points at (type fuse.<file>); pkgforge-dev's runtime serves it with a separate
        # dwarfs process (type fuse.dwarfs, source = the AppImage's path), which outlives a killed
        # launcher and runtime and keeps the mount (HW 2026-10-05).
        real = os.path.realpath(self.image)
        fstype = "fuse." + os.path.basename(real)
        for fields in mount_table():
            if len(fields) > 2 and (fields[2] == fstype or fields[0] == real):
                log(f"releasing stale mount {fields[1]}")
                fusermount("-uz", fields[1])

    def prepare(self):
        """Mount; -> the root the definition's binary is relative to. Exit(3) when it fails."""
        self.sweep_stale()
        # The runtime must start with SIGTERM ignored (it keeps that disposition across exec);
        # the launcher's own no-op handler goes back right after, so it never dies of one either.
        handler = signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            self.runtime = subprocess.Popen([self.image, "--appimage-mount"],
                                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
        except OSError as err:
            raise Exit(3, f"{self.image} did not mount: {err}") from None
        finally:
            signal.signal(signal.SIGTERM, handler)
        deadline = time.monotonic() + MOUNT_TIMEOUT
        line = read_line(self.runtime.stdout.fileno(), MOUNT_TIMEOUT)
        if not line:
            raise Exit(3, f"{self.image} did not mount")
        self.mnt = line
        # RPCS3's runtime (DwarFS) prints the mount point before its filesystem is up: wait for the
        # mount itself, not just the line (it failed 9 ms in otherwise, HW 2026-10-07 Pocket FIT).
        while not (self.mounted() and os.path.isdir(line)):
            if time.monotonic() > deadline or self.runtime.poll() is not None:
                raise Exit(3, f"{self.image} did not mount at {line}")
            time.sleep(0.05)
        return self.mnt

    def env(self):
        return {}

    def probe_files(self, root, binary):
        """The files whose start prepare_readable() reads: what the start reads first."""
        return [os.path.join(root, binary)]

    def unreadable(self, root, binary):
        """Why the mount cannot be read ("" when it can, or when a file is merely missing: the
        start reports that itself)."""
        for path in self.probe_files(root, binary):
            try:
                with open(path, "rb") as f:
                    f.read(PROBE_BYTES)
            except OSError as err:
                if err.errno in UNREADABLE:
                    return f"{path}: {err.strerror}"
        return ""

    def mounted(self):
        return any(len(fields) > 1 and fields[1] == self.mnt for fields in mount_table())

    def release(self):
        """Undo prepare(), however far it got. Never raises: the emulator's status must survive."""
        if not self.runtime:
            return
        if self.mnt is None:  # the mount never came up
            self.runtime.kill()
            return
        try:
            self.runtime.send_signal(signal.SIGHUP)
        except ProcessLookupError:
            pass
        for _ in range(UNMOUNT_TRIES):
            if not self.mounted() or fusermount("-u", self.mnt):
                break
            time.sleep(0.1)
        if self.mounted():
            log(f"{self.mnt} still busy; the next launch sweeps it")
        self.runtime = None  # released: a second release(), or one after another prepare(), is its own


class SharunAppImage(AppImage):
    """pkgforge-dev's "anylinux" AppImages (Dolphin, Snes9x, Azahar, ...; PPSSPP's official one is
    built with the same tooling): a sharun bundle with its own loader, libraries and Mesa. Two
    things its AppRun would do, which we never run (one of its hooks is a self-updater that would
    replace the pinned AppImage):

    - Paths the program hardcodes (Dolphin's data dir, holding Sys: fonts, per-game settings) are
      rewritten to random /tmp/<name> paths that bin/01-path-mapping-hardcoded.hook links to the
      mounted bin, lib or share. We make the same links, reading the hook as data: only
      `_tmp_<dir>=<letters>` lines. Without them Dolphin 2609 ran with no Sys folder ("Trying to
      access Windows-1252 fonts", HW 2026-10-05).
    - Vulkan: sharun points the loader at the bundled drivers unless SHARUN_ALLOW_SYS_VKICD=1. Every
      emulator runs on the image's Turnip (Dolphin 2609 bundles an older Mesa).

    The self-updater hook never runs here (only AppRun sources hooks, and it also needs $APPIMAGE,
    which only the runtime sets for AppRun); DISABLE_AUTO_UPDATES=1, the hook's own off switch,
    keeps it off should a later build run its hooks some other way: RetroForge pins every version.
    """

    # The hook's name depends on the build tooling's age: PPSSPP's own anylinux build ships it as a
    # .src.hook (sourced by AppRun), pkgforge-dev's repackagings as a plain .hook. Same content.
    HOOKS = ("bin/01-path-mapping-hardcoded.hook", "bin/01-path-mapping-hardcoded.src.hook")
    HOOK_LINE = re.compile(r'_tmp_(bin|lib|share)="?([A-Za-z0-9]+)"?')

    def __init__(self, emulator, image):
        super().__init__(emulator, image)
        self.links = []

    def prepare(self):
        root = super().prepare()
        self.link_hardcoded_paths(root)
        return root

    def probe_files(self, root, binary):
        # bin/<name> is sharun's own small entry; the program it loads is shared/bin/<name>, the
        # file whose first read failed.
        real = os.path.join(root, "shared", "bin", os.path.basename(binary))
        return super().probe_files(root, binary) + ([real] if os.path.lexists(real) else [])

    def link_hardcoded_paths(self, root):
        lines = []
        for hook in self.HOOKS:
            try:
                with open(os.path.join(root, hook), errors="replace") as f:
                    lines = f.read().splitlines()
                break
            except OSError:
                continue
        for line in lines:
            m = self.HOOK_LINE.fullmatch(line)
            if m:
                self.link(os.path.join(TMP_LINK_DIR, m.group(2)), os.path.join(root, m.group(1)))

    def link(self, link, target):
        # /tmp is shared: only ever replace an entry of our own, and only a symlink.
        try:
            st = os.lstat(link)
        except FileNotFoundError:
            st = None
        except OSError as err:
            log(f"cannot check {link}: {err}")
            return
        if st is not None and (not os.path.islink(link) or st.st_uid != os.getuid()):
            log(f"{link} exists and is not a link of ours: {self.emulator} runs without "
                f"{os.path.basename(target)} files from its download")
            return
        tmp = f"{link}.retroforge-{secrets.token_hex(8)}"
        try:
            os.symlink(target, tmp)
            os.replace(tmp, link)
            self.links.append((link, target))
        except OSError as err:
            log(f"could not link {link} to {target}: {err}")
            try:
                os.unlink(tmp)
            except OSError:
                pass

    def release(self):
        for link, target in self.links:  # ours, if no later launch took it over
            try:
                if os.readlink(link) == target:
                    os.unlink(link)
            except OSError:
                pass
        super().release()

    def env(self):
        return {"SHARUN_ALLOW_SYS_VKICD": "1", "VK_DRIVER_FILES": SYSTEM_VULKAN_ICD,
                "DISABLE_AUTO_UPDATES": "1"}


class Scripts:
    """A folder of scripts retroforge-emu unpacked under $HOME (PortMaster): nothing to mount; a game is
    a script of its own (see the scripts format above)."""

    runs_rom = True

    def __init__(self, emulator, root):
        self.emulator, self.root = emulator, root

    def prepare(self):
        return self.root

    def unreadable(self, root, binary):
        return ""

    def env(self):
        return {}

    def release(self):
        """Release every runtime mount the port `mount` stand-in recorded (see above). Never raises."""
        try:
            with open(PM_MOUNTS) as f:
                entries = [line.rstrip("\n").split("\t", 1)[0] for line in f if line.strip()]
        except OSError:
            return
        live = {fields[1].replace("\\040", " ") for fields in mount_table() if len(fields) > 1}
        for dst in dict.fromkeys(entries):
            if dst in live:
                log(f"releasing {dst}, left mounted by the port")
                try:
                    subprocess.run(["fusermount", "-u", "-z", dst], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, check=False)
                except OSError as err:
                    log(f"fusermount -u {dst}: {err}")
        try:
            open(PM_MOUNTS, "w").close()
        except OSError:
            pass


class Binary:
    """A download that is one plain executable (hakuX's standalone build): retroforge-emu names it <tag>.AppImage
    all the same, `current` points at it, and it runs in place. Nothing to mount or release: the
    definition's binary is `current` itself, relative to the emulator's folder."""

    runs_rom = False

    def __init__(self, emulator, image):
        self.emulator, self.image = emulator, image

    def prepare(self):
        return os.path.dirname(self.image)

    def unreadable(self, root, binary):
        return ""

    def env(self):
        return {}

    def release(self):
        pass


AppImage.runs_rom = False
FORMATS = {"appimage": AppImage, "appimage-sharun": SharunAppImage, "scripts": Scripts,
           "binary": Binary}
