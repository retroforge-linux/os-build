# frame_cap — a game's frame-rate limit for retroforge-launch (Game settings > RetroForge > Frame rate
# limit: FPS_LIMIT=<fps> in the game's conf).
#
# gamescope caps the game it shows at the GAMESCOPE_FPS_LIMIT atom on its X server's root (our gamescope
# patch 0004 makes the atom stick; HW 2026-07-25, vkcube: 30 -> 29 fps, 20 -> 20 fps, 0 -> 59 fps), and a
# Vulkan game presents FIFO while a cap is on. The cap is gamescope's, not the window's: the launcher sets
# it on the game's X server ($DISPLAY, the root Steam writes it on too) before the start and puts back
# what it found when the emulator exits. A journal (STATE_DIR/restore/frame-cap.json, written BEFORE the
# change: the display, the value before, the value set and the launcher's PID) covers a run that never got
# to: the games display's watcher and the next launch put it back, only while the atom still holds the
# value that run set (a cap someone set since stays). As window_size's games display.
#
# NEVER RAISES: an X11 failure is a warning, and the game runs without the cap.

import json
import os
import re

import x11_root

KEY = "FPS_LIMIT"  # the game conf's line
ATOM = "GAMESCOPE_FPS_LIMIT"
VALUE = re.compile(r"[1-9][0-9]{0,2}")
MIN_FPS, MAX_FPS = 10, 240


def chosen(game_conf, warn):
    """The frame rate a game's conf limits it to, or None for none."""
    value = game_conf.get(KEY, "")
    if not value:
        return None
    if not (VALUE.fullmatch(value) and MIN_FPS <= int(value) <= MAX_FPS):
        warn(f"game setting {KEY}={value} is not a frame rate from {MIN_FPS} to {MAX_FPS}: ignored")
        return None
    return int(value)


def _journal(state_dir):
    return os.path.join(state_dir, "restore", "frame-cap.json")


def _alive(pid):
    return os.path.exists(f"/proc/{pid}")


def _put_back(display, before, warn):
    if before:
        return x11_root.set_cardinal(display, ATOM, before, warn)
    return x11_root.remove(display, ATOM, warn)


def restore(state_dir, warn, owner=None, say=None):
    """Put back the cap a run changed (its journal), if any: the journal of launcher `owner`, or with no
    owner one whose launcher is gone. Only while the atom still holds what that run set."""
    path = _journal(state_dir)
    try:
        with open(path) as f:
            j = json.load(f)
        display, before, set_to, pid = j["display"], j["before"], int(j["set"]), int(j["pid"])
        if before is not None:
            before = int(before)
    except FileNotFoundError:
        return
    except (OSError, ValueError, KeyError, TypeError) as err:
        warn(f"dropping an unreadable {path}: {err}")
        display = None
    else:
        if owner is not None and pid != owner:
            return  # another launch's
        if owner is None and pid != os.getpid() and _alive(pid):
            return  # its launcher still runs, and puts it back itself
    if display:
        read, now = x11_root.get_cardinal(display, ATOM, warn)
        if read and now == set_to and _put_back(display, before, warn) and say:
            say(f"frame rate limit {before or 'off'} again")
    try:
        os.unlink(path)
    except OSError:
        pass


def apply(display, fps, state_dir, say, warn):
    """Limit gamescope to `fps` for this run; a callable that puts back what was there, or None when
    nothing changed."""
    if not display:
        warn("no DISPLAY: no frame rate limit")
        return None
    read, before = x11_root.get_cardinal(display, ATOM, warn)
    if not read:
        warn(f"cannot read {ATOM} on {display}: no frame rate limit")
        return None
    if before == fps:
        return None
    path = _journal(state_dir)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.tmp"
        with open(tmp, "w") as f:
            json.dump({"display": display, "before": before, "set": fps, "pid": os.getpid()}, f)
        os.replace(tmp, path)  # before the change: a run killed from here on is put right
    except OSError as err:
        warn(f"cannot write {path} ({err}): no frame rate limit")
        return None
    if not x11_root.set_cardinal(display, ATOM, fps, warn):
        warn(f"could not set {ATOM} on {display}: no frame rate limit")
        try:
            os.unlink(path)
        except OSError:
            pass
        return None
    say(f"frame rate limited to {fps} fps (it was {before or 'off'})")
    pid = os.getpid()
    return lambda: restore(state_dir, warn, owner=pid)
