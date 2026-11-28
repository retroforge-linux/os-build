#!/usr/bin/env bash
# Offline test for /usr/lib/retroforge/store (GOG and Epic, .claude/plans/stores.plan.md).
#
#   tests/test-store.sh
#
# Fake legendary and gogdl (RETROFORGE_STORE_TOOL_*), a fake runtime, Proton and game runner, and a
# local server for every https:// request (RETROFORGE_STORE_API): GOG's APIs, the tools' releases and
# the runtime's channel. Rules: a tool is set up only from its pinned sha256, unpacked and compiled;
# sign-in (a fake Chromium on the DevTools pipe) opens the store's own page with the plan's flags in a
# private profile deleted after, takes a code only from the store's https end page, closes the window
# (killing what does not close, also on Cancel and SIGTERM) and then signs in; tokens are the player's
# only (0600); the libraries list owned Windows games with art and their install state; installs report
# N% and fail on what the tool logs (legendary exits 0 either way); a launch sets the prefix up once,
# syncs saves down, runs the game through Proton in the runtime (both at oom_score_adj 900, the store at
# the session's), syncs them up, and does not upload after a failed download; a GOG conflict keeps the
# last sync time; the game's environment names its umu id and store for protonfixes, from the
# umu-database cached at install and fetched again only when a day old (kept when that fails), or turns
# protonfixes off when the player did; RetroForge's own fixes (game-fixes.json) set their INI keys in the
# prefix before the game starts, keeping the file's other lines, and go off with protonfixes.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$ROOT/rootfs/overlay/usr/lib/retroforge/store"
[ -f "$STORE" ] || { echo "missing: $STORE" >&2; exit 1; }
T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

python3 - "$STORE" "$T" "$ROOT" <<'PY'
import hashlib, http.server, io, json, os, re, resource, shutil, signal, stat, subprocess, sys, tarfile, threading, time
import urllib.error, urllib.parse, urllib.request, zipfile

STORE, T, ROOT = sys.argv[1:4]
PASS = FAIL = 0
CASE = ""


def ok(cond, what, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   {CASE} -- {what}")
    else:
        FAIL += 1
        print(f"  FAIL {CASE} -- {what}" + (f": {detail}" if detail else ""))


# ---- the fake world --------------------------------------------------------------------------------
HOME = os.path.join(T, "home")
FAKE = os.path.join(T, "fake")
for d in (HOME, FAKE):
    os.makedirs(d)
DATA = os.path.join(HOME, ".local/share/retroforge/stores")
CONF = os.path.join(HOME, ".config/retroforge/stores")
CALLS = os.path.join(FAKE, "calls")

buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as z:
    z.writestr("__main__.py", "import sys\nprint('fake tool', sys.argv[1:])\n")
    z.writestr("pkg/__init__.py", "X = 1\n")
ZIPAPP = b"#!/usr/bin/env python3\n" + buf.getvalue()
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w:xz") as tar:
    body = b"#!/bin/sh\nexit 0\n"
    info = tarfile.TarInfo("SteamLinuxRuntime_4-arm64/_v2-entry-point")
    info.size, info.mode = len(body), 0o755
    tar.addfile(info, io.BytesIO(body))
RT = buf.getvalue()
UMU_ROUTE = "/raw.githubusercontent.com/Open-Wine-Components/umu-database/main/umu-database.csv"
UMU_HEAD = "TITLE,STORE,CODENAME,UMU_ID,COMMON ACRONYM (Optional),NOTE (Optional),EXE_STRINGS (Optional)\n"
# GOG 1 and Epic's Fortnite2 (its app name in another case), each also listed under the other store.
UMU_CSV = (UMU_HEAD + "Game One,gog,1,umu-1001,,,\nElsewhere,egs,1,umu-9999,,,\nGame Two,egs,fortnite2,umu-2002,g2,,\n"
           "Misfiled,gog,Fortnite2,umu-8888,,,\n").encode()
ROUTES = {
    UMU_ROUTE: UMU_CSV,
    "/github.com/x/tool": ZIPAPP,
    "/repo.steampowered.com/rt/VERSION.txt": b"4.0.1\n",
    "/repo.steampowered.com/rt/SHA256SUMS": (hashlib.sha256(RT).hexdigest() + " *SteamLinuxRuntime_4-arm64.tar.xz\n").encode(),
    "/repo.steampowered.com/rt/SteamLinuxRuntime_4-arm64.tar.xz": RT,
    "/users.gog.com/users/u1": {"username": "gogtester"},
    "/galaxy-library.gog.com/users/u1/releases": {"items": [{"platform_id": "gog", "external_id": "1"},
                                                            {"platform_id": "steam", "external_id": "9"}],
                                                  "next_page_token": "p2"},
    "/galaxy-library.gog.com/users/u1/releases?page_token=p2": {"items": [{"platform_id": "gog", "external_id": "2"},
                                                                          {"platform_id": "gog", "external_id": "3"}]},
    "/gamesdb.gog.com/platforms/gog/external_releases/1": {
        "type": "game", "title": {"*": "Game One"}, "supported_operating_systems": [{"slug": "windows"}],
        "game": {"visible_in_library": True, "vertical_cover": {"url_format": "https://images.gog.com/v1{formatter}.{ext}"},
                 "logo": {"url_format": "https://images.gog.com/l1{formatter}.{ext}"}}},
    "/gamesdb.gog.com/platforms/gog/external_releases/2": {"type": "dlc", "title": {"*": "A DLC"},
                                                           "supported_operating_systems": [{"slug": "windows"}]},
    "/gamesdb.gog.com/platforms/gog/external_releases/3": {"type": "game", "title": {"*": "Linux Only"},
                                                           "supported_operating_systems": [{"slug": "linux"}]},
    "/images.gog.com/v1_glx_vertical_cover.jpg": b"\xff\xd8\xff gog cover",
    "/cdn.epic/tall.jpg?w=360&resize=1&quality=medium": b"\xff\xd8\xff epic cover",
    "/remote-config.gog.com/components/galaxy_client/clients/c1?component_version=2.0.45": {
        "content": {"Windows": {"cloudStorage": {"enabled": True, "locations": [
            {"name": "saves", "location": "<?APPLICATION_DATA_LOCAL?>/Game One/Saves"}]}}}},
}
SEEN = []


class Api(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        SEEN.append((self.path, self.headers.get("Authorization", "")))
        body = ROUTES.get(self.path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        body = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Api)
threading.Thread(target=api.serve_forever, daemon=True).start()
API = f"http://127.0.0.1:{api.server_address[1]}"

PINS = os.path.join(T, "pins")
os.makedirs(PINS)
for name in ("legendary", "gogdl"):
    with open(os.path.join(PINS, f"{name}.pin"), "w") as f:
        f.write(f"name: {name}\ntag: 1.0\nurl: https://github.com/x/tool\nsha256: {hashlib.sha256(ZIPAPP).hexdigest()}\n")
OWN_FIXES = os.path.join(ROOT, "rootfs/overlay/usr/share/retroforge/stores/game-fixes.json")
shutil.copy(OWN_FIXES, PINS)
with open(os.path.join(PINS, "steamrt4.pin"), "w") as f:
    f.write("name: rt\nbase: https://repo.steampowered.com/rt\nasset: SteamLinuxRuntime_4-arm64.tar.xz\n")


def script(name, body):
    path = os.path.join(FAKE, name)
    with open(path, "w") as f:
        f.write("#!/usr/bin/env python3\nimport json, os, sys\n"
                f"CALLS = {CALLS!r}\n"
                "def call(*extra):\n"
                "    with open(CALLS, 'a') as f:\n"
                "        f.write(json.dumps([os.path.basename(sys.argv[0])] + sys.argv[1:] + list(extra)) + '\\n')\n"
                + body)
    os.chmod(path, 0o755)
    return path


LEGENDARY = script("legendary", r'''
cfg = os.environ["LEGENDARY_CONFIG_PATH"]
os.makedirs(cfg, exist_ok=True)
a = [x for x in sys.argv[1:] if x != "-y"]
inst = os.path.join(cfg, "installed.json")
installed = json.load(open(inst)) if os.path.exists(inst) else {}
call(os.environ.get("STEAM_COMPAT_DATA_PATH", ""))
once = os.environ.get("FAKE_FAIL_ONCE")  # a marker path: the first list fails (a network stall), later ones do not
if once and a[0] == "list" and not os.path.exists(once):
    open(once, "w").close()
    print("requests.exceptions.ReadTimeout: HTTPSConnectionPool(host='launcher-public-service-prod06.ol.epicgames.com')", file=sys.stderr)
    print("[cli] ERROR: could not list games", file=sys.stderr)
    sys.exit(1)
refresh = os.environ.get("FAKE_EPIC_REFRESH")
if refresh and a[0] != "auth":  # legendary 0.21.1 core._login, then the command's own line
    if refresh == "refused":
        print("[Core] ERROR: Stored credentials are no longer valid! Please login again.", file=sys.stderr)
        os.remove(os.path.join(cfg, "user.json"))  # lock.clear()
    else:
        print("[Core] ERROR: HTTP request for login failed: ConnectionError(), please try again later.", file=sys.stderr)
    print("[cli] ERROR: Login failed, cannot continue!", file=sys.stderr)
    sys.exit(1)
if a[:2] == ["auth", "--delete"]:
    if os.path.exists(os.path.join(cfg, "user.json")): os.remove(os.path.join(cfg, "user.json"))
elif a[:2] == ["auth", "--code"]:
    if a[2] == "0123456789abcdef0123456789abcdef":
        json.dump({"displayName": "Tester", "refresh_token": "r", "account_id": "a"}, open(os.path.join(cfg, "user.json"), "w"))
        print('[cli] INFO: Successfully logged in as "Tester"', file=sys.stderr)
    else:
        print("[Core] ERROR: Logging in failed with InvalidCredentialsError(), please try again.", file=sys.stderr)
elif a[0] == "list":
    print(json.dumps([{"app_name": "Fortnite2", "app_title": "Game Two", "metadata": {"keyImages": [
        {"type": "DieselGameBoxTall", "url": "https://cdn.epic/tall.jpg"}, {"type": "DieselGameBox", "url": "https://cdn.epic/wide.jpg"}]}},
        {"app_name": "Plain", "app_title": "Plain Game", "metadata": {}},
        {"app_name": "Extras", "app_title": "Game Two Content", "metadata": {"categories": [
            {"path": "public"}, {"path": "digitalextras"}, {"path": "games"}, {"path": "applications"}]}},
        {"app_name": "Asset", "app_title": "An Unreal asset", "metadata": {"categories": [{"path": "assets"}]}}]))
elif a[0] == "install":
    app = a[1]
    base = a[a.index("--base-path") + 1]
    if os.environ.get("FAKE_INSTALL_SLOW"):  # a download under way, for the cancel
        print("[DLManager] INFO: = Progress: 5.00% (1/2)", file=sys.stderr, flush=True)
        import time
        time.sleep(30)
    crash = os.environ.get("FAKE_INSTALL_CRASH")  # a marker path, or "always": a traceback, exit 1, no ERROR line
    if crash and (crash == "always" or not os.path.exists(crash)):
        if crash != "always":
            open(crash, "w").close()
        print("Traceback (most recent call last):", file=sys.stderr)
        print("requests.exceptions.ReadTimeout: HTTPSConnectionPool(host='egdownload.fastly-edge.com'): Read timed out.", file=sys.stderr)
        sys.exit(1)
    for pct in ("10.00", "55.50", "100.00"):
        print(f"[DLManager] INFO: = Progress: {pct}% (1/2), Running for 00:00:01, ETA: 00:00:01", file=sys.stderr, flush=True)
    if app == "broken":
        print("[DLManager] ERROR: Installation failed after 3 seconds.", file=sys.stderr)
    else:
        os.makedirs(os.path.join(base, app, "Bin"), exist_ok=True)
        installed[app] = {"app_name": app, "install_path": os.path.join(base, app), "is_dlc": False}
        json.dump(installed, open(inst, "w"))
elif a[0] == "uninstall":
    installed.pop(a[1], None)
    json.dump(installed, open(inst, "w"))
elif a[0] == "launch":
    g = installed[a[1]]["install_path"]
    print(json.dumps({"game_executable": "Bin\\Game.exe", "game_directory": g, "working_directory": g + "/Bin",
                      "game_parameters": ["-x"], "user_parameters": [], "egl_parameters": ["-AUTH_PASSWORD=xc"]}))
elif a[0] == "sync-saves":
    if os.environ.get("FAKE_SYNC_FAIL"):
        print("[cli] ERROR: could not reach the cloud", file=sys.stderr)
''')
GOGDL = script("gogdl", r'''
a = sys.argv[1:]
auth = a[a.index("--auth-config-path") + 1]
a = a[a.index("--auth-config-path") + 2:]
call()
creds = {"access_token": "tok", "refresh_token": "r", "user_id": "u1", "expires_in": 3600, "loginTime": 1}
if a[:2] == ["auth", "--code"]:
    if a[2] == "goodcode123":
        json.dump({"46899977096215655": creds}, open(auth, "w"))
        print(json.dumps(creds))
    else:
        print(json.dumps({"error": True}))
elif a == ["auth"]:
    refresh = os.environ.get("FAKE_GOG_REFRESH")  # gogdl 1.3.1 auth.py: null either way, a log line offline
    once = os.environ.get("FAKE_FAIL_ONCE")
    if once and not os.path.exists(once):
        open(once, "w").close()
        refresh = "unreached"
    if refresh == "unreached":
        print("[AUTH] ERROR: Failed to refresh credentials", file=sys.stderr)
    print(json.dumps(creds) if os.path.exists(auth) and not refresh else "null")
elif a[0] == "info":
    print(json.dumps({"folder_name": "Game One" if a[1] == "1" else f"Game {a[1]}", "buildId": "b1", "versionEtag": "e1"}))
elif a[0] == "download":
    base = a[a.index("--path") + 1]
    for p in ("12.50", "99.00"):
        print(f"[PROGRESS] INFO: = Progress: {p} 1/8, Running for: 00:00:01, ETA: 00:00:01", file=sys.stderr, flush=True)
    d = os.path.join(base, "Game One" if a[1] == "1" else f"Game {a[1]}")
    os.makedirs(os.path.join(d, "BIN"), exist_ok=True)
    json.dump({"clientId": "c1", "playTasks": [{"type": "FileTask", "path": "bin\\game.exe", "isPrimary": True,
               "arguments": "-a \"two words\"", "workingDir": "bin"}]}, open(os.path.join(d, f"goggame-{a[1]}.info"), "w"))
    open(os.path.join(d, "BIN", "game.exe"), "w").close()
elif a[0] == "save-sync":
    if os.environ.get("FAKE_CONFLICT"):
        print("[SAVES] WARNING: Files in conflict force downloading or uploading of files", file=sys.stderr)
        sys.stdout.write("1800000000.0")
    else:
        sys.stdout.write("1700000000.5")
''')
RUNNER = script("runner", r'''
with open(os.path.join(os.path.dirname(CALLS), "oom"), "a") as f:
    f.write(json.dumps(["boot" if "wineboot" in sys.argv else "game", open("/proc/self/oom_score_adj").read().strip(),
                        open(f"/proc/{os.getppid()}/oom_score_adj").read().strip(),
                        __import__("resource").getrlimit(__import__("resource").RLIMIT_CORE)]) + "\n")
w = os.environ.get("FAKE_WATCH")
with open(os.path.join(os.path.dirname(CALLS), "vram"), "w") as f:
    f.write(" ".join(k for k in os.environ if "VRAM_REPORT_LIMIT" in k))
call({**{k: os.environ.get(k) for k in ("UMU_ID", "STORE", "PROTONFIXES_DISABLE")}, **({"watch": os.path.exists(w)} if w else {})}, os.environ.get("STEAM_FEX_TSOENABLED", ""), os.environ.get("STEAM_COMPAT_INSTALL_PATH", ""), os.environ.get("STEAM_COMPAT_LIBRARY_PATHS", ""),
     os.getcwd(), os.environ.get("STEAM_COMPAT_DATA_PATH", ""), os.environ.get("STEAM_COMPAT_CLIENT_INSTALL_PATH", ""),
     os.environ.get("STEAM_COMPAT_TOOL_PATHS", ""))
if "wineboot" in sys.argv:
    pfx = os.path.join(os.environ["STEAM_COMPAT_DATA_PATH"], "pfx")
    os.makedirs(pfx, exist_ok=True)
    open(os.path.join(pfx, "user.reg"), "w").close()
sys.exit(int(os.environ.get("FAKE_GAME_RC", "0")))
''')
PROTON = os.path.join(FAKE, "proton-x")
os.makedirs(PROTON)
open(os.path.join(PROTON, "proton"), "w").close()
COMPAT_LOG = os.path.join(FAKE, "compat-tools.log")  # its arguments, a line a run
COMPAT = script("compat-tools", f"""
open({COMPAT_LOG!r}, "a").write(" ".join(sys.argv[1:]) + "\\n")
if sys.argv[1:] == ["status"]:  # what is installed, from the card: FAKE_NO_PROTON, none
    have = not os.environ.get("FAKE_NO_PROTON")
    print(json.dumps({{"name": "proton-cachyos-arm64", "installed": "x" if have else None, "path": {PROTON!r} if have else None}}))
else:
    print({PROTON!r})
""")
RUNTIME = os.path.join(FAKE, "runtime")
os.makedirs(RUNTIME)

BASE_ENV = dict(os.environ, HOME=HOME, XDG_CONFIG_HOME=os.path.join(HOME, ".config"),
                XDG_DATA_HOME=os.path.join(HOME, ".local/share"), RETROFORGE_STORE_PINS=PINS,
                RETROFORGE_STORE_API=API, RETROFORGE_STORE_TOOL_LEGENDARY=LEGENDARY, RETROFORGE_STORE_TOOL_GOGDL=GOGDL,
                RETROFORGE_STORE_RUNTIME=RUNTIME, RETROFORGE_STEAM_COMPAT_TOOLS=COMPAT, RETROFORGE_STORE_RUN=RUNNER,
                RETROFORGE_STORE_CHROMIUM=os.path.join(FAKE, "chromium"), RETROFORGE_STORE_SCALE="1.5",
                RETROFORGE_STEAM_ROOT=os.path.join(HOME, "no-steam"), RETROFORGE_GAME_PROFILE=os.path.join(FAKE, "game_profile"))


def store(*args, env=None, unset=()):
    e = dict(BASE_ENV, **(env or {}))
    for k in unset:
        e.pop(k, None)
    return subprocess.run([sys.executable, STORE] + list(args), env=e, text=True, capture_output=True, timeout=60)


def calls():
    try:
        return [json.loads(line) for line in open(CALLS)]
    except FileNotFoundError:
        return []


def reset_calls():
    if os.path.exists(CALLS):
        os.remove(CALLS)


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def game_run(cs):
    """The runner call that ran the game (not the prefix's wineboot)."""
    return next((c for c in cs if c[0] == "runner" and "waitforexitandrun" in c), None)


# ---- setup ---------------------------------------------------------------------------------------
CASE = "setup"
r = store("epic", "status", unset=["RETROFORGE_STORE_TOOL_LEGENDARY"])
ok(r.returncode == 0 and json.loads(r.stdout)["ready"] is False, "not ready before setup", r.stdout + r.stderr)
bad_pins = os.path.join(T, "badpins")
os.makedirs(bad_pins)
for f in os.listdir(PINS):
    text = open(os.path.join(PINS, f)).read()
    open(os.path.join(bad_pins, f), "w").write(re.sub(r"sha256: \w+", "sha256: " + "0" * 64, text))
r = store("epic", "setup", env={"RETROFORGE_STORE_PINS": bad_pins}, unset=["RETROFORGE_STORE_TOOL_LEGENDARY"])
ok(r.returncode == 1 and "sha256 mismatch" in r.stderr and not os.path.exists(os.path.join(DATA, "tools", "legendary-1.0")),
   "a download whose sha256 is not the pin's is refused, nothing set up", r.stderr)
r = store("epic", "setup", unset=["RETROFORGE_STORE_TOOL_LEGENDARY"])
tool = os.path.join(DATA, "tools", "legendary-1.0")
pycs = [os.path.join(d, f) for d, _, fs in os.walk(tool) for f in fs if f.endswith(".pyc")]
ok(r.returncode == 0 and r.stdout.strip().endswith("100%") and os.path.isfile(os.path.join(tool, "__main__.py")) and pycs,
   "the pinned zipapp is unpacked and compiled", r.stdout + r.stderr)
ok(pycs and all(int.from_bytes(open(p, "rb").read(8)[4:8], "little") == 3 for p in pycs), "its bytecode is checked-hash")
r = store("epic", "status", unset=["RETROFORGE_STORE_TOOL_LEGENDARY"])
ok(json.loads(r.stdout)["ready"] is True, "ready after setup")
r = subprocess.run([sys.executable, tool, "x"], text=True, capture_output=True)
ok("fake tool ['x']" in r.stdout, "it runs unpacked", r.stdout + r.stderr)


# ---- sign-in -------------------------------------------------------------------------------------
# A fake Chromium on the DevTools pipe (fds 3 and 4): FAKE_CHROMIUM picks how the store's pages go.
# It records its command line, its profile, its pid and the gamepad profile declared when it started, and
# leaves a cookie in the profile. The focused-field asks (TYPING) are logged as "typing", not as the
# Runtime.evaluate of a page read, and answer "" (no field) unless the mode is "typing".
EPIC_REDIRECT = "https://www.epicgames.com/id/api/redirect?clientId=34a02cf8f4414e29b15921876da36f9a&responseType=code"
CHROME_LOG = os.path.join(FAKE, "chromium.json")
CHROMIUM = os.path.join(FAKE, "chromium")
with open(CHROMIUM, "w") as f:
    f.write(r'''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
mode = os.environ.get("FAKE_CHROMIUM", "gog")
argv = sys.argv[1:]
profile = next(a.split("=", 1)[1] for a in argv if a.startswith("--user-data-dir="))
child = subprocess.Popen(["sleep", "300"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) if mode == "stubborn" else None
decl = os.environ.get("RETROFORGE_GAME_PROFILE", "")
json.dump({"argv": argv, "profile": profile, "profile_mode": os.stat(profile).st_mode & 0o777, "pid": os.getpid(),
           "own_session": os.getsid(0) == os.getpid(), "display": os.environ.get("DISPLAY"), "child": child.pid if child else None,
           "declared": open(decl).read() if decl and os.path.exists(decl) else None, "methods": []},
          open(sys.argv[0] + ".json", "w"))
# what the page's focused field is at each ask, in mode "typing": none, a field, the same one, another, none
fields = ["", "login.gog.com|0|username", "login.gog.com|0|username", "login.gog.com|1|password", ""]
open(os.path.join(profile, "Cookies"), "w").write("session")
print("chromium noise", flush=True)
if mode == "stubborn":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
methods, buf, reads = [], b"", 0
def send(m):
    os.write(4, json.dumps(m).encode() + b"\0")
def target(url, kind="page", tid="T1"):
    send({"method": "Target.targetInfoChanged", "params": {"targetInfo": {"targetId": tid, "type": kind, "url": url}}})
while True:
    chunk = os.read(3, 65536)
    if not chunk:
        break
    buf += chunk
    *msgs, buf = buf.split(b"\0")
    for raw in msgs:
        m = json.loads(raw)
        asks = m["method"] == "Runtime.evaluate" and "activeElement" in m.get("params", {}).get("expression", "")
        methods.append("typing" if asks else m["method"])
        if m["method"].startswith("Input."):  # what the helper typed, in order
            methods.append(m["method"] + " " + json.dumps(m.get("params", {}), sort_keys=True))
        log = json.load(open(sys.argv[0] + ".json"))
        log["methods"] = methods
        json.dump(log, open(sys.argv[0] + ".json", "w"))
        if m["method"] == "Target.setDiscoverTargets":
            send({"id": m["id"], "result": {}})
            os.write(4, b"not json\0")
            start = next(a.split("=", 1)[1] for a in argv if a.startswith("--app="))
            send({"method": "Target.targetCreated", "params": {"targetInfo": {"targetId": "T1", "type": "page", "url": start}}})
            if mode == "gog":
                target("https://embed.gog.com/on_login_success?origin=client&code=workercode123", kind="service_worker", tid="W")
                target("https://evil.example/on_login_success?code=evilcode123")
                target("http://embed.gog.com/on_login_success?origin=client&code=httpcode1234")
                target("https://embed.gog.com/on_login_success?origin=client&code=x")
                target("https://embed.gog.com/on_login_success?origin=client&code=goodcode123")
            elif mode.startswith("epic"):
                target("https://www.epicgames.com/id/api/redirect?clientId=x&responseType=code")
            elif mode == "close":
                sys.exit(0)
            elif mode == "replace":  # another launcher declares its profile over ours, then the window closes
                open(decl, "w").write("/other/profile.yaml\n1\n")
                sys.exit(0)
        elif m["method"] == "Target.attachToTarget":
            send({"id": m["id"], "result": {"sessionId": "S1"}})
        elif m["method"].startswith("Input."):
            send({"id": m["id"], "sessionId": m.get("sessionId"), "result": {}})
            if mode == "type" and m["params"].get("key") == "Enter" and m["params"].get("type") == "keyUp":
                time.sleep(0.3)
                sys.exit(0)
        elif asks and mode == "type":  # one field keeps the focus until Enter is typed into it
            send({"id": m["id"], "sessionId": "S1", "result": {"result": {"type": "string", "value": "login.gog.com|0|username"}}})
        elif asks:
            field = fields.pop(0) if mode == "typing" and fields else ""
            send({"id": m["id"], "sessionId": "S1", "result": {"result": {"type": "string", "value": field}}})
            if mode == "typing" and not fields:
                time.sleep(0.3)
                sys.exit(0)
        elif m["method"] == "Runtime.evaluate":
            reads += 1
            code = os.environ.get("FAKE_EPIC_CODE", "0123456789abcdef0123456789abcdef")
            page = json.dumps({"redirectUrl": "x", "authorizationCode": code})
            if mode == "epic-error":  # the target went: an error, then the window closes
                send({"id": m["id"], "error": {"code": -32000, "message": "target closed"}})
                time.sleep(1.5)
                sys.exit(0)
            if mode == "epic-foreign":  # navigated elsewhere before the read: a page of another origin
                send({"id": m["id"], "sessionId": "S1", "result": {"result": {"type": "string", "value": json.dumps(
                    ["https://evil.example/id/api/redirect", page])}}})
                time.sleep(1.5)
                sys.exit(0)
            text = ["", json.dumps({"authorizationCode": None}), page][min(reads, 3) - 1]
            send({"id": m["id"], "sessionId": "S1", "result": {"result": {"type": "string", "value": json.dumps(
                ["https://www.epicgames.com/id/api/redirect?clientId=x&responseType=code", text])}}})
        elif m["method"] == "Browser.close" and mode != "stubborn":
            sys.exit(0)
''')
os.chmod(CHROMIUM, 0o755)


def chromium_log():
    try:
        return json.load(open(CHROME_LOG))
    except (FileNotFoundError, ValueError):
        return {}


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    try:  # a zombie of ours is gone as far as the player is concerned
        return open(f"/proc/{pid}/stat").read().split(")")[-1].split()[0] != "Z"
    except FileNotFoundError:
        return False


def sign_in(name, mode, env=None, stop=None, args=()):
    """`store <name> sign-in` with the fake Chromium in mode; (events, the process's exit status,
    stderr). stop(proc) runs once Chromium is open (the plugin's Cancel, a SIGTERM)."""
    if os.path.exists(CHROME_LOG):
        os.remove(CHROME_LOG)
    proc = subprocess.Popen([sys.executable, STORE, name, "sign-in", *args], env=dict(BASE_ENV, FAKE_CHROMIUM=mode, **(env or {})),
                            text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    events = []
    if stop:
        line = proc.stdout.readline()
        events.append(json.loads(line) if line else {})
        for _ in range(50):
            if chromium_log().get("methods"):
                break
            time.sleep(0.1)
        stop(proc)
    # stdin stays open (closing it is the Cancel) until the helper is done.
    timer = threading.Timer(60, proc.kill)
    timer.start()
    out, err = proc.stdout.read(), proc.stderr.read()
    proc.wait()
    timer.cancel()
    if not proc.stdin.closed:
        proc.stdin.close()
    try:
        events += [json.loads(l) for l in out.splitlines()]
    except ValueError:
        events.append({"not json": out})
    return events, proc.returncode, err


def kinds(events):
    return [e.get("state") or e.get("event") for e in events]


CASE = "sign-in gog"
events, rc, err = sign_in("gog", "gog")
log = chromium_log()
ok(kinds(events) == ["open", "closed", "code", "signed_in"] and events[0].get("pid") == log.get("pid")
   and events[-1].get("account") == "gogtester", "Chromium opens, closes, then the code signs in as the account's name",
   str(events) + err[-300:])
ok(rc == 0, "exit 0", err[-300:])
argv = log.get("argv", [])
gog_url = "https://auth.gog.com/auth?client_id=46899977096215655&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=galaxy"
ok(f"--app={gog_url}" in argv, "on GOG's own sign-in page, in app mode", str(argv))
ok("--remote-debugging-pipe" in argv and not [a for a in argv if a.startswith("--remote-debugging-port")],
   "driven over the pipe, no port")
ok("--disable-blink-features=AutomationControlled" in argv, "not marked automation-controlled (Cloudflare, F2)")
ok("--force-device-scale-factor=1.5" in argv and "--start-fullscreen" in argv, "fullscreen, at the screen's scale (F3)")
ok(log.get("profile_mode") == 0o700 and not os.path.exists(log.get("profile", "/")), "its profile is private, and gone after",
   str(log.get("profile")))
ok(log.get("own_session") is True and log.get("methods", [])[-1:] == ["Browser.close"], "its own session, closed by us",
   str(log.get("methods")))
gog_codes = [c for c in calls() if c[0] == "gogdl" and "--code" in c]
ok([c[c.index("--code") + 1] for c in gog_codes][-1:] == ["goodcode123"] and len(gog_codes) == 1,
   "only the https embed.gog.com page's code is used (not a worker's, another host's, http, or a malformed one)",
   str(gog_codes))
ok(("/users.gog.com/users/u1", "Bearer tok") in SEEN, "the name comes from GOG's users API with the token")
ok(mode(os.path.join(CONF, "gog-auth.json")) == 0o600 and mode(os.path.join(CONF, "gog-account.json")) == 0o600,
   "the tokens and the account are the player's only")
r = store("gog", "status")
ok(json.loads(r.stdout) == {"ready": True, "signed_in": True, "account": "gogtester"}, "status", r.stdout)

CASE = "sign-in epic"
events, rc, err = sign_in("epic", "epic", env={"FAKE_EPIC_CODE": "ffffffffffffffffffffffffffffffff"})
ok(kinds(events) == ["open", "closed", "code", "error"] and "Logging in failed" in events[-1].get("message", "")
   and rc == 1 and err.strip().splitlines()[-1].startswith("store: "), "a code Epic refuses: an error, exit 1",
   str(events) + err[-300:])
reset_calls()
events, rc, err = sign_in("epic", "epic")
log = chromium_log()
epic_url = "https://www.epicgames.com/id/login?redirectUrl=" + urllib.parse.quote(EPIC_REDIRECT, safe="")
ok(kinds(events) == ["open", "closed", "code", "signed_in"] and events[-1].get("account") == "Tester" and rc == 0,
   "the code on Epic's redirect page signs in", str(events) + err[-300:])
ok(f"--app={epic_url}" in log.get("argv", []), "on Epic's sign-in, redirecting to legendary's client's code page",
   str(log.get("argv")))
ok(log.get("methods", []).count("Runtime.evaluate") == 3 and "Target.attachToTarget" in log.get("methods", []),
   "the page is read until its JSON has the code", str(log.get("methods")))
legend = [c for c in calls() if c[0] == "legendary"]
ok([c[1:3] for c in legend] == [["auth", "--delete"], ["auth", "--code"]],
   "an earlier sign-in is dropped first (legendary keeps it over a new code)", str(legend))
r = store("epic", "status")
ok(json.loads(r.stdout)["account"] == "Tester", "status reads the account without the network", r.stdout)
events, rc, err = sign_in("epic", "epic-foreign")
ok(kinds(events) == ["open", "closed"] and chromium_log().get("methods", []).count("Runtime.evaluate") == 1,
   "Epic's JSON on a page of another origin is not a code, and is not read again", str(events) + str(chromium_log().get("methods")))
events, rc, err = sign_in("epic", "epic-error")
ok(kinds(events) == ["open", "closed"] and chromium_log().get("methods", []).count("Runtime.evaluate") == 1,
   "an error answer stops the reading", str(chromium_log().get("methods")))

CASE = "sign-in keyboard and gamepad"
GAME_PROFILE = os.path.join(FAKE, "game_profile")
events, rc, err = sign_in("gog", "typing")
log = chromium_log()
ok([e.get("on") for e in events if e.get("event") == "typing"] == [True, True, False]
   and kinds(events)[:1] == ["open"] and kinds(events)[-1:] == ["closed"] and rc == 0,
   "a text field takes the focus, then another one, then none: typing on, on, off", str(events) + err[-300:])
ok("typing" in log.get("methods", []) and not {"Runtime.enable", "Page.addScriptToEvaluateOnNewDocument",
                                               "Runtime.addBinding"} & set(log.get("methods", [])),
   "the page is asked by evaluation alone: no Runtime domain, no binding, nothing injected", str(log.get("methods")))
ok("--enable-spatial-navigation" in log.get("argv", []), "spatial navigation: the D-pad's arrow keys move between fields")
decl = (log.get("declared") or "").split("\n")
ok(decl[:1] == [os.path.join(PINS, "signin-gamepad.yaml")] and decl[1:2] and decl[1].isdigit()
   and int(decl[1]) != log.get("pid"), "the sign-in's gamepad profile is declared to OGUI while the window is up, as the helper's",
   str(decl))
ok(not os.path.exists(GAME_PROFILE), "and withdrawn after")
# The on-screen keyboard types into the plugin, not into an X11 window (OGUI's X11 path finds no
# InputPlumber keyboard after a fresh boot): the plugin says each edit on the helper's stdin, and the
# helper types it into the focused field over the pipe. Lines before a field has the focus, broken
# lines and unknown ones are dropped.
def type_in(proc):
    proc.stdin.write("not json\n" + json.dumps({"type": "text", "delete": 0, "insert": "early"}) + "\n")
    proc.stdin.flush()
    while True:
        line = proc.stdout.readline()
        if not line or json.loads(line).get("event") == "typing":
            break
    for cmd in ({"type": "text", "delete": 0, "insert": "ab"}, {"type": "text", "delete": 1, "insert": "c\u00e9"},
                {"type": "bogus"}, {"type": "key", "key": "Enter"}):
        proc.stdin.write(json.dumps(cmd) + "\n")
    proc.stdin.flush()
events, rc, err = sign_in("gog", "type", stop=type_in)
typed = [x for x in chromium_log().get("methods", []) if x.startswith("Input.") and " " in x]
key = lambda t, k, code, **kw: "Input.dispatchKeyEvent " + json.dumps(dict(
    {"type": t, "key": k, "code": k, "windowsVirtualKeyCode": code, "nativeVirtualKeyCode": code}, **kw), sort_keys=True)
ok(typed == ['Input.insertText {"text": "ab"}', key("rawKeyDown", "Backspace", 8), key("keyUp", "Backspace", 8),
             'Input.insertText {"text": "c\\u00e9"}', key("rawKeyDown", "Enter", 13), key("char", "Enter", 13, text="\r"),
             key("keyUp", "Enter", 13)],
   "the keyboard's edits are typed into the focused field: text, a backspace per deleted character, Enter",
   str(typed) + err[-300:])
events, rc, err = sign_in("gog", "replace")
ok(os.path.exists(GAME_PROFILE) and open(GAME_PROFILE).read() == "/other/profile.yaml\n1\n",
   "a declaration another launcher made over ours since is not withdrawn by us")
if os.path.exists(GAME_PROFILE):
    os.remove(GAME_PROFILE)
events, rc, err = sign_in("gog", "gog")
ok(not [e for e in events if e.get("event") == "typing"], "no field ever focused: no typing event", str(events))
profile = open(os.path.join(ROOT, "rootfs/overlay/usr/share/retroforge/stores/signin-gamepad.yaml")).read()
rows = {b: re.search(rf"button: {b}\n\s+target_events:\n\s+- (\w+: \w+)", profile) for b in
        ["DPadUp", "DPadDown", "DPadLeft", "DPadRight", "South", "East", "West", "North"]}
ok({b: m.group(1) if m else None for b, m in rows.items()} == {
    "DPadUp": "keyboard: KeyUp", "DPadDown": "keyboard: KeyDown", "DPadLeft": "keyboard: KeyLeft",
    "DPadRight": "keyboard: KeyRight", "South": "keyboard: KeyEnter", "East": "keyboard: KeyEsc",
    "West": "keyboard: KeySpace", "North": "dbus: ui_osk"},
   "the pad: D-pad = arrow keys, A Enter, B Escape, Y Space, X the keyboard", str(rows))
ok(re.search(r"button: Guide\n\s+target_events:\n\s+- layer:\n\s+name: guide\n\s+on_deactivation:\n"
             r"\s+only_when_unused: true\n\s+emit_events:\n\s+- dbus: ui_guide", profile)
   and profile.count("dbus: ui_quick") == 1 and profile.count("dbus: ui_osk") == 2,
   "Guide keeps OGUI's menu, Guide+A its quick bar and Guide+X its keyboard")

CASE = "sign-in ends"
events, rc, err = sign_in("gog", "close")
ok(kinds(events) == ["open", "closed"] and rc == 0, "the player closing the window: no sign-in, exit 0", str(events) + err[-300:])
events, rc, err = sign_in("gog", "hang", stop=lambda p: p.stdin.close())
log = chromium_log()
ok(kinds(events) == ["open", "closed"] and rc == 0 and log.get("methods", [])[-1:] == ["Browser.close"],
   "closing stdin (the plugin's Cancel) closes the window", str(events) + err[-300:])
ok(not os.path.exists(log.get("profile", "/")), "its profile is gone")
events, rc, err = sign_in("gog", "stubborn", stop=lambda p: p.stdin.close())
log = chromium_log()
ok(kinds(events) == ["open", "closed"] and not alive(log.get("pid", 0)) and not alive(log.get("child") or 0),
   "a Chromium that does not close is killed, with what it started", str(log))
events, rc, err = sign_in("gog", "hang", stop=lambda p: p.send_signal(signal.SIGTERM))
log = chromium_log()
ok(kinds(events) == ["open", "closed"] and not alive(log.get("pid", 0)) and not os.path.exists(log.get("profile", "/")),
   "SIGTERM closes the window and deletes the profile first", str(events) + err[-300:])
events, rc, err = sign_in("gog", "stubborn", stop=lambda p: (p.send_signal(signal.SIGTERM), time.sleep(0.3),
                                                                p.send_signal(signal.SIGTERM), p.send_signal(signal.SIGHUP)))
log = chromium_log()
ok(kinds(events) == ["open", "closed"] and not alive(log.get("pid", 0)) and not alive(log.get("child") or 0)
   and not os.path.exists(log.get("profile", "/")), "more signals while it closes do not cut the cleanup short",
   str(events) + err[-300:])
events, rc, err = sign_in("gog", "close", args=("--display", ":7"))
ok(rc == 0 and chromium_log().get("display") == ":7", "--display puts the window on that X display (OGUI's game one)",
   str(chromium_log().get("display")) + err[-200:])
r = store("gog", "sign-in", "--display", "evil:0")
ok(r.returncode == 2 and chromium_log().get("display") == ":7", "a display that is not :N is a bad invocation", r.stderr)
r = store("gog", "sign-in", env={"RETROFORGE_STORE_SCALE": "nan"})
ok(r.returncode == 1 and "not a scale" in r.stderr, "a scale that is not one is refused", r.stderr)
events, rc, err = sign_in("gog", "gog", env={"RETROFORGE_STORE_CHROMIUM": os.path.join(FAKE, "missing")})
ok(rc == 1 and "could not open Chromium" in err and events == [], "a Chromium that cannot start: exit 1", err[-300:])
r = store("gog", "sign-in", unset=["RETROFORGE_STORE_TOOL_GOGDL"])
ok(r.returncode == 3, "the store's tool not set up: exit 3", r.stderr)


CASE = "games gog"
r = store("gog", "games")
games = json.loads(r.stdout or "[]")
ok(r.returncode == 0 and [g["id"] for g in games] == ["1"], "owned Windows games only (no DLC, no Linux-only, no other platform)", r.stdout + r.stderr)
ok(games and games[0]["title"] == "Game One" and games[0]["art"].get("portrait") == "https://images.gog.com/v1_glx_vertical_cover.jpg"
   and "logo" not in games[0]["art"] and games[0]["installed"] is False,
   "title, art sized by GOG's suffixes, no logo (GOG's is the key art), not installed", str(games))
r = store("gog", "games", env={"RETROFORGE_STORE_API": "http://127.0.0.1:9"})
ok(r.returncode == 0 and [g["id"] for g in json.loads(r.stdout or "[]")] == ["1"] and "as last listed" in r.stderr,
   "offline: the library as last listed", r.stderr)

CASE = "games epic"
r = store("epic", "games")
games = {g["id"]: g for g in json.loads(r.stdout or "[]")}
ok(set(games) == {"Fortnite2", "Plain"} and games["Fortnite2"]["art"] == {
   "portrait": "https://cdn.epic/tall.jpg?w=360&resize=1&quality=medium",
   "landscape": "https://cdn.epic/wide.jpg?w=800&resize=1&quality=medium",
   "hero": "https://cdn.epic/wide.jpg?w=1600&resize=1&quality=medium"}, "games and their art, resized by Epic's CDN", r.stdout + r.stderr)
ok("Extras" not in games and "Asset" not in games,
   "a game's digital extras and an item that is not a game are not listed", str(sorted(games)))
r = store("epic", "games", env={"XDG_CONFIG_HOME": os.path.join(T, "nobody")})
ok(r.returncode == 3, "not signed in: exit 3", r.stderr)

CASE = "art"
CACHE = os.path.join(T, "cache")
art_env = {"XDG_CACHE_HOME": CACHE}


def cached(store_name, gid, url):
    return os.path.join(CACHE, "retroforge", "store-art", store_name, gid, "portrait-" + hashlib.sha1(url.encode()).hexdigest()[:12])


store("gog", "games", env=art_env)
store("epic", "games", env=art_env)
r1, r2 = store("gog", "art", env=art_env), store("epic", "art", env=art_env)
gog_cover = cached("gog", "1", "https://images.gog.com/v1_glx_vertical_cover.jpg")
epic_cover = cached("epic", "Fortnite2", "https://cdn.epic/tall.jpg?w=360&resize=1&quality=medium")
ok(r1.returncode == 0 and os.path.isfile(gog_cover) and open(gog_cover, "rb").read() == b"\xff\xd8\xff gog cover",
   "the listed games' covers, where the cards look for them (library_store.gd: <key>-<url sha1>)", r1.stderr)
ok(r2.returncode == 0 and os.path.isfile(epic_cover) and "1 fetched" in r2.stderr, "epic too; a game with no cover is skipped", r2.stderr)
before = len(SEEN)
r = store("gog", "art", env=art_env)
ok(r.returncode == 0 and len(SEEN) == before and r.stderr == "", "a cached cover is not fetched again", r.stderr)
# Epic's CDN names some covers with spaces (GTA V: ".../Portrait Store Banner-1200x1600-....jpg"):
# http.client refuses a request line with a space, so they "failed" on every library load (issue #31).
SPACED = "https://cdn.epic/Portrait Store Banner-1200x1600.jpg?w=360&resize=1&quality=medium"
ROUTES["/cdn.epic/Portrait%20Store%20Banner-1200x1600.jpg?w=360&resize=1&quality=medium"] = b"\xff\xd8\xff spaced"
lib = os.path.join(DATA, "epic-library.json")
listed = json.load(open(lib))
json.dump(listed + [{"id": "Spaced", "title": "Spaced", "art": {"portrait": SPACED}}], open(lib, "w"))
r = store("epic", "art", env=art_env)
spaced = cached("epic", "Spaced", SPACED)
ok(r.returncode == 0 and os.path.isfile(spaced) and open(spaced, "rb").read() == b"\xff\xd8\xff spaced" and "1 fetched" in r.stderr,
   "a cover whose URL has spaces is fetched (percent-encoded), cached under the URL as listed", r.stderr)
json.dump(listed, open(lib, "w"))
ROUTES["/images.gog.com/v1_glx_vertical_cover.jpg"] = None
os.remove(gog_cover)
store("gog", "art", env=art_env)
ok(os.path.isfile(gog_cover + ".missing"), "one the store does not have is marked missing (not asked again for a day)")


# ---- install -------------------------------------------------------------------------------------
def compat_calls():
    try:
        return open(COMPAT_LOG).read().splitlines()
    except FileNotFoundError:
        return []


def percents(out):
    return [int(line[:-1]) for line in out.split() if line.endswith("%")]


CASE = "install epic"
r = store("epic", "install", "Fortnite2")
p = percents(r.stdout)
ok(r.returncode == 0 and p == sorted(p) and p[-1] == 100 and all(x <= 90 for x in p[:-1]), "N% as it goes, 100% once ready", r.stdout + r.stderr)
inst = [c for c in calls() if c[0] == "legendary" and "install" in c]
ok(inst and "--skip-dlcs" in inst[-1] and "--skip-sdl" in inst[-1] and inst[-1][inst[-1].index("--max-shared-memory") + 1] == "512",
   "no DLC, no prompts, 512 MiB of shared memory", str(inst[-1:]))
ok(os.path.isfile(os.path.join(DATA, "umu-database.csv")) and [s[0] for s in SEEN].count(UMU_ROUTE) == 1,
   "the umu-database is cached, for a first launch offline")
r = store("epic", "games")
ok({g["id"]: g["installed"] for g in json.loads(r.stdout)}["Fortnite2"] is True, "installed in the library")
open(COMPAT_LOG, "w").close()
store("epic", "install", "Fortnite4")
ok(compat_calls() == ["install --wait"], "an install brings Proton to its newest release", str(compat_calls()))

CASE = "install, the first one downloads Proton"
COMPAT_SLOW = script("compat-tools-slow", f"""
import time
prog = os.path.join(os.environ["XDG_DATA_HOME"], "retroforge", "steam-compat-tools.progress")
os.makedirs(os.path.dirname(prog), exist_ok=True)
for v in ("40", "unpacking"):
    open(prog, "w").write(v + "\\n")
    time.sleep(1.4)
os.unlink(prog)
print({PROTON!r})
""")
r = store("epic", "install", "Fortnite3", env={"RETROFORGE_STEAM_COMPAT_TOOLS": COMPAT_SLOW})
p = percents(r.stdout)
ok(r.returncode == 0 and p == sorted(p) and p[-1] == 100 and any(85 < x < 99 for x in p),
   "Proton's download moves the bar between the runtime's end (85%) and 99%", r.stdout + r.stderr)
CASE = "install epic"
r = store("epic", "install", "broken")
ok(r.returncode == 1 and "Installation failed" in (r.stderr.splitlines() or [""])[-1], "legendary's logged failure fails the install (it exits 0)", r.stderr)
reset_calls()
r = store("epic", "install", "Crashy", env={"FAKE_INSTALL_CRASH": os.path.join(T, "crashed-once")})
ok(r.returncode == 0 and "trying again (2/3)" in r.stderr and len([c for c in calls() if c[0] == "legendary" and "install" in c]) == 2,
   "an install that crashes once (a network stall) is tried again, and installs", r.stderr)
store("epic", "uninstall", "Crashy")
r = store("epic", "install", "Crashy2", env={"FAKE_INSTALL_CRASH": "always"})
ok(r.returncode == 1 and "Read timed out" in (r.stderr.splitlines() or [""])[-1],
   "one that keeps crashing fails with the traceback's last line, not just an exit status", r.stderr[-300:])
reset_calls()
proc = subprocess.Popen([sys.executable, STORE, "epic", "install", "Slow"], env=dict(BASE_ENV, FAKE_INSTALL_SLOW="1"),
                        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
proc.stdout.readline()  # its first N%: the download is under way
proc.terminate()
out, err = proc.communicate(timeout=60)
ok(proc.returncode != 0 and "trying again" not in err and len([c for c in calls() if c[0] == "legendary" and "install" in c]) == 1,
   "a cancelled install is not tried again", err[-300:])

CASE = "install gog"
r = store("gog", "install", "1")
rec = json.load(open(os.path.join(DATA, "gog-installed.json")))
ok(r.returncode == 0 and percents(r.stdout)[-1] == 100 and rec["1"]["path"].endswith("games/gog/Game One"),
   "installed and recorded (gogdl keeps no record)", r.stdout + r.stderr)
ok(json.loads(store("gog", "games").stdout)[0]["installed"] is True, "installed in the library")

CASE = "runtime"
r = store("gog", "install", "1", unset=["RETROFORGE_STORE_RUNTIME"])
ours = os.path.join(DATA, "runtime", "SteamLinuxRuntime_4-arm64", "_v2-entry-point")
ok(r.returncode == 0 and os.path.isfile(ours) and open(os.path.join(DATA, "runtime", ".version")).read().strip() == "4.0.1",
   "without Steam's, the runtime's channel is downloaded and checked", r.stderr)
steam_rt = os.path.join(HOME, "steam", "steamapps", "common", "SteamLinuxRuntime_4-arm64")
os.makedirs(steam_rt)
open(os.path.join(steam_rt, "_v2-entry-point"), "w").close()
reset_calls()
store("gog", "launch", "1", env={"RETROFORGE_STEAM_ROOT": os.path.join(HOME, "steam")}, unset=["RETROFORGE_STORE_RUNTIME"])
run = game_run(calls())
ok(run and run[1] == os.path.join(steam_rt, "_v2-entry-point"), "Steam's runtime when it has one", str(run))

# ---- launch --------------------------------------------------------------------------------------
CASE = "launch gog"
shutil.rmtree(os.path.join(DATA, "prefixes"), ignore_errors=True)
for f in ("gog-saves.json", "notices-gog"):
    if os.path.exists(os.path.join(DATA, f)):
        os.remove(os.path.join(DATA, f))
reset_calls()
OOMS = os.path.join(FAKE, "oom")
if os.path.exists(OOMS):
    os.remove(OOMS)
CORE = resource.getrlimit(resource.RLIMIT_CORE)
resource.setrlimit(resource.RLIMIT_CORE, (CORE[1], CORE[1]))  # the session's limit up, so 0 is the store's
r = store("gog", "launch", "1", env={"FAKE_GAME_RC": "7"})
resource.setrlimit(resource.RLIMIT_CORE, CORE)
cs = calls()
ooms = [json.loads(line) for line in open(OOMS)] if os.path.exists(OOMS) else []
ok(ooms and all(o[3] == [0, 0] for o in ooms), "the prefix's set-up and the game leave no core file (RLIMIT_CORE 0)", str(ooms))
ok([o[:2] for o in ooms] == [["boot", "900"], ["game", "900"]],
   "the prefix's set-up and the game start at oom_score_adj 900, the OOM killer's first choice", str(ooms))
session = open("/proc/self/oom_score_adj").read().strip()
ok(ooms and all(o[2] == session for o in ooms), "the store keeps the session's, to upload the saves after the game",
   f"session {session}: {ooms}")
order = []
for c in cs:
    if c[0] == "runner":
        order.append("boot" if "wineboot" in c else "game")
    elif c[0] == "gogdl" and "save-sync" in c:
        order.append("sync " + ("down" if "--skip-upload" in c else "up"))
ok(r.returncode == 7, "the game's exit status", r.stderr)
ok(order == ["boot", "sync down", "game", "sync up"], "prefix set up, saves down, the game, saves up", str(order))
boot = next((c for c in cs if c[0] == "runner" and "wineboot" in c), None)
ok(boot and boot[-8].get("UMU_ID") == "umu-default" and boot[-8].get("PROTONFIXES_DISABLE") == "1",
   "the prefix's set-up names an umu id (else Proton's steam.exe asserts on our empty Steam client), no fixes",
   str(boot[-8] if boot else None))
syncs = [c for c in cs if c[0] == "gogdl" and "save-sync" in c]
pfx_saves = os.path.join(DATA, "prefixes", "gog-1", "pfx", "drive_c", "users", "steamuser", "AppData", "Local", "Game One", "Saves")
ok(syncs and syncs[0][syncs[0].index("save-sync") + 1] == pfx_saves, "the save folder inside the prefix", str(syncs[:1]))
run = game_run(cs)
i = run.index("waitforexitandrun")
gamedir = os.path.join(DATA, "games", "gog", "Game One")
ok(run[1:4] == [os.path.join(RUNTIME, "_v2-entry-point"), "--verb=waitforexitandrun", "--"] and run[4] == os.path.join(PROTON, "proton")
   and run[i + 1] == os.path.join(gamedir, "BIN", "game.exe") and run[i + 2:i + 4] == ["-a", "two words"],
   "Proton in the runtime, the primary task's program (case-insensitive) and arguments", str(run))
ok(run[-4:] == [os.path.join(gamedir, "BIN"), os.path.join(DATA, "prefixes", "gog-1"), os.path.join(DATA, "steam-client"),
                f"{PROTON}:{RUNTIME}"], "its folder, prefix, empty client folder, tools", str(run[-4:]))
ok(run[-6:-4] == [gamedir, os.path.join(DATA, "games", "gog")],
   "the install folder is the game's, its library the store's (drive S: has room above the program: GRIP)", str(run[-6:-4]))
ok(json.load(open(os.path.join(DATA, "gog-saves.json"))) == {"1.saves": "1700000000.5"}, "the sync time is kept per location")
ok(run[-7] == "1", "x86 memory ordering (FEX TSO) on by default", str(run[-7:]))
choices = os.path.join(HOME, ".config", "retroforge", "store-games.json")
json.dump({"gog-1": {"tso": "off"}}, open(choices, "w"))
reset_calls()
store("gog", "launch", "1")
ok(game_run(calls())[-7] == "0", "off when the player turned it off for the game", str(game_run(calls())[-7:]))
reset_calls()
store("gog", "launch", "1", env={"ENABLE_MESA_VRAM_REPORT_LIMIT": "1", "VK_VRAM_REPORT_LIMIT_HEAP_SIZE": "512",
                                 "VK_VRAM_REPORT_LIMIT_DEVICE_ID": "0x5143:0x06010000"})
vram = open(os.path.join(os.path.dirname(CALLS), "vram")).read()
ok(game_run(calls()) and sorted(vram.split()) == ["ENABLE_MESA_VRAM_REPORT_LIMIT", "VK_VRAM_REPORT_LIMIT_DEVICE_ID",
                                                  "VK_VRAM_REPORT_LIMIT_HEAP_SIZE"],
   "with the shell's VRAM report limit, as Steam's games (mesa patch 0025)", repr(vram))
valve = os.path.join(HOME, "no-steam", "steamapps", "common", "Proton Experimental (ARM64)")
os.makedirs(valve)
open(os.path.join(valve, "proton"), "w").close()
json.dump({"gog-1": {"proton": "Proton Experimental (ARM64)"}}, open(choices, "w"))
reset_calls()
store("gog", "launch", "1")
run = game_run(calls())
ok(run[4] == os.path.join(valve, "proton") and run[-1] == f"{valve}:{RUNTIME}", "the Proton the player chose for the game", str(run[4:5]))
json.dump({"gog-1": {"proton": "../../etc"}}, open(choices, "w"))
reset_calls()
r = store("gog", "launch", "1")
ok(game_run(calls())[4] == os.path.join(PROTON, "proton") and "no Proton" in r.stderr, "one that is not there: the default", r.stderr)
os.remove(choices)
reset_calls()
store("gog", "launch", "1")
ok(not [c for c in calls() if c[0] == "runner" and "wineboot" in c], "the prefix is set up once")

CCONF = os.path.join(HOME, ".config", "retroforge", "game-core-dumps.conf")  # Settings > General > Game crash dumps
with open(CCONF, "w") as f:
    f.write("GAME_CORE_DUMPS=on\n")
os.remove(OOMS)
reset_calls()
resource.setrlimit(resource.RLIMIT_CORE, (CORE[1], CORE[1]))
store("gog", "launch", "1")
resource.setrlimit(resource.RLIMIT_CORE, CORE)
os.remove(CCONF)
cores = [json.loads(line)[3] for line in open(OOMS)] if os.path.exists(OOMS) else []
ok(cores and all(c == [CORE[1], CORE[1]] for c in cores), "Game crash dumps on: the game keeps the session's core limit", str(cores))

CASE = "launch, Proton as installed"
open(COMPAT_LOG, "w").close()
reset_calls()
store("gog", "launch", "1")
ok(compat_calls() == ["status"] and game_run(calls())[4] == os.path.join(PROTON, "proton"),
   "the installed one: no update check, no download before the game", str(compat_calls()))
open(COMPAT_LOG, "w").close()
reset_calls()
store("gog", "launch", "1", env={"FAKE_NO_PROTON": "1"})
ok(compat_calls() == ["status", "install --wait"] and game_run(calls())[4] == os.path.join(PROTON, "proton"),
   "none installed: installed first", str(compat_calls()))
open(COMPAT_LOG, "w").close()
reset_calls()
store("gog", "launch", "1", env={"RETROFORGE_STEAM_COMPAT_TOOLS": script("compat-tools-old", f"""
print(json.dumps({{"installed": "x"}}) if sys.argv[1:] == ["status"] else {PROTON!r})
""")})
ok(game_run(calls())[4] == os.path.join(PROTON, "proton"), "a status without the folder: install finds it")

CASE = "game settings"
def game(*args, env=None):
    r = store("gog", "game", "1", *args, env=env)
    try:
        return r, json.loads(r.stdout)
    except ValueError:
        return r, None
if os.path.exists(choices):
    os.remove(choices)
r, g = game()
ok(r.returncode == 0 and g and set(g["settings"].values()) == {"default"} and g["apis"] == [] and g["online"] is False,
   "every choice at its default, no graphics API for a game whose engine it does not know, no Online for GOG", r.stdout + r.stderr)
ok(g and g["default_proton_key"] == os.path.basename(PROTON) and g["protons"] == [],
   "the default Proton named; Valve's (no umu-protonfixes) is not one a store game can choose", str(g))
cachy = os.path.join(HOME, "no-steam", "compatibilitytools.d", "cachy-test")
os.makedirs(os.path.join(cachy, "protonfixes"))
os.makedirs(os.path.join(cachy, "files", "lib", "wine", "aarch64-unix"))
open(os.path.join(cachy, "proton"), "w").close()
open(os.path.join(cachy, "compatibilitytool.vdf"), "w").write('"compatibilitytools"\n{\n "compat_tools"\n {\n  "cachy-test"\n  {\n   "display_name" "Cachy Test"\n  }\n }\n}\n')
r, g = game()
ok(g and g["protons"] == [{"key": "cachy-test", "name": "Cachy Test"}], "an arm64 Proton with umu-protonfixes, by its display name", str(g))
r, g = game("set", "proton", "cachy-test")
ok(r.returncode == 0 and json.load(open(choices)) == {"gog-1": {"proton": "cachy-test"}}, "a choice is saved", r.stderr)
r, _ = game("set", "proton", "Proton Experimental (ARM64)")
ok(r.returncode == 2 and json.load(open(choices)) == {"gog-1": {"proton": "cachy-test"}}, "one it does not offer is refused", r.stderr)
for key, value in (("tso", "off"), ("protonfixes", "off"), ("resolution", "1280x720")):
    game("set", key, value)
r, _ = game("set", "online", "on")
ok(r.returncode == 2, "Online is Epic's only", r.stderr)
r, _ = game("set", "resolution", "big")
ok(r.returncode == 2, "a resolution is WxH", r.stderr)
r, _ = game("set", "api", "vulkan")
ok(r.returncode == 2, "no graphics API the game does not offer", r.stderr)
open(os.path.join(gamedir, "UnityPlayer.dll"), "w").close()
r, g = game()
ok(g and g["engine"] == "unity" and g["apis"] == ["d3d11", "vulkan"], "a Unity game: DirectX 11 and Vulkan", str(g))
os.makedirs(os.path.join(gamedir, "D3D12"))
r, g = game("set", "api", "vulkan")
ok(r.returncode == 0 and g["apis"] == ["d3d11", "d3d12", "vulkan"] and g["settings"]["api"] == "vulkan",
   "DirectX 12 with its D3D12 folder; the choice saved", str(g))
ok(g and g["settings"] == {"tso": "off", "proton": "cachy-test", "protonfixes": "off", "online": "default",
                           "resolution": "1280x720", "api": "vulkan", "cpus": "default"}, "every choice as saved", str(g))
reset_calls()
r = store("gog", "launch", "1", unset=["DISPLAY"])
run = game_run(calls())
ok(run and run[run.index("waitforexitandrun") + 2:run.index("waitforexitandrun") + 5] == ["-a", "two words", "-force-vulkan"],
   "the launch adds the API's flag after the game's own arguments", str(run))
ok(run and run[4] == os.path.join(cachy, "proton") and "no DISPLAY" in r.stderr,
   "with the chosen Proton; without a games display to size, the game still starts", r.stderr)
for key in ("tso", "proton", "protonfixes", "resolution", "api"):
    game("set", key, "default")
ok(not os.path.exists(choices) or json.load(open(choices)) == {}, "Default removes each, and the emptied game's entry")
# Run on fast cores (python/fastcores.py), on a fake topology: 4 little cores at 284, 4 big at 1024.
cpu = os.path.join(T, "cpu")
for c in range(8):
    os.makedirs(os.path.join(cpu, f"cpu{c}"), exist_ok=True)
    with open(os.path.join(cpu, f"cpu{c}", "cpu_capacity"), "w") as f:
        f.write("284" if c < 4 else "1024")
with open(os.path.join(cpu, "online"), "w") as f:
    f.write("0-7")
with open(os.path.join(T, "scx"), "w") as f:
    f.write("disabled")
fast_env = {"RETROFORGE_CPU_ROOT": cpu, "RETROFORGE_SCX_STATE": os.path.join(T, "scx")}
r, g = game("set", "cpus", "on")
ok(r.returncode == 0 and g and g["settings"]["cpus"] == "on", "Run on fast cores: On saved", r.stderr)
r, g = game("set", "cpus", "off")
ok(r.returncode != 0, "cpus is on or default, nothing else", r.stderr)
reset_calls()
r = store("gog", "launch", "1", env=fast_env, unset=["DISPLAY"])
run = game_run(calls())
ok(run and run[1:4] == ["uclampset", "-m", "285"] and run[4].endswith("_v2-entry-point"),
   "On: the game starts under uclampset -m 285 (just above the little cores)", str(run))
ok("gog 1: prefers fast cores 4,5,6,7 (uclamp.min 285)" in r.stderr, "and says so", r.stderr)
game("set", "cpus", "default")
reset_calls()
r = store("gog", "launch", "1", env=fast_env, unset=["DISPLAY"])
run = game_run(calls())
ok(run and run[1].endswith("_v2-entry-point"), "Default: started as before, no uclamp", str(run))
shutil.rmtree(cachy)
shutil.rmtree(os.path.join(gamedir, "D3D12"))
os.remove(os.path.join(gamedir, "UnityPlayer.dll"))
r = store("epic", "game", "Fortnite2")
ok(r.returncode == 0 and json.loads(r.stdout)["online"] is True, "an Epic game offers Online", r.stderr)
r = store("gog", "game", "999")
ok(r.returncode == 1, "a game that is not installed has no settings", r.stderr)

CASE = "gog conflict"
store("gog", "launch", "1", env={"FAKE_CONFLICT": "1"})
ok(json.load(open(os.path.join(DATA, "gog-saves.json"))) == {"1.saves": "1700000000.5"}, "a conflict keeps the last sync time")
note = open(os.path.join(DATA, "notices-gog")).read()
ok("changed both here and in GOG's cloud" in note, "and the player is told", note)

CASE = "launch epic"
reset_calls()
r = store("epic", "launch", "Fortnite2")
cs = calls()
run = game_run(cs)
i = run.index("waitforexitandrun") if run else 0
ok(run and run[i + 1:i + 4] == [os.path.join(DATA, "games", "epic", "Fortnite2", "Bin/Game.exe"), "-x", "-AUTH_PASSWORD=xc"],
   "the program with the game's and Epic's parameters", str(run))
syncs = [c for c in cs if c[0] == "legendary" and "sync-saves" in c]
ok(len(syncs) == 2 and "--accept-path" in syncs[0] and "--skip-upload" in syncs[0] and "--skip-download" in syncs[1]
   and syncs[0][-1] == os.path.join(DATA, "prefixes", "epic-Fortnite2"), "saves down (their path from the prefix), then up", str(syncs))
reset_calls()
r = store("epic", "launch", "Fortnite2", env={"FAKE_SYNC_FAIL": "1"})
syncs = [c for c in calls() if c[0] == "legendary" and "sync-saves" in c]
ok(r.returncode == 0 and len(syncs) == 1 and game_run(calls()), "no upload after a failed download, and the game still runs", str(syncs))
ok("cloud copy stays as it was" in open(os.path.join(DATA, "notices-epic")).read(), "the player is told")
reset_calls()
store("epic", "launch", "Fortnite2")
launches = [c for c in calls() if c[0] == "legendary" and "launch" in c]
ok(len(launches) == 1 and "--offline" in launches[0] and game_run(calls()),
   "an Epic game starts offline by default, without Epic's token (DOOM 64 waits forever on an EOS consent it cannot get)",
   str(launches))
json.dump({"epic-Fortnite2": {"online": "on"}}, open(choices, "w"))
reset_calls()
store("epic", "launch", "Fortnite2")
launches = [c for c in calls() if c[0] == "legendary" and "launch" in c]
ok(len(launches) == 1 and "--offline" not in launches[0] and "--skip-version-check" in launches[0],
   "online when the player turned it on for the game", str(launches))
os.remove(choices)

CASE = "protonfixes"
UMU_CACHE = os.path.join(DATA, "umu-database.csv")
DEAD_API = {"RETROFORGE_STORE_API": "http://127.0.0.1:9"}


def fetches():
    return [s[0] for s in SEEN].count(UMU_ROUTE)


def pf_run(name, gid, env=None):
    """(what the game's environment says to protonfixes, the TSO setting, the launch's stderr)."""
    reset_calls()
    r = store(name, "launch", gid, env=env)
    run = game_run(calls())
    return (run[-8], run[-7], r.stderr) if run else (None, None, r.stderr)


def stale():
    if os.path.exists(UMU_CACHE):
        old = time.time() - 2 * 86400
        os.utime(UMU_CACHE, (old, old))


if os.path.exists(UMU_CACHE):
    os.remove(UMU_CACHE)
n = fetches()
pf, _, err = pf_run("gog", "1")
ok(pf == {"UMU_ID": "umu-1001", "STORE": "gog", "PROTONFIXES_DISABLE": None},
   "a GOG game: its umu id by its GOG id (not another store's same id), store gog", str(pf))
ok(fetches() == n + 1 and os.path.isfile(UMU_CACHE) and open(UMU_CACHE, "rb").read() == UMU_CSV and mode(UMU_CACHE) == 0o600,
   "the umu-database is fetched once and cached in the store data folder", str(fetches() - n))
ok("protonfixes umu-1001" in err, "the launch logs it", err)
pf, _, _ = pf_run("epic", "Fortnite2")
ok(pf == {"UMU_ID": "umu-2002", "STORE": "egs", "PROTONFIXES_DISABLE": None} and fetches() == n + 1,
   "an Epic game by its app name (in any case), store egs, from the cache", str(pf))
stale()
ROUTES[UMU_ROUTE] = UMU_CSV.replace(b"umu-1001", b"umu-1002")
pf, _, _ = pf_run("gog", "1")
ok(pf["UMU_ID"] == "umu-1002" and fetches() == n + 2, "a day old, it is fetched again", str(pf))
stale()
ROUTES[UMU_ROUTE] = b"<html>rate limited</html>"
pf, _, err = pf_run("gog", "1")
ok(pf["UMU_ID"] == "umu-1002" and os.path.isfile(UMU_CACHE) and b"umu-1002" in open(UMU_CACHE, "rb").read()
   and "as last fetched" in err,
   "what is not the umu-database does not replace the cached one", err)
ok(os.path.isfile(UMU_CACHE) and time.time() - os.path.getmtime(UMU_CACHE) < 600, "and it is not asked again for a day")
stale()
pf, _, _ = pf_run("gog", "1", env=DEAD_API)
ok(pf["UMU_ID"] == "umu-1002" and os.path.isfile(UMU_CACHE) and time.time() - os.path.getmtime(UMU_CACHE) < 600, "offline: the cached one, not asked again for a day", str(pf))
ROUTES[UMU_ROUTE] = UMU_HEAD.encode()
stale()
pf, _, _ = pf_run("gog", "1")
ok(pf == {"UMU_ID": "umu-default", "STORE": "gog", "PROTONFIXES_DISABLE": None},
   "a game the database does not list is umu-default (the store's defaults), as umu-run names it", str(pf))
if os.path.exists(UMU_CACHE):
    os.remove(UMU_CACHE)
pf, _, err = pf_run("gog", "1", env=DEAD_API)
ok(pf == {"UMU_ID": "umu-default", "STORE": "gog", "PROTONFIXES_DISABLE": None} and "no umu-database" in err,
   "offline without a cached database: umu-default, and the game runs", err)
ROUTES[UMU_ROUTE] = UMU_CSV
n = fetches()
json.dump({"gog-1": {"tso": "off", "protonfixes": "off"}}, open(choices, "w"))
pf, tso, err = pf_run("gog", "1")
ok(pf == {"UMU_ID": "umu-default", "STORE": "gog", "PROTONFIXES_DISABLE": "1"} and tso == "0" and "protonfixes off" in err,
   "off for the game: PROTONFIXES_DISABLE, still an umu id (not Steam's game to Proton), beside its TSO choice", str(pf))
ok(fetches() == n, "and the umu-database is not fetched for it")
pf, _, _ = pf_run("epic", "Fortnite2")
ok(pf["UMU_ID"] == "umu-2002" and fetches() == n + 1, "another game keeps its fixes", str(pf))
os.remove(choices)

CASE = "own fixes"
fixes = json.load(open(OWN_FIXES))
ok(fixes and all(re.fullmatch(r"(gog|epic)-\S+", k) and v.get("why") and v.get("ini") and
                 all({"file", "section", "key", "value"} <= set(i) for i in v["ini"]) for k, v in fixes.items()),
   "game-fixes.json: entries keyed <store>-<id>, each with why and its INI keys", str(list(fixes)))
GRIP = "1342466874"
r = store("gog", "install", GRIP)
ok(r.returncode == 0, "GRIP installs", r.stderr)
grip_local = os.path.join(DATA, "prefixes", f"gog-{GRIP}", "pfx", "drive_c", "users", "steamuser", "AppData", "Local")
ini = os.path.join(grip_local, "GRIP", "Saved", "Config", "WindowsNoEditor", "Engine.ini")


def text_of(path):
    return open(path).read() if os.path.isfile(path) else ""


pf, _, err = pf_run("gog", GRIP, env={"FAKE_WATCH": ini})
ok(pf and pf.get("watch") is True and text_of(ini) == "[HTTP]\nbUseNullHttp=True\n",
   "GRIP: no UE4 HTTP, in its prefix's user Engine.ini, before it starts", str(pf) + err)
ok("RetroForge fix: Engine.ini [HTTP] bUseNullHttp=True" in err and pf["UMU_ID"] == "umu-default" and pf["STORE"] == "gog",
   "logged, and umu-protonfixes runs too", err)
pf, _, err = pf_run("gog", GRIP)
ok(text_of(ini) == "[HTTP]\nbUseNullHttp=True\n" and "RetroForge fix" not in err, "a fix in place is left as it is", err)
saved = "[Core.System]\r\nPaths=../../../Engine/Content\r\n\r\n[HTTP]\r\nHttpTimeout=30\r\nbUseNullHttp=False\r\n\r\n[Audio]\r\nVolume=1\r\n"
os.makedirs(os.path.dirname(ini), exist_ok=True)
open(ini, "wb").write(saved.encode("utf-16"))
pf_run("gog", GRIP)
raw = open(ini, "rb").read() if os.path.isfile(ini) else b""
ok(raw[:2] == b"\xff\xfe" and raw.decode("utf-16") == saved.replace("bUseNullHttp=False", "bUseNullHttp=True"),
   "an Engine.ini as the game saved it (UTF-16, CRLF): the key set in place, the rest as it was", repr(raw[:80]))
for before, after in (("[HTTP]\nHttpTimeout=30\n\n[Audio]\nVolume=1\n", "[HTTP]\nHttpTimeout=30\nbUseNullHttp=True\n\n[Audio]\nVolume=1\n"),
                      ("[Audio]\nVolume=1\n", "[Audio]\nVolume=1\n\n[HTTP]\nbUseNullHttp=True\n")):
    os.makedirs(os.path.dirname(ini), exist_ok=True)
    open(ini, "w").write(before)
    pf_run("gog", GRIP)
    ok(text_of(ini) == after, "added to its section, or the section added: " + before.split("\n")[0], repr(text_of(ini)))
shutil.rmtree(os.path.join(grip_local, "GRIP"), ignore_errors=True)
other_case = os.path.join(grip_local, "Grip", "Saved", "Config", "WindowsNoEditor")
os.makedirs(other_case)
pf_run("gog", GRIP)
ok(os.path.isfile(os.path.join(other_case, "Engine.ini")) and not os.path.exists(os.path.join(grip_local, "GRIP")),
   "into the game's folder as Windows matches it (any case)")
shutil.rmtree(os.path.join(grip_local, "Grip"))
json.dump({f"gog-{GRIP}": {"protonfixes": "off"}}, open(choices, "w"))
pf, _, _ = pf_run("gog", GRIP)
ok(not os.path.exists(os.path.join(grip_local, "GRIP")) and pf["PROTONFIXES_DISABLE"] == "1",
   "off with umu-protonfixes when the player turned them off for the game", str(pf))
os.remove(choices)
ok(not os.path.exists(os.path.join(DATA, "prefixes", "gog-1", "pfx", "drive_c", "users", "steamuser", "AppData", "Local", "GRIP")),
   "a game without an entry gets none")

# ---- uninstall, sign-out -------------------------------------------------------------------------
CASE = "uninstall"
r = store("epic", "uninstall", "Fortnite2")
ok(r.returncode == 0 and {g["id"]: g["installed"] for g in json.loads(store("epic", "games").stdout)}["Fortnite2"] is False, "epic", r.stderr)
r = store("gog", "uninstall", "1")
ok(r.returncode == 0 and not os.path.exists(gamedir) and json.loads(store("gog", "games").stdout)[0]["installed"] is False,
   "gog: the folder and the record go", r.stderr)
CASE = "listing retried"
for name in ("epic", "gog"):
    marker = os.path.join(T, f"failed-once-{name}")
    r = store(name, "games", env={"FAKE_FAIL_ONCE": marker})
    ok(r.returncode == 0 and "trying again (2/3)" in r.stderr and "as last listed" not in r.stderr
       and os.path.exists(marker) and json.loads(r.stdout or "[]"),
       f"{name}: a listing that fails once (a network stall) is tried again, and lists the library", r.stderr)

CASE = "refresh"
# The stored refresh token: GOG or Epic refusing it signs the store out (the Stores row then says
# Sign in) and is exit 3 (the library empties, an install says sign in); not reaching the store to
# use it is offline, and the library is the last one listed.
r = store("gog", "games", env={"FAKE_GOG_REFRESH": "unreached"})
ok(r.returncode == 0 and "as last listed" in r.stderr and json.loads(store("gog", "status").stdout)["signed_in"],
   "gog unreachable: the library as last listed, still signed in", r.stderr)
r = store("epic", "games", env={"FAKE_EPIC_REFRESH": "unreached"})
ok(r.returncode == 0 and "as last listed" in r.stderr and json.loads(store("epic", "status").stdout)["signed_in"],
   "epic unreachable: the library as last listed, still signed in", r.stderr)
r = store("gog", "games", env={"FAKE_GOG_REFRESH": "refused"})
ok(r.returncode == 3 and "sign in again" in r.stderr and r.stdout.strip() == "", "gog refuses the token: exit 3, no library", r.stderr)
ok(json.loads(store("gog", "status").stdout) == {"ready": True, "signed_in": False, "account": ""}
   and not os.path.exists(os.path.join(CONF, "gog-auth.json")), "and it is signed out here too")
r = store("epic", "games", env={"FAKE_EPIC_REFRESH": "refused"})
ok(r.returncode == 3 and "sign in again" in r.stderr and r.stdout.strip() == "", "epic refuses the token: exit 3, no library", r.stderr)
ok(json.loads(store("epic", "status").stdout)["signed_in"] is False, "and it reads signed out (legendary cleared it)")
r = store("epic", "games")
ok(r.returncode == 3, "a signed-out store lists nothing: exit 3", r.stderr)

CASE = "sign-out"
ok(store("gog", "sign-out").returncode == 0 and json.loads(store("gog", "status").stdout)["signed_in"] is False, "gog")
ok(store("epic", "sign-out").returncode == 0 and json.loads(store("epic", "status").stdout)["signed_in"] is False, "epic")
CASE = "usage"
ok(store("steam", "games").returncode == 2 and store("gog", "install").returncode == 2, "a bad invocation is exit 2")

CASE = "concurrent writers"
# OGUI loads a store's library twice at once at startup; both `games` runs write <store>-games.json and
# <store>-library.json. Through one shared <file>.part, the second rename found it gone
# (FileNotFoundError, exit 1), and the plugin dropped every card of that store (issue #32).
WRITER = f"""
import importlib.machinery, importlib.util, sys, time
loader = importlib.machinery.SourceFileLoader("store", {STORE!r})
spec = importlib.util.spec_from_loader("store", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
start = float(sys.argv[2])
while time.time() < start:  # both at once: imported, then writing together
    pass
for i in range(3000):
    m.write_private(sys.argv[1], "x" * 4096)
"""
target = os.path.join(T, "race", "lib.json")
start = str(time.time() + 1.5)
procs = [subprocess.Popen([sys.executable, "-c", WRITER, target, start], env=BASE_ENV, stderr=subprocess.PIPE, text=True)
         for _ in range(2)]
errs = [(p.wait(timeout=60), p.stderr.read()) for p in procs]
ok(all(rc == 0 for rc, _ in errs) and open(target).read() == "x" * 4096
   and not [f for f in os.listdir(os.path.dirname(target)) if f.endswith(".part")],
   "two writers of one file at once both succeed, and leave no .part behind", " / ".join(e[-300:] for _, e in errs))

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
PY
