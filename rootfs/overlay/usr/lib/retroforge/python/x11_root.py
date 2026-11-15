# x11_root — the X root window of $DISPLAY, for retroforge-launch: set or remove a string property on
# it, and count its monitors.
#
# What it is for: on a dual-screen board, gamescope (patch 0041) sends a window to the second panel
# when its title matches the regex in its Xwayland root's GAMESCOPE_SECONDARY_WINDOW_TITLE. Each
# emulator names its second screen's window its own way, so the emulator's definition says which
# (emulator.json "secondary_window_title") and the launcher sets it before the emulator starts, then
# removes it when the emulator exits. The launcher runs on the game's Xwayland ($DISPLAY), which is
# the root gamescope reads.
#
# libX11 through ctypes: the image has libX11 (gamescope, Xwayland and SDL need it) but no X tools on
# a release card (xorg-xprop is a dev package, rootfs/customize-base.sh) and no python-xlib. The value
# is UTF8_STRING, 8-bit, which gamescope reads with XGetTextProperty.
#
# Monitors: an emulator that opens one window per panel needs its X server to show both panels as
# monitors (gamescope patch 0045 gives the game's Xwayland a second output; Xwayland makes each a RandR
# monitor, which is what SDL counts as displays). DSperate exits at start in dual-window mode with fewer
# than two, so the launcher asks first (launch_def: dual_screen_args). XRRGetMonitors, libXrandr.
#
# NEVER RAISES, NEVER EXITS: Xlib's default error handler exit()s the process, so a no-op handler is
# installed first; every failure (no libX11, no display, a server error) comes back as False (0
# monitors) with the reason passed to `warn`, and the game starts all the same (on the main panel).
#
# Test seams: RETROFORGE_LIBX11, RETROFORGE_LIBXRANDR (other library paths; the tests' stand-ins).

import ctypes
import os

LIBX11 = os.environ.get("RETROFORGE_LIBX11", "libX11.so.6")
LIBXRANDR = os.environ.get("RETROFORGE_LIBXRANDR", "libXrandr.so.2")
PROP_MODE_REPLACE = 0
_ERROR_HANDLER = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
_ignore_errors = _ERROR_HANDLER(lambda _dpy, _event: 0)  # kept referenced: Xlib calls it later


def _xlib():
    x = ctypes.CDLL(LIBX11)
    x.XOpenDisplay.restype = ctypes.c_void_p
    x.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x.XDefaultRootWindow.restype = ctypes.c_ulong
    x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x.XInternAtom.restype = ctypes.c_ulong
    x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x.XChangeProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong,
                                  ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    x.XDeleteProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong]
    x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x.XSetErrorHandler.argtypes = [_ERROR_HANDLER]
    x.XSetErrorHandler.restype = ctypes.c_void_p
    return x


def _with_root(display, action, warn, fail=False):
    """action(xlib, dpy, root) on `display`'s default root, and its result (True when it returns
    None); `fail` (and warn) on any failure."""
    if not display:
        warn("no DISPLAY")
        return fail
    try:
        x = _xlib()
    except (OSError, AttributeError) as err:
        warn(f"cannot load {LIBX11}: {err}")
        return fail
    x.XSetErrorHandler(_ignore_errors)
    dpy = x.XOpenDisplay(display.encode())
    if not dpy:
        warn(f"cannot open X display {display}")
        return fail
    try:
        result = action(x, dpy, x.XDefaultRootWindow(dpy))
        x.XSync(dpy, 0)
        return True if result is None else result
    finally:
        x.XCloseDisplay(dpy)


def set_string(display, name, value, warn):
    """Set root property `name` to the UTF-8 string `value`. True when done."""
    data = value.encode()

    def action(x, dpy, root):
        utf8 = x.XInternAtom(dpy, b"UTF8_STRING", 0)
        x.XChangeProperty(dpy, root, x.XInternAtom(dpy, name.encode(), 0), utf8, 8,
                          PROP_MODE_REPLACE, data, len(data))

    return _with_root(display, action, warn)


def remove(display, name, warn):
    """Remove root property `name` (nothing happens when it is not set). True when done."""
    def action(x, dpy, root):
        x.XDeleteProperty(dpy, root, x.XInternAtom(dpy, name.encode(), 0))

    return _with_root(display, action, warn)


def monitors(display, warn):
    """How many active monitors `display`'s root has (RandR 1.5), or 0 when that cannot be told."""
    try:
        xr = ctypes.CDLL(LIBXRANDR)
        xr.XRRGetMonitors.restype = ctypes.c_void_p
        xr.XRRGetMonitors.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
        xr.XRRFreeMonitors.argtypes = [ctypes.c_void_p]
    except (OSError, AttributeError) as err:
        warn(f"cannot load {LIBXRANDR}: {err}")
        return 0

    def action(_x, dpy, root):
        n = ctypes.c_int(0)
        info = xr.XRRGetMonitors(dpy, root, 1, ctypes.byref(n))
        if not info:
            warn(f"{display} answers no RandR monitors")
            return 0
        xr.XRRFreeMonitors(info)
        return n.value

    return _with_root(display, action, warn, fail=0)
