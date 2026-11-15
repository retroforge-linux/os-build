#!/usr/bin/env bash
# Offline test for the emulator catalog the RetroForge plugin downloads from (plan Phase 4, part 4).
#
#   tests/test-catalog.sh                    # offline: shape and cross-checks against the image
#   RETROFORGE_NET_TEST=1 tests/test-catalog.sh  # also asks GitHub that every pin still matches
#
# WHY THIS EXISTS. The catalog decides which emulator build a player gets, so a bad row is a
# broken game for everyone who downloads after it:
#
#   - a rolling tag (DuckStation's `latest` / `preview`) replaces its asset in place, so a pin on
#     one silently ships an untested build: pins must be numbered releases -- unless the entry has no
#     tested build at all (Cemu, user decision 2026-10-07): then no sha256 (retroforge-emu checks
#     GitHub's own digest), "size" is an estimate, and tag_pattern is ^<that rolling tag>$;
#   - "tag_pattern" (plan emulator-latest) decides which upstream release is the newest and gets
#     installed by default: it must match the tested pin, and never a rolling tag (a build swapped
#     under the same name would read as "already the latest" forever); with RETROFORGE_NET_TEST=1,
#     `retroforge-emu check` must resolve every entry's newest build;
#   - the sha256 is what the plugin checks the download against (and must match GitHub's per-asset
#     digest): a malformed one would make every install fail, or, if skipped, verify nothing;
#   - an emulator the image cannot launch (no /usr/share/retroforge/emulators/<emu>/emulator.json), or one serving a
#     system launch.conf maps elsewhere, would download fine and then never start; an app (no
#     systems) is opened from Apps only, so launch.conf must map nothing to it;
#   - a plain-http URL would let anyone on the path swap the AppImage;
#   - an "unpack" entry (PortMaster, a zip unpacked into the player's home) with a target outside
#     the home, or "self_update" on an AppImage, would be refused by retroforge-emu at every install.
#
# Launch details (format, binary, args, first-run seed) live in the image's emulator.json, NOT here: the
# catalog only says what to download and how to verify it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="${RETROFORGE_CATALOG:-$ROOT/rootfs/overlay/usr/share/retroforge/catalog.json}"
LAUNCH_CONF="$ROOT/rootfs/overlay/etc/retroforge/launch.conf"
EMU_DATA_DIR="$ROOT/rootfs/overlay/usr/share/retroforge/emulators"

for f in "$CATALOG" "$LAUNCH_CONF"; do
  [ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

# The checks are in Python (JSON + regex); each prints "ok|FAIL <TAB> case <TAB> message".
out="$(RETROFORGE_NET_TEST="${RETROFORGE_NET_TEST:-0}" python3 - "$CATALOG" "$LAUNCH_CONF" "$EMU_DATA_DIR" <<'PY'
import json, os, re, sys, urllib.request

catalog_path, launch_conf, emu_conf_dir = sys.argv[1:4]
net = os.environ.get("RETROFORGE_NET_TEST") == "1"

def ok(case, msg):  print(f"ok\t{case}\t{msg}")
def bad(case, msg): print(f"FAIL\t{case}\t{msg}")

case = "catalog file"
try:
    with open(catalog_path) as f:
        cat = json.load(f)
    ok(case, "is valid JSON")
except Exception as e:
    bad(case, f"does not parse: {e}")
    sys.exit(0)

if cat.get("schema") == 1:
    ok(case, "schema 1")
else:
    bad(case, f"schema is {cat.get('schema')!r}, the plugin reads 1")
emus = cat.get("emulators")
if isinstance(emus, dict) and emus:
    ok(case, f"lists {len(emus)} emulator(s)")
else:
    bad(case, "has no 'emulators' object")
    sys.exit(0)

# system -> emulator, last match wins (as in retroforge-launch)
launch = {}
for line in open(launch_conf):
    m = re.match(r"^([a-z0-9_]+)=([a-z0-9_-]+)\s*$", line)
    if m:
        launch[m.group(1)] = m.group(2)

ROLLING = {"latest", "preview", "nightly", "continuous", "dev", "master", "main"}
REQUIRED = {"name", "author", "systems", "github", "tag", "asset", "sha256", "size", "homepage", "licence"}
OPTIONAL = {"data", "unpack", "self_update", "tag_pattern", "cores", "extract"}

def check_github(case, e, rx):
    url = f"https://api.github.com/repos/{e['github']}/releases/tags/{e['tag']}"
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
        tok = os.environ.get("GITHUB_TOKEN")
        if tok:
            req.add_header("Authorization", f"Bearer {tok}")
        rel = json.load(urllib.request.urlopen(req, timeout=20))
    except Exception as err:
        bad(case, f"release {e['tag']} not readable: {err}")
        return
    assets = [a for a in rel.get("assets", []) if rx.fullmatch(a["name"])]
    if len(assets) != 1:
        bad(case, f"asset pattern matches {len(assets)} assets of {e['tag']}, want exactly 1")
        return
    a = assets[0]
    if "sha256" not in e:
        if re.fullmatch(r"sha256:[0-9a-f]{64}", str(a.get("digest"))):
            ok(case, f"GitHub publishes a sha256 digest for {a['name']} (the nightly is checked against it)")
        else:
            bad(case, f"no sha256 digest on {a['name']}: retroforge-emu would refuse every install")
        if isinstance(a.get("size"), int) and e["size"] / 2 <= a["size"] <= e["size"] * 2:
            ok(case, f"size estimate {e['size']} is near today's {a['size']}")
        else:
            bad(case, f"size estimate {e['size']} is far from today's {a.get('size')}")
        return
    if a.get("digest") == f"sha256:{e['sha256']}":
        ok(case, f"sha256 matches GitHub's digest for {a['name']}")
    else:
        bad(case, f"GitHub's digest is {a.get('digest')}, the catalog says sha256:{e['sha256']}")
    if a.get("size") == e["size"]:
        ok(case, "size matches the release asset")
    else:
        bad(case, f"size {e['size']} != asset size {a.get('size')}")
    if str(a.get("browser_download_url", "")).startswith("https://"):
        ok(case, "download URL is https")
    else:
        bad(case, f"download URL {a.get('browser_download_url')!r} is not https")

sys.path.insert(0, os.path.join(emu_conf_dir, "..", "..", "..", "lib", "retroforge", "python"))
import emu_cores

class CoreFail(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)

CORE_CTX = emu_cores.Ctx(Fail=CoreFail, EXIT_USAGE=2, EXIT_NET=3, EXIT_VERIFY=4, EXIT_LOCAL=5,
                         SAFE_TAG=re.compile(r"[A-Za-z0-9._@-]+"))

def check_cores(case, emu, e):
    try:
        cores = emu_cores.specs(CORE_CTX, emu, e)
    except CoreFail as err:
        bad(case, f"cores refused by retroforge-emu: {err}")
        return
    ok(case, f"cores {[c for c, _ in cores]} pass retroforge-emu's checks")
    for core, src in cores:
        if "buildbot" in src:
            ok(case, f"core {core}: libretro buildbot nightly (no tested build)")
            continue
        a = src["asset"]
        if a.startswith("^") and a.endswith("$") and "aarch64" in a and a.endswith(r"\.zip$"):
            ok(case, f"core {core}: asset {a} is an anchored aarch64 zip")
        else:
            bad(case, f"core {core}: asset {a!r} must be ^...aarch64...\\.zip$")
        if "tag_pattern" in src and not re.fullmatch(src["tag_pattern"], src["tag"]):
            bad(case, f"core {core}: tag_pattern {src['tag_pattern']!r} does not match its pin {src['tag']!r}")
        if net and "sha256" in src:
            check_github(f"emulator {emu} core {core} (GitHub)", src, re.compile(a))
    try:
        with open(os.path.join(emu_conf_dir, emu, "emulator.json")) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return  # reported by the emulator.json check
    loaded = set()
    for args in (d.get("system_args") or {}).values():
        for arg in args:
            m = re.search(r"/cores/([a-z0-9_]+)_libretro\.so$", str(arg))
            if m:
                loaded.add(m.group(1))
    names = {c for c, _ in cores}
    if loaded - names:
        bad(case, f"emulator.json loads cores the catalog does not install: {sorted(loaded - names)}")
    if names - loaded:
        bad(case, f"catalog cores no system loads (installed for nothing): {sorted(names - loaded)}")
    if loaded == names:
        ok(case, "every catalog core is loaded by a system, and only those")

for emu, e in emus.items():
    case = f"emulator {emu}"
    if not re.fullmatch(r"[a-z0-9_-]+", emu):
        bad(case, "id is not [a-z0-9_-]+ (it names a folder and a conf)")
        continue
    nightly = "sha256" not in e  # no tested build: follows a rolling release (Cemu)
    required = REQUIRED - {"sha256"} if nightly else REQUIRED
    missing = required - set(e)
    if missing:
        bad(case, f"lacks {sorted(missing)}")
        continue
    ok(case, "has every field")
    extra = set(e) - REQUIRED - OPTIONAL
    if extra:
        bad(case, f"unknown fields {sorted(extra)} (launch settings belong in the image's emulator.json)")
    # Optional data files retroforge-emu fetches after an install (RPCS3's config database): https only,
    # a normalised path under $HOME. retroforge-emu skips a bad entry; the catalog must not carry one.
    data = e.get("data", [])
    good = isinstance(data, list) and all(
        isinstance(d, dict) and set(d) == {"url", "to"} and isinstance(d["url"], str)
        and d["url"].startswith("https://") and isinstance(d["to"], str) and d["to"]
        and not d["to"].startswith("/") and os.path.normpath(d["to"]) == d["to"]
        and ".." not in d["to"].split("/") for d in data)
    if good:
        if data:
            ok(case, f"data files: {[d['to'] for d in data]} (https, under the player's home)")
    else:
        bad(case, f"bad data entries {data!r}: each needs an https url and a relative path, nothing else")

    # Libretro cores (RetroArch, plan retroarch): checked by the shipped emu_cores.specs (what
    # retroforge-emu refuses, this refuses); a GitHub core's asset is an anchored aarch64 zip and its
    # tag_pattern matches its pin; every core is loaded by a system in the image's emulator.json
    # (system_args "-L .../cores/<core>_libretro.so") and every core loaded there is in the catalog.
    if "cores" in e:
        check_cores(case, emu, e)

    # An unpacked archive (PortMaster): a folder under the player's home and the version file in it,
    # both normalised relative paths; self_update only on one (retroforge-emu refuses it otherwise).
    unpack = e.get("unpack")
    rel = lambda p: (isinstance(p, str) and p and not p.startswith("/")
                     and os.path.normpath(p) == p and ".." not in p.split("/"))
    if unpack is not None:
        if isinstance(unpack, dict) and set(unpack) == {"to", "version"} and rel(unpack["to"]) and rel(unpack["version"]):
            ok(case, f"unpacks into ~/{unpack['to']} (version in {unpack['version']})")
        else:
            bad(case, f"bad unpack {unpack!r}: needs exactly 'to' and 'version', relative paths")
    # One file out of a tarball (DSperate): a regex retroforge-emu matches against the archive's member
    # paths; the asset must be a tarball, the definition the binary format, and never with unpack.
    if "extract" in e:
        try:
            rx_ok = isinstance(e["extract"], str) and e["extract"] and re.compile(e["extract"]) is not None
        except re.error:
            rx_ok = False
        fmt = None
        try:
            with open(os.path.join(emu_conf_dir, emu, "emulator.json")) as f:
                fmt = json.load(f).get("format")
        except (OSError, ValueError):
            pass
        if (rx_ok and unpack is None and fmt == "binary"
                and re.search(r"\\\.tar\\\.(gz|xz|bz2)\$$", e["asset"])):
            ok(case, f"keeps the one tarball member matching {e['extract']} (binary format)")
        else:
            bad(case, f"bad extract {e['extract']!r}: a regex, a tarball asset, the binary format, no unpack")
    if "self_update" in e:
        if e["self_update"] is True and unpack is not None and not nightly:
            ok(case, "updates itself after the first install (no update offered)")
        else:
            bad(case, "self_update must be true, on an unpacked archive with a tested pin only")

    if os.path.isfile(os.path.join(emu_conf_dir, emu, "emulator.json")):
        ok(case, f"the image can launch it (/usr/share/retroforge/emulators/{emu}/emulator.json)")
    else:
        bad(case, f"no /usr/share/retroforge/emulators/{emu}/emulator.json: it would download and never start")
    systems = e["systems"]
    if isinstance(systems, list) and systems:
        wrong = [s for s in systems if launch.get(s) != emu]
        if wrong:
            bad(case, f"systems {wrong} are not mapped to {emu} in launch.conf")
        else:
            ok(case, f"systems {systems} map to it in launch.conf")
    elif systems == []:
        # An app: opened from Apps, never by a ROM card.
        mapped = sorted(s for s, m in launch.items() if m == emu)
        if mapped:
            bad(case, f"systems is empty but launch.conf maps {mapped} to it")
        else:
            ok(case, "an app: no system, and launch.conf maps none to it")
    else:
        bad(case, "systems is not a list")

    tag = e["tag"]
    tags = None
    if "tag_pattern" in e:
        try:
            tags = re.compile(e["tag_pattern"])
        except (re.error, TypeError) as err:
            bad(case, f"tag_pattern does not compile: {err}")
    if tags is not None:
        tp = e["tag_pattern"]
        rolling_hits = sorted(t for t in ROLLING if tags.fullmatch(t))
        if not (tp.startswith("^") and tp.endswith("$")):
            bad(case, f"tag_pattern {tp!r} must be ^...$")
        elif not tags.fullmatch(tag):
            bad(case, f"tag_pattern {tp!r} does not match the tested tag {tag!r}")
        elif nightly and tp == f"^{re.escape(tag)}$" and tag in ROLLING:
            ok(case, f"follows the rolling {tag!r} release on purpose (no tested build)")
        elif nightly:
            bad(case, f"no sha256 (no tested build) needs tag_pattern ^<rolling tag>$, not {tp!r}")
        elif rolling_hits:
            bad(case, f"tag_pattern {tp!r} matches the rolling tag(s) {rolling_hits}")
        else:
            ok(case, f"follows upstream's newest release matching {tp}")
    elif nightly:
        bad(case, "no sha256 and no tag_pattern: retroforge-emu has nothing to install")
    if not nightly:
        if tag.lower() in ROLLING or not re.search(r"\d", tag):
            bad(case, f"tag {tag!r} is rolling: its asset can change under the pin")
        else:
            ok(case, f"tested pin is a numbered release ({tag})")
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", e["github"]):
        ok(case, f"source github.com/{e['github']}")
    else:
        bad(case, f"github {e['github']!r} is not owner/repo")
    pattern = e["asset"]
    try:
        rx = re.compile(pattern)
    except re.error as err:
        rx = None
        bad(case, f"asset pattern does not compile: {err}")
    if rx:
        anchored = pattern.startswith("^") and pattern.endswith("$")
        arm = "arm64" in pattern.lower() or "aarch64" in pattern.lower()
        # An unpacked archive carries every architecture's helpers (PortMaster.zip: aarch64, armhf,
        # x86_64) and its tool picks the right one: one asset for all, no arch in the name.
        if anchored and (arm or unpack is not None):
            ok(case, f"asset pattern {pattern} is anchored and {'arm64' if arm else 'multi-arch (unpacked)'}")
        else:
            bad(case, f"asset pattern {pattern!r} must be ^...$ and name arm64/aarch64")
    if nightly:
        if rx and rx.groups >= 1:
            ok(case, "asset pattern captures the build id (installed as nightly-<id>)")
        elif rx:
            bad(case, "a nightly asset pattern needs a capture group for the build id")
    elif re.fullmatch(r"[0-9a-f]{64}", str(e["sha256"])):
        ok(case, "sha256 is 64 lowercase hex")
    else:
        bad(case, f"sha256 {e['sha256']!r} is not 64 lowercase hex")
    if isinstance(e["size"], int) and not isinstance(e["size"], bool) and e["size"] > 0:
        ok(case, "size is a positive byte count (shown before download)")
    else:
        bad(case, f"size {e['size']!r} is not a positive integer")
    lic = e["licence"]
    if isinstance(lic, dict) and lic.get("name") and str(lic.get("url", "")).startswith("https://"):
        ok(case, f"licence attributed ({lic['name']})")
    else:
        bad(case, "licence needs a name and an https:// url (attribution is owed)")
    if isinstance(e["author"], str) and e["author"].strip():
        ok(case, f"author credited ({e['author']})")
    else:
        bad(case, "author needs a name (the Emulators page credits it)")
    if str(e["homepage"]).startswith("https://"):
        ok(case, "homepage is https")
    else:
        bad(case, f"homepage {e['homepage']!r} is not https")

    if net and rx:
        check_github(f"emulator {emu} (GitHub)", e, rx)

# The newest build every entry would install, resolved by retroforge-emu itself (the code that runs on
# the device): a tag_pattern or asset pattern that matches nothing upstream fails here, not on a player.
if net:
    import subprocess, tempfile
    case = "newest (GitHub)"
    tool = os.path.normpath(os.path.join(os.path.dirname(launch_conf), "../../usr/bin/retroforge-emu"))
    with tempfile.TemporaryDirectory() as home:
        env = dict(os.environ, HOME=home, RETROFORGE_CATALOG=catalog_path, RETROFORGE_EMU_DIR=home + "/emulators")
        run = subprocess.run([sys.executable, tool, "check", "--refresh"], env=env, capture_output=True, text=True)
    try:
        answers = json.loads(run.stdout)["emulators"]
    except (ValueError, KeyError) as err:
        answers = {}
        bad(case, f"retroforge-emu check gave no JSON ({err}): {run.stderr.strip()}")
    for emu, a in answers.items():
        if a.get("error") is None and a.get("latest"):
            ok(case, f"{emu}: newest is {a['latest']}")
        else:
            bad(case, f"{emu}: no newest build resolves: {a.get('error')}")
        for core, c in (a.get("cores") or {}).items():
            if isinstance(c, dict) and c.get("error") is None and c.get("latest"):
                ok(case, f"{emu} core {core}: newest is {c['latest']}")
            else:
                bad(case, f"{emu} core {core}: no newest build resolves: {c}")

# Every system the image launches has an emulator in the catalog, or the plugin cannot offer it.
case = "coverage"
served = {s for e in emus.values() if isinstance(e.get("systems"), list) for s in e["systems"]}
for system, emu in launch.items():
    if system in served:
        ok(case, f"system {system} ({emu}) is downloadable")
    else:
        bad(case, f"system {system} maps to {emu} in launch.conf but no catalog entry serves it")
PY
)"
rc=$?
[ $rc -eq 0 ] || { echo "the catalog checker crashed (exit $rc)" >&2; exit 1; }

PASS=0; FAIL=0
while IFS=$'\t' read -r verdict case msg; do
  case $verdict in
    ok)   PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$case" "$msg" ;;
    FAIL) FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$case" "$msg" ;;
  esac
done <<< "$out"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
