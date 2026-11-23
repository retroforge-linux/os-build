# emu_folders — the pinned folders retroforge-emu installs with an emulator whose catalog entry has
# "folders" (RetroArch's shader presets). Imported by /usr/bin/retroforge-emu, which hands in its own
# helpers (Ctx below), as to emu_cores.
#
# CATALOG: "folders": [{"name", "url", "sha256", "size", "to"}], "to" relative to $HOME: an https zip
# with ONE top-level folder, whose contents become `to`. Pinned by sha256: it changes only with the
# catalog (an OTA), so a core update never downloads it again. RetroArch's shader presets are GitHub's
# archive of one libretro/slang-shaders commit, put where RetroArch's own (hidden) Online Updater would.
#
# The folder is replaced whole (staged beside it, then renamed), so it holds exactly the pin's files. A
# MARKER in it (.retroforge-emu: the emulator, then the zip's sha256) says what is installed and that
# retroforge-emu put it there: a folder without this emulator's marker, or a symlink, is never replaced
# or deleted, and its download is not offered. What the player keeps BESIDE it (RetroArch saves presets
# to shaders/presets) is never touched; a change made inside it lasts until the pin moves.
#
# A failed folder changes nothing of what was installed; the install ends with its exit status, the
# emulator and its cores already in place.
import os
import re
import shutil
import zipfile
import zlib

KEYS = {"name", "url", "sha256", "size", "to"}


class Ctx:
    """What emu_folders needs from retroforge-emu: Fail and its exit codes, log, download, scale (where
    a download's progress lands), verify, unpack_member, discard, safe_relative, HOME, EMU_DIR, MARKER,
    SPACE_MARGIN."""

    def __init__(self, **kw):
        self.__dict__.update(kw)


def specs(ctx, emu, e):
    """The entry's folders, each checked; exit 4 before any download otherwise."""
    folders = e.get("folders")
    if not isinstance(folders, list) or not folders:
        raise ctx.Fail(ctx.EXIT_VERIFY, f"{emu}: 'folders' must be a non-empty list")
    emus = os.path.abspath(ctx.EMU_DIR)
    for f in folders:
        if not (isinstance(f, dict) and set(f) == KEYS and isinstance(f["name"], str) and f["name"]
                and isinstance(f["url"], str) and f["url"].startswith("https://")
                and re.fullmatch(r"[0-9a-f]{64}", str(f["sha256"]))
                and type(f["size"]) is int and f["size"] > 0 and ctx.safe_relative(f["to"])):
            raise ctx.Fail(ctx.EXIT_VERIFY, f"{emu}: bad folder {f!r}: name, an https url, sha256, size and "
                                            f"a relative path, nothing else")
        dest = os.path.join(ctx.HOME, f["to"])
        if os.path.commonpath([dest, emus]) in (dest, emus):
            raise ctx.Fail(ctx.EXIT_VERIFY, f"{emu}: folder {dest} and {emus} must not hold each other")
    if any(len({f[k] for f in folders}) != len(folders) for k in ("name", "to")):
        raise ctx.Fail(ctx.EXIT_VERIFY, f"{emu}: two folders with one name or target")
    return folders


def marker(ctx, dest):
    """(emulator, sha256) of the marker in `dest`; None without one."""
    try:
        with open(os.path.join(dest, ctx.MARKER), encoding="utf-8") as f:
            lines = f.read(256).split("\n")
    except (OSError, UnicodeDecodeError):
        return None
    return (lines[0], lines[1]) if len(lines) > 1 else None


def installed(ctx, emu, dest):
    """The sha256 installed at `dest`, or None; False for something there that is not ours."""
    if not os.path.lexists(dest):
        return None
    owner = None if os.path.islink(dest) else marker(ctx, dest)
    return owner[1] if owner is not None and owner[0] == emu else False


def due(ctx, emu, folders):
    """The folders an install would download: missing, or not at the catalog's pin."""
    return [f for f in folders if installed(ctx, emu, os.path.join(ctx.HOME, f["to"])) not in (False, f["sha256"])]


def install(ctx, emu, folders, d, lo, hi):
    """Download and unpack every due folder; progress lo..hi. `d` holds the download in progress."""
    for f in folders:
        dest = os.path.join(ctx.HOME, f["to"])
        if installed(ctx, emu, dest) is False:
            ctx.log(f"{emu}: ~/{f['to']} was not put there by retroforge-emu: left alone")
    todo = due(ctx, emu, folders)
    for i, f in enumerate(todo):
        ctx.scale(lo + (hi - lo) * i // len(todo), lo + (hi - lo) * (i + 1) // len(todo))
        fetch(ctx, emu, f, d)
        ctx.log(f"{emu}: {f['name']} installed in ~/{f['to']}")


def fetch(ctx, emu, f, d):
    part = os.path.join(d, f".{os.path.basename(f['to'])}.zip.part")
    try:
        if shutil.disk_usage(d).free < f["size"] + ctx.SPACE_MARGIN:
            raise ctx.Fail(ctx.EXIT_LOCAL, f"not enough free space in {d} for {f['name']}")
        ctx.download(f["url"], part, f["size"])
        ctx.verify(part, f)
        unpack(ctx, emu, part, os.path.join(ctx.HOME, f["to"]), f["sha256"])
    except OSError as err:
        raise ctx.Fail(ctx.EXIT_LOCAL, f"{f['name']}: {err}")
    finally:
        if os.path.lexists(part):
            os.unlink(part)


def side(dest, what):
    parent, name = os.path.split(dest)
    return os.path.join(parent, f".{name}.retroforge-{what}")


def unpack(ctx, emu, archive, dest, sha256):
    """The zip's single top folder becomes `dest`, staged beside it."""
    stage = side(dest, "new")
    try:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        ctx.discard(stage)
        with zipfile.ZipFile(archive) as z:
            members = z.infolist()
            tops = {m.filename.split("/", 1)[0] for m in members}
            if len(tops) != 1 or "" in tops:
                raise ctx.Fail(ctx.EXIT_VERIFY, "the archive's entries are not all in one top-level folder")
            top = tops.pop()
            if shutil.disk_usage(os.path.dirname(dest)).free < sum(m.file_size for m in members) + ctx.SPACE_MARGIN:
                raise ctx.Fail(ctx.EXIT_LOCAL, f"not enough free space to unpack {dest}")
            os.mkdir(stage, 0o755)
            for m in members:
                ctx.unpack_member(z, m, top, stage)
        with open(os.path.join(stage, ctx.MARKER), "w") as f:
            f.write(f"{emu}\n{sha256}\n")
        swap(ctx, emu, stage, dest)
    except (zipfile.BadZipFile, zipfile.LargeZipFile, zlib.error, EOFError, ValueError,
            RuntimeError, NotImplementedError) as err:
        raise ctx.Fail(ctx.EXIT_VERIFY, f"cannot read the archive: {err}")
    finally:
        tidy(ctx, stage)


def swap(ctx, emu, stage, dest):
    """Rename `stage` over `dest`, whose old contents go last; they come back if the rename fails."""
    old = side(dest, "old")
    ctx.discard(old)
    if installed(ctx, emu, dest) is False:
        raise ctx.Fail(ctx.EXIT_LOCAL, f"{dest} was not put there by retroforge-emu: left alone")
    had = os.path.lexists(dest)
    if had:
        os.rename(dest, old)
    try:
        os.rename(stage, dest)
    except OSError:
        if had:
            os.rename(old, dest)
        raise
    tidy(ctx, old)


def tidy(ctx, path):
    try:
        ctx.discard(path)
    except OSError as err:
        ctx.log(f"warning: could not clean {path}: {err}")


def listing(ctx, emu, folders):
    """`list`'s "folders": per folder whether an install would download it, and its size."""
    todo = [f["name"] for f in due(ctx, emu, folders)]
    return {f["name"]: {"due": f["name"] in todo, "size": f["size"]} for f in folders}


def remove(ctx, emu, folders):
    """Delete each folder this emulator's marker is in, and what a killed run left beside it."""
    for f in folders:
        dest = os.path.join(ctx.HOME, f["to"])
        state = installed(ctx, emu, dest)
        if state is False:
            ctx.log(f"warning: {dest} was not put there by retroforge-emu for {emu}: left alone")
        try:
            if state is not None and state is not False:  # "" is ours too: a truncated marker
                shutil.rmtree(dest)
            ctx.discard(side(dest, "new"))
            ctx.discard(side(dest, "old"))
        except OSError as err:
            raise ctx.Fail(ctx.EXIT_LOCAL, f"cannot remove {dest}: {err}")
