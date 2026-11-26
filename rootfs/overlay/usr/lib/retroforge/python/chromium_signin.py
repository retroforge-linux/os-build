# chromium_signin — a store's own sign-in page in Chromium, and the code it ends with
# (/usr/lib/retroforge/store `sign-in`; .claude/plans/store-signin-window.plan.md, D2). Moved from the
# prototype (apps/retroforge-store-signin/chromium-signin.py at f8f62179); GOG and Epic HW-OK from
# Settings > Stores on the Pocket FIT, 2026-10-29.
#
# WHY CHROMIUM. Google refuses "Sign in with Google" in embedded web views (Electron, WebKit) by policy;
# Chromium is the browser itself, which Google treats as one (plan F1).
#
# THE CODE. Chromium runs with --remote-debugging-pipe: the DevTools protocol on fds 3 (our commands)
# and 4 (its answers and events), JSON messages ending in a NUL. No port is opened. Every page's address
# arrives as Target.targetInfoChanged: GOG's code is in the address it redirects to at the end; Epic's is
# in the JSON page it ends on, read with Runtime.evaluate in that page together with the page's own
# address, so a target that has gone elsewhere since is never read as Epic's.
#
# THE KEYBOARD. Nothing tells OGUI that a page's text field has the focus (an X11 window has no text-input
# protocol), so its on-screen keyboard never came up. Every page is asked for its focused field every
# TYPING_POLL s, and on_typing(True) runs when one takes the focus (or another one does), on_typing(False)
# when none has it: the plugin opens and closes the keyboard (signin_window.gd).
# The keyboard types into the plugin, not into the window: OGUI's X11 keyboard sends through InputPlumber's
# virtual keyboard, which OGUI does not find after a fresh boot (its D-Bus proxy caches InputPlumber's target
# list from before the keyboard target exists, and InputPlumber 0.82 never signals the change; Air X,
# 2026-11-01). The plugin says each edit as a JSON line on our stdin, {"type": "text", "delete": n,
# "insert": s} or {"type": "key", "key": "Enter"}, and type_in() types it into the focused field's page.
#
# THE WINDOW. App mode (one window, no address bar), fullscreen, at screen height / 720 (plan F3: 1.5 on
# 1080p, a 1280x720 page). Its profile is a private temporary folder, deleted after: no cookie outlives
# the sign-in. Chromium has its own session (process group), so nothing of it outlives us either.
# The image's /etc/chromium/policies/managed/retroforge-signin.json keeps the window bare: no bar warning
# about --disable-blink-features (below; CommandLineFlagSecurityWarningsEnabled), and no offer to save
# the password, an address or a card once the form is sent (PasswordManagerEnabled, Autofill*).
import ctypes
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

PAGE_HEIGHT = 720  # the page height the stores' sign-in forms fit without scrolling (plan F3)
CLOSE_WAIT = 10  # seconds Chromium gets to close before it is killed
FLAGS = ["--ozone-platform=x11", "--start-fullscreen", "--no-first-run", "--no-default-browser-check",
         "--disable-sync", "--password-store=basic", "--disable-features=Translate",
         # The pipe alone marks every page automation-controlled (navigator.webdriver is true), and
         # Cloudflare's check on Epic then loops forever (Air X and Pocket FIT, 2026-10-29; plan F2).
         "--disable-blink-features=AutomationControlled",
         # The arrow keys move between a page's links, fields and buttons: the D-pad sends them
         # (stores/signin-gamepad.yaml).
         "--enable-spatial-navigation"]
READ_PAGE = {"expression": "JSON.stringify([location.href, document.body ? document.body.innerText : ''])",
             "returnByValue": True}
# The page's focused text field as a key that changes when another field takes the focus, "" when none
# has it (through shadow roots and same-origin frames). Read like READ_PAGE, an evaluation that changes
# nothing: no script injected, and the Runtime domain never enabled (its events are a bot check's tell).
TYPING = {"expression": r"""(() => {
  let e = document.activeElement;
  for (;;) {
    if (e && e.shadowRoot && e.shadowRoot.activeElement) { e = e.shadowRoot.activeElement; continue; }
    let d = null;
    try { d = e && e.contentDocument; } catch (_) {}
    if (d && d.activeElement) { e = d.activeElement; continue; }
    break;
  }
  if (!e || !(e.isContentEditable || e.tagName === "TEXTAREA" || (e.tagName === "INPUT"
      && !/^(button|checkbox|color|file|hidden|image|radio|range|reset|submit)$/i.test(e.type)))) return "";
  const all = Array.from(e.getRootNode().querySelectorAll("input,textarea,[contenteditable]"));
  return [location.host, all.indexOf(e), e.name || e.id || e.type || ""].join("|");
})()""", "returnByValue": True}
TYPING_POLL = 0.5  # s between two asks of every page for its focused text field
MAX_DELETE = 256  # backspaces one edit may type; more is not the keyboard talking
# The keys type_in() presses: DevTools key name -> Windows virtual key code, and the text a press types.
KEYS = {"Backspace": (8, None), "Enter": (13, "\r")}
MAX_MESSAGE = 4 << 20  # bytes of one protocol message; more is not Chromium talking sensibly


def screen_scale(name=None):
    """Chromium's scale for the X display it opens on (name, else DISPLAY): its screen's height /
    PAGE_HEIGHT, at least 1. 1 without a screen (no libX11, no display)."""
    try:
        x11 = ctypes.CDLL("libX11.so.6")
    except OSError:
        return 1.0
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XDefaultScreen.argtypes = [ctypes.c_void_p]
    x11.XDisplayHeight.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    display = x11.XOpenDisplay(name.encode() if name else None)
    if not display:
        return 1.0
    try:
        height = x11.XDisplayHeight(display, x11.XDefaultScreen(display))
    finally:
        x11.XCloseDisplay(display)
    return max(1.0, round(height / PAGE_HEIGHT, 2))


class Pipe:
    """The DevTools protocol over Chromium's fds 3 and 4."""

    def __init__(self, write_fd, read_fd):
        self.w, self.r, self.buf, self.next_id = write_fd, read_fd, b"", 0

    def send(self, method, params=None, session=None):
        self.next_id += 1
        msg = {"id": self.next_id, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        os.write(self.w, json.dumps(msg).encode() + b"\0")
        return self.next_id

    def read(self):
        """The whole messages that have arrived (call when select says r is readable); None once
        Chromium has gone."""
        chunk = os.read(self.r, 1 << 16)
        if not chunk:
            return None
        self.buf += chunk
        *whole, self.buf = self.buf.split(b"\0")
        if len(self.buf) > MAX_MESSAGE:
            return None
        out = []
        for m in whole:
            try:
                m = json.loads(m)
            except ValueError:
                continue
            if isinstance(m, dict):
                out.append(m)
        return out

    def close(self):
        for fd in (self.w, self.r):
            try:
                os.close(fd)
            except OSError:
                pass


def _start(binary, url, profile, scale, env):
    """Chromium in app mode, its DevTools pipe on our side."""
    cmd_r, cmd_w = os.pipe()  # we write commands, it reads them on fd 3
    ans_r, ans_w = os.pipe()  # it writes on fd 4, we read
    # Out of the way of 3 and 4 first, so the dup2s below cannot overwrite one another.
    hi = [os.dup(fd) for fd in (cmd_r, ans_w)]
    for fd in (cmd_r, ans_w):
        os.close(fd)

    def child():  # pass_fds keeps 3 and 4 open in the child, which these dup2s make ours
        os.dup2(hi[0], 3)
        os.dup2(hi[1], 4)

    args = [binary, f"--app={url}", f"--user-data-dir={profile}", "--remote-debugging-pipe",
            f"--force-device-scale-factor={scale}"] + FLAGS
    try:
        # stdout to our stderr: our stdout is the events'. stdin not ours: closing it is the Cancel.
        proc = subprocess.Popen(args, preexec_fn=child, pass_fds=(3, 4), stdin=subprocess.DEVNULL,
                                stdout=sys.stderr, env=env, start_new_session=True)
    except OSError:
        for fd in hi + [cmd_w, ans_r]:
            os.close(fd)
        raise
    for fd in hi:
        os.close(fd)
    return proc, Pipe(cmd_w, ans_r)


def _close(proc, pipe):
    try:
        pipe.send("Browser.close")
        proc.wait(timeout=CLOSE_WAIT)
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)  # what is left of its session (renderers, zygote)
    except (ProcessLookupError, PermissionError):
        pass
    proc.wait()
    pipe.close()


class _Reader:
    """Turns the protocol's messages into a code: code_in_url(url) for an address that carries one,
    reads_page(url) for one whose page does, code_in_page(text) for that page's text. Each returns
    None for anything that is not a code. One read of a page at a time per target, which stops when
    the target leaves the page, its answer is an error, or the page it read is not one reads_page takes."""

    def __init__(self, pipe, code_in_url, reads_page, code_in_page):
        self.pipe, self.code_in_url, self.reads_page, self.code_in_page = pipe, code_in_url, reads_page, code_in_page
        self.pending = {}  # message id -> ("attach" | "read", target id, session)
        self.reading = set()  # target ids on a page reads_page takes

    def _read(self, tid, session):
        self.pending[self.pipe.send("Runtime.evaluate", READ_PAGE, session)] = ("read", tid, session)

    def take(self, m):
        method, params = m.get("method"), m.get("params", {})
        if method in ("Target.targetCreated", "Target.targetInfoChanged"):
            info = params.get("targetInfo", {})
            if info.get("type") != "page":
                return None
            url, tid = info.get("url", ""), info.get("targetId")
            if not self.reads_page(url):
                self.reading.discard(tid)
                return self.code_in_url(url)
            if tid not in self.reading:
                self.reading.add(tid)
                self.pending[self.pipe.send("Target.attachToTarget", {"targetId": tid, "flatten": True})] = ("attach", tid, None)
            return None
        what, tid, session = self.pending.pop(m.get("id"), (None, None, None))
        if what is None:
            return None
        if "error" in m or tid not in self.reading:
            self.reading.discard(tid)
            return None
        if what == "attach":
            session = m.get("result", {}).get("sessionId")
            if session:
                self._read(tid, session)
            else:
                self.reading.discard(tid)
            return None
        try:
            href, text = json.loads(m.get("result", {}).get("result", {}).get("value"))
        except (TypeError, ValueError):
            href, text = "", None
        if not (isinstance(href, str) and self.reads_page(href)):
            self.reading.discard(tid)  # gone elsewhere: read again only if it comes back
            return None
        code = self.code_in_page(text) if isinstance(text, str) else None
        if code is None:  # not loaded yet: read it again
            time.sleep(0.5)
            self._read(tid, session)
        return code


class _Typing:
    """THE KEYBOARD above: each page target attached once, asked for TYPING at every poll() past its
    time (one ask in flight per page), and on_typing called when the focused field's key changes."""

    def __init__(self, pipe, on_typing):
        self.pipe, self.on_typing = pipe, on_typing
        self.sessions = {}  # target id -> session
        self.keys = {}  # target id -> its focused text field's key, "" for none
        self.pending = {}  # message id -> ("attach" | "ask", target id)
        self.shown = ""  # the key on_typing last heard of
        self.due = 0.0  # time.monotonic() of the next asks

    def take(self, m):
        method, params = m.get("method"), m.get("params", {})
        if method == "Target.targetCreated":
            info = params.get("targetInfo", {})
            tid = info.get("targetId")
            if info.get("type") == "page" and tid and tid not in self.sessions:
                self.pending[self.pipe.send("Target.attachToTarget", {"targetId": tid, "flatten": True})] = ("attach", tid)
            return
        if method in ("Target.targetDestroyed", "Target.detachedFromTarget"):
            tid = params.get("targetId")
            self.sessions.pop(tid, None)
            self.keys.pop(tid, None)
            self._tell()
            return
        what, tid = self.pending.pop(m.get("id"), (None, None))
        if what == "attach" and "error" not in m and m.get("result", {}).get("sessionId"):
            self.sessions[tid] = m["result"]["sessionId"]
        elif what == "ask" and tid in self.sessions:
            value = None if "error" in m else m.get("result", {}).get("result", {}).get("value")
            self.keys[tid] = value if isinstance(value, str) else ""
            self._tell()

    def poll(self, now):
        if now < self.due:
            return
        self.due = now + TYPING_POLL
        asking = {tid for what, tid in self.pending.values() if what == "ask"}
        for tid, session in self.sessions.items():
            if tid not in asking:
                self.pending[self.pipe.send("Runtime.evaluate", TYPING, session)] = ("ask", tid)

    def type_in(self, line):
        """One line the plugin said (THE KEYBOARD above) typed into the page whose field has the focus;
        dropped when no field has it, or when it is not an edit."""
        tid = next((t for t, k in sorted(self.keys.items()) if k), None)
        session = self.sessions.get(tid)
        try:
            cmd = json.loads(line)
        except ValueError:
            return
        if not session or not isinstance(cmd, dict):
            return
        if cmd.get("type") == "text":
            delete, insert = cmd.get("delete", 0), cmd.get("insert", "")
            if not isinstance(delete, int) or not isinstance(insert, str):
                return
            for _ in range(max(0, min(delete, MAX_DELETE))):
                self._press(session, "Backspace")
            if insert:
                self.pipe.send("Input.insertText", {"text": insert}, session)
        elif cmd.get("type") == "key" and cmd.get("key") in KEYS:
            self._press(session, cmd["key"])

    def _press(self, session, key):
        code, text = KEYS[key]
        down = {"key": key, "code": key, "windowsVirtualKeyCode": code, "nativeVirtualKeyCode": code}
        self.pipe.send("Input.dispatchKeyEvent", dict(down, type="rawKeyDown"), session)
        if text:
            self.pipe.send("Input.dispatchKeyEvent", dict(down, type="char", text=text), session)
        self.pipe.send("Input.dispatchKeyEvent", dict(down, type="keyUp"), session)

    def _tell(self):
        key = next((k for _, k in sorted(self.keys.items()) if k), "")
        if key != self.shown:
            self.shown = key
            self.on_typing(bool(key))


def run(binary, url, *, env, scale, code_in_url, reads_page, code_in_page, stop_fd, timeout, on_open,
        on_typing=None):
    """Chromium on url until a page gives a code. (reason, code): ("code", code), ("closed", None) when
    the player closed the window, ("cancelled", None) when stop_fd reached its end (the plugin's
    Cancel) or SIGTERM/SIGHUP came, ("timeout", None). on_open(pid) once Chromium runs, on_typing(on)
    as a page's text field takes or loses the focus, and the lines on stop_fd typed into it (THE KEYBOARD).
    Raises OSError when it cannot
    start. A signal only sets a flag, so Chromium is always closed and the profile always deleted,
    however many come and whenever."""
    stopped = []
    old = {s: signal.signal(s, lambda *_: stopped.append(1)) for s in (signal.SIGTERM, signal.SIGHUP)}
    proc = pipe = None
    profile = tempfile.mkdtemp(prefix="retroforge-signin-")
    try:
        proc, pipe = _start(binary, url, profile, scale, env)
        on_open(proc.pid)
        reader = _Reader(pipe, code_in_url, reads_page, code_in_page)
        typing = _Typing(pipe, on_typing) if on_typing else None
        said = b""  # stop_fd's bytes past its last whole line
        try:
            pipe.send("Target.setDiscoverTargets", {"discover": True})
            deadline = time.monotonic() + timeout
            while (left := deadline - time.monotonic()) > 0:
                if stopped:
                    return "cancelled", None
                if typing:
                    typing.poll(time.monotonic())
                wait = min(left, TYPING_POLL if typing else 1.0)
                ready, _, _ = select.select([pipe.r, stop_fd], [], [], wait)
                if stop_fd in ready:
                    chunk = os.read(stop_fd, 4096)
                    if not chunk:
                        return "cancelled", None
                    *lines, said = (said + chunk).split(b"\n")
                    said = said[-MAX_MESSAGE:]
                    for line in lines:
                        if typing:
                            typing.type_in(line.decode("utf-8", "replace"))
                if pipe.r not in ready:
                    continue
                msgs = pipe.read()
                if msgs is None:
                    return "closed", None
                for m in msgs:
                    if typing:
                        typing.take(m)
                    code = reader.take(m)
                    if code:
                        return "code", code
            return "timeout", None
        except BrokenPipeError:  # it went while we wrote to it
            return "closed", None
    finally:
        if proc is not None:
            _close(proc, pipe)
        shutil.rmtree(profile, ignore_errors=True)
        for s, handler in old.items():
            signal.signal(s, handler)
