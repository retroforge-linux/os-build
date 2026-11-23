# window_size — an emulator's window the size of the picture it shows, for retroforge-launch
# (emulator.json "window_size").
#
# Why: gamescope fits any window to the panel, and where it pre-rotates (--composite-blit) the copy it
# makes is the WINDOW's size, which the DPU plane then scales up for free: a 600x446 RetroArch window
# scanned out as a 446x600 plane stretched to 1080x1452 (HW, Air X, 2026-11-18). A window as big as the
# game display (1280x720) has the emulator scale the picture up on the GPU first, and gamescope copy the
# bigger frame. So the window is the picture's size, and gamescope and the DPU do the rest.
#
# "retroarch-log": RetroArch sizes its window once, when video starts, from the core's base geometry
# (windowed at video_scale 1: the seed and system_settings), and never again: a core that changes its
# picture (armN64's Resolution, Genesis Plus GX's H32/H40, Snes9x's hi-res) only changes RetroArch's
# aspect. So it runs with --verbose and its stderr comes through a pipe here; each geometry line it
# logs ("[Core] Geometry: WxH, Aspect: A" at load, "[Environ] SET_GEOMETRY: ..." and
# "[Environ] SET_SYSTEM_AV_INFO: ..." after) resizes its window, found by _NET_WM_PID on $DISPLAY (the
# game's Xwayland): H tall and H x A wide, as RetroArch sizes a window with video_force_aspect, or the
# X screen's shape with "Stretch to screen" (aspect_ratio_index 24 in its configs), which gamescope
# then fits edge to edge. A picture under MIN_HEIGHT lines gets the smallest whole-number multiple that
# reaches it (Game Boy 3x = 432, GBA 3x = 480, SNES/Mega Drive/native N64 2x): RetroArch draws its
# menu, notifications and RetroAchievements pop-ups at the window's size, and its Quick Menu was
# unreadable in a 160x144 window and clear at 480x432 (HW, Air X, 2026-11-18). Never larger than the X
# screen (scaled down, shape kept). RetroArch takes the resize like any other and its swapchain
# follows (HW 2026-11-18). A line logged before the window exists waits for it.
#
# The pipe, not --log-file: RetroArch truncates its log file at start and only appends after, so a
# reader could never trim it, and a core that sets its geometry every frame would grow it all
# session. RetroArch's WARN and ERROR lines go on to the launcher's stderr (the journal); INFO and
# DEBUG stay here. Without --verbose RetroArch printed none of them.
#
# An object, for an emulator that runs fullscreen: the games DISPLAY is sized to its picture for the run,
# and the emulator fills it. {"lines": {"psx": 240}, "scale": SCALE}: the picture's lines at 1x per
# system, times the emulator's resolution scale as its settings stand once the player's options are
# applied (a change in its own menu counts from its next start):
#
#   SCALE = {"file": "main", "section": "GPU", "key": "ResolutionScale",   a setting in a file its
#            "per": 1, "default": "1", "auto": ["0"]}                       options.json names
#         | {"arg": "scale", "per": 1, "default": "1"}                      a name=value argument
#
# scale = value / per (Flycast's rend.Resolution counts lines: per 480; RPCS3 percent: per 100). A value
# in "auto", or none and no default, leaves the display alone: the emulator fits its picture to the
# screen it finds. The display keeps its shape (the games display's own, 16:9) and gets the picture's
# height, stepped up to MIN_HEIGHT as above: the emulator fits a 4:3 or 16:9 picture into it as it fits
# one into the normal display, only 1:1 in height, and no aspect has to be known here (Dolphin's auto
# is the game's own). gamescope keeps it no larger than its output.
#
# The launcher asks gamescope (x11_root.ask_xwayland_size, GAMESCOPE_XWAYLAND_MODE_CONTROL, as Steam and
# retroforge-steam-direct do for a game's resolution) before the start, waits for the X screen to
# change, and gives the old size back when the emulator exits. A journal (STATE_DIR/restore/
# games-display.json, written BEFORE the change, naming the launcher's PID and the size it set) covers a
# run that never got to (a double Exit SIGKILLs the launcher): a watcher started detached, outside the
# game's process tree (systemd-run, as retroforge-steam-direct's restore-resolution), gives the size
# back once that launcher is gone, and the next launch of any emulator does it too should the watcher
# not have. Only from the size the run set: a size someone asked for since stays. A journal is only
# ever restored by its own launcher, its watcher, or a launch after its launcher died, so a late
# watcher never undoes the next run's size. A ROM launch only: Open keeps the
# normal display for the emulator's own menus. Proven on the Air X 2026-11-18: asked for 960x544, the
# game's X server became 960x544, a fullscreen app opened at that size and the DPU plane scaled a
# 544x960 copy to the panel.
#
# THE PLAYER CAN TURN IT OFF (options.json picture_window, per emulator and per game, on by default;
# emuopts.window_size): shaders are drawn at the window's size, too few pixels for a CRT or LCD mask, and
# then scaled up. Off, the launcher never comes here and the emulator fills the games display.
#
# NEVER RAISES: an X11 failure is a warning, and the game keeps the window RetroArch made, or runs on the
# display as it was.

import json
import os
import re
import select
import sys
import threading
import time

import emuopts
import x11_root

RETROARCH_LOG = "retroarch-log"
KINDS = {RETROARCH_LOG}
GEOMETRY = re.compile(rb"\[(?:Core\] Geometry|Environ\] SET_GEOMETRY|Environ\] SET_SYSTEM_AV_INFO): "
                      rb"(\d+)x(\d+), Aspect: (\d+(?:\.\d+)?)")
QUIET = re.compile(rb"^\[(?:libretro )?(?:INFO|DEBUG)\]")
STRETCH = "24"  # RetroArch's aspect_ratio_index for Full, options.json "Stretch to screen"
MIN_HEIGHT = 430  # lines: smaller pictures go up by whole steps (above)
RETRY = 0.1  # s between looks for a window that is not there yet
WAIT_WINDOW = 30.0  # s a size waits for its window before it is dropped


def target(width, height, aspect, screen, stretch):
    """The window for a width x height picture of display `aspect` (0: square pixels) on an X screen
    of (w, h): height (times the whole step to MIN_HEIGHT) tall and that times aspect wide, the
    screen's shape with stretch; never larger than the screen."""
    sw, sh = screen
    if stretch and sw and sh:
        shape = sw / sh
    else:
        shape = aspect if aspect > 0 else width / max(height, 1)
    h = max(1, height) * max(1, -(-MIN_HEIGHT // max(1, height)))
    w = max(1, round(h * shape))
    if sw and sh and (w > sw or h > sh):
        k = min(sw / w, sh / h)
        w, h = max(1, round(w * k)), max(1, round(h * k))
    return w, h


def config_paths(args):
    """RetroArch's config files in `args`, in the order it reads them (--config, then --appendconfig
    ones, each a |-separated list): the last one to set a key wins."""
    paths = []
    for i, arg in enumerate(args):
        for flag, many in (("--config", False), ("-c", False), ("--appendconfig", True)):
            value = None
            if arg == flag and i + 1 < len(args):
                value = args[i + 1]
            elif arg.startswith(flag + "="):
                value = arg[len(flag) + 1:]
            if value is not None:
                paths += value.split("|") if many else [value]
    return paths


def stretched(args):
    """Whether RetroArch fills its window ("Stretch to screen") with the configs in `args`."""
    index = None
    for path in config_paths(args):
        try:
            with open(path, errors="replace") as f:
                for line in f:
                    key, _, value = line.partition("=")
                    if key.strip() == "aspect_ratio_index":
                        index = value.strip().strip('"')
        except OSError:
            continue
    return index == STRETCH


class RetroArchLog:
    """Reads a RetroArch's stderr until it closes, passing WARN/ERROR lines on and sizing its window
    to each geometry it logs."""

    def __init__(self, stream, pid, display, stretch, say, warn, out=None):
        self.fd = stream.fileno()
        self.pid, self.display, self.stretch = pid, display, stretch
        self.say, self.warn = say, warn
        self.out = out or sys.stderr.buffer
        self.thread = threading.Thread(target=self._run, name="window_size", daemon=True)

    def start(self):
        self.thread.start()
        return self

    def join(self, timeout=None):
        self.thread.join(timeout)

    def _line(self, line, pending):
        if not QUIET.match(line):
            try:
                self.out.write(line + b"\n")
                self.out.flush()
            except (OSError, ValueError):
                pass
        m = GEOMETRY.search(line)
        if not m:
            return pending
        width, height, aspect = int(m.group(1)), int(m.group(2)), float(m.group(3))
        if not width or not height:
            return pending
        screen = x11_root.screen_size(self.display, self.warn) if self.display else (0, 0)
        return (target(width, height, aspect, screen, self.stretch), (width, height), time.monotonic())

    def _resize(self, pending, done):
        """Try the pending size; the size now done, and what stays pending."""
        size, picture, since = pending
        if size == done:
            return done, None
        if not self.display:
            self.warn("no DISPLAY: the window keeps RetroArch's size")
            return size, None
        got = x11_root.resize_window_of(self.display, self.pid, size[0], size[1], self.warn)
        if got:
            self.say(f"window {size[0]}x{size[1]} for the {picture[0]}x{picture[1]} picture")
            return size, None
        if got is None and time.monotonic() - since < WAIT_WINDOW:
            return done, pending  # no window yet
        if got is None:
            self.warn(f"no window of PID {self.pid} after {WAIT_WINDOW:.0f} s: it keeps RetroArch's size")
        return size, None

    def _run(self):
        buf, pending, done = b"", None, None
        try:
            while True:
                ready, _, _ = select.select([self.fd], [], [], RETRY if pending else None)
                if ready:
                    chunk = os.read(self.fd, 65536)
                    if not chunk:
                        break
                    *lines, buf = (buf + chunk).split(b"\n")
                    for line in lines:
                        pending = self._line(line.rstrip(b"\r"), pending)
                if pending:
                    done, pending = self._resize(pending, done)
            if buf:
                self._line(buf, None)
        except (OSError, ValueError) as err:
            self.warn(f"stopped following the window: {err}")


def follow(kind, emu, args, display, say, warn):
    """Start following `emu` (a Popen whose stderr is a pipe) for a definition's window_size `kind`;
    the follower to join once it exits, or None."""
    if kind == RETROARCH_LOG and emu.stderr is not None:
        return RetroArchLog(emu.stderr, emu.pid, display, stretched(args), say, warn).start()
    return None


# --------------------------------------------------------------------- the games display (object) --

SCALE_KEYS = {"file", "section", "key", "arg", "per", "default", "auto"}
ARG_NAME = re.compile(r"[a-z][a-z0-9_]*")
MAX_LINES = 4320
SETTLE = 2.0  # s to wait for the X screen to take a new size


def check_display(spec):
    """Why a window_size object is wrong, or None when it is right."""
    if set(spec) != {"lines", "scale"}:
        return 'an object must have exactly "lines" and "scale"'
    lines, scale = spec["lines"], spec["scale"]
    if not (isinstance(lines, dict) and lines and all(isinstance(k, str) and type(v) is int and 0 < v <= MAX_LINES
                                                      for k, v in lines.items())):
        return f'"lines" must map systems to whole numbers of lines, 1 to {MAX_LINES}'
    if not (isinstance(scale, dict) and set(scale) <= SCALE_KEYS):
        return f'"scale" must be an object with some of {sorted(SCALE_KEYS)}'
    by_arg, by_file = "arg" in scale, "file" in scale or "key" in scale
    if by_arg == by_file:
        return '"scale" takes either "arg" or "file" and "key"'
    if by_arg and not (isinstance(scale["arg"], str) and ARG_NAME.fullmatch(scale["arg"])):
        return '"scale" "arg" must be a lowercase name'
    if by_file and not all(isinstance(scale.get(k), str) and scale.get(k) and "\n" not in scale[k] for k in ("file", "key")):
        return '"scale" "file" and "key" must be one-line strings'
    if not isinstance(scale.get("section", ""), str):
        return '"scale" "section" must be a string'
    per = scale.get("per", 1)
    if not (isinstance(per, (int, float)) and not isinstance(per, bool) and per > 0):
        return '"scale" "per" must be a number above 0'
    if scale.get("default") is not None and not isinstance(scale["default"], str):
        return '"scale" "default" must be a string'
    auto = scale.get("auto", [])
    if not (isinstance(auto, list) and all(isinstance(a, str) for a in auto)):
        return '"scale" "auto" must be a list of strings'
    return None


def _scale_value(scale, system, args, files, home, warn):
    """The scale setting's text as the emulator will read it, or None."""
    if "arg" in scale:
        value = None
        for a in args:
            name, eq, rest = a.partition("=")
            if eq and name == scale["arg"]:
                value = rest
        return value
    f = (files or {}).get(scale["file"])
    if not f:
        warn(f"window_size names file {scale['file']!r}, which options.json does not declare")
        return None
    path = os.path.join(home, f["path"].replace(emuopts.SYSTEM, system))
    try:
        with open(path, errors="replace") as fh:
            text = fh.read()
    except FileNotFoundError:
        return None
    except OSError as err:
        warn(f"cannot read {path}: {err}")
        return None
    try:
        return emuopts.get_setting(f["format"], text, scale.get("section", ""), scale["key"])
    except Exception as err:  # a settings file the emulator mangled must not stop the game
        warn(f"cannot read {scale['key']} from {path}: {err}")
        return None


def display_lines(spec, system, args, files, home, warn):
    """How many lines the emulator's picture has this run, or None to leave the display alone."""
    lines = spec["lines"].get(system)
    if lines is None:
        return None
    scale = spec["scale"]
    value = _scale_value(scale, system, args, files, home, warn)
    if value is None:
        value = scale.get("default")
    if value is None or value.strip() in scale.get("auto", []):
        return None
    try:
        k = float(value.strip()) / scale.get("per", 1)
    except ValueError:
        warn(f"window_size: {value!r} is not a number: the display keeps its size")
        return None
    return max(1, round(lines * k)) if k > 0 else None


def display_size(lines, current):
    """The games display for a picture of `lines`: that height stepped up to MIN_HEIGHT, the current
    display's shape."""
    cw, ch = current
    h = lines * max(1, -(-MIN_HEIGHT // lines))
    return max(1, round(h * cw / ch)) if cw and ch else h * 16 // 9, h


def _journal(state_dir):
    return os.path.join(state_dir, "restore", "games-display.json")


def _settle(display, before, asked, warn):
    """Wait for `display`'s X screen to leave `before` (gamescope may give less than asked: its output's
    size); its size then, or None."""
    deadline = time.monotonic() + SETTLE
    while True:
        now = x11_root.xwayland_server(display, warn)
        if now and (now[1], now[2]) != before:
            return now[1], now[2]
        if time.monotonic() > deadline:
            return None
        time.sleep(0.05)


def _ask(display, server, size, before, warn):
    if not x11_root.ask_xwayland_size(display, server, size[0], size[1], warn):
        return None
    return _settle(display, before, size, warn)


def _alive(pid):
    return os.path.exists(f"/proc/{pid}")


def _write_journal(path, record):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(record, f)
    os.replace(tmp, path)


def restore_display(state_dir, warn, owner=None, say=None):
    """Give back the games display size a run changed (its journal), if any: the journal of launcher
    `owner`, or with no owner one whose launcher is gone. Only while the display still has the size that
    run set: a size someone has asked for since stays."""
    path = _journal(state_dir)
    try:
        with open(path) as f:
            j = json.load(f)
        display, server = j["display"], int(j["server"])
        size, set_to, pid = (int(j["width"]), int(j["height"])), tuple(int(n) for n in j["set"]), int(j["pid"])
    except FileNotFoundError:
        return
    except (OSError, ValueError, KeyError, TypeError) as err:
        warn(f"dropping an unreadable {path}: {err}")
        display = None
    else:
        if owner is not None and pid != owner:
            return  # another launch's
        if owner is None and pid != os.getpid() and _alive(pid):
            return  # its launcher still runs, and gives it back itself
    if display:
        now = x11_root.xwayland_server(display, warn)
        if now and (now[1], now[2]) == set_to and set_to != size:
            if _ask(display, server, size, set_to, warn) and say:
                say(f"games display {size[0]}x{size[1]} again")
    try:
        os.unlink(path)
    except OSError:
        pass


def size_display(display, lines, state_dir, say, warn):
    """Size `display` (one of gamescope's X servers) for a picture of `lines`; a callable that gives the
    old size back, or None when nothing changed. The journal names this process and, once gamescope has
    answered, the size it gave: restore_display gives the old one back only from that size."""
    if not display:
        warn("no DISPLAY: the games display keeps its size")
        return None
    now = x11_root.xwayland_server(display, warn)
    if not now:
        warn(f"{display} is not one of gamescope's X servers: the games display keeps its size")
        return None
    server, before = now[0], (now[1], now[2])
    size = display_size(lines, before)
    if size == before:
        return None
    path = _journal(state_dir)
    record = {"display": display, "server": server, "width": before[0], "height": before[1], "set": list(size),
              "pid": os.getpid()}
    try:
        _write_journal(path, record)  # before the change: a run killed from here on is put right
    except OSError as err:
        warn(f"cannot write {path} ({err}): the games display keeps its size")
        return None
    got = _ask(display, server, size, before, warn)
    if not got:
        warn(f"gamescope did not resize {display} to {size[0]}x{size[1]}: it stays {before[0]}x{before[1]}")
        try:
            os.unlink(path)
        except OSError:
            pass
        return None
    if got != size:  # gamescope keeps it no larger than its output
        record["set"] = list(got)
        try:
            _write_journal(path, record)
        except OSError as err:
            warn(f"cannot update {path}: {err}")
    say(f"games display {got[0]}x{got[1]} for the {lines}-line picture (it was {before[0]}x{before[1]})")
    pid = os.getpid()
    return lambda: restore_display(state_dir, warn, owner=pid)


def watch_display(pid, state_dir, say, warn, poll=0.5):
    """Wait for launcher `pid` to end, then give back the size its run left (its journal, if it is still
    there): run detached, outside the game's process tree, so a SIGKILLed launch (OGUI's double Exit)
    still gets the normal size back before anything else starts."""
    while _alive(pid):
        time.sleep(poll)
    restore_display(state_dir, warn, owner=pid, say=say)
