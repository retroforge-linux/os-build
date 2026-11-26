# Valve's arm64 Steam client on ARMv8.0 SoCs (SM6115)

**Status (2026-10-10):** the cause is found and the fix is written. Valve's arm64 client ran on the
MANGMI Air X (Cortex-A73/A53) up to its Big Picture sign-in screen, self-updated to the current
build, inside Valve's arm64 Steam Runtime, with the userspace LSE shim. The kernel fix
(`kernel/patches/0025`) is built but has not booted on hardware yet.

## What fails

Client builds since 2026-04-15 target ARMv8.1 with LSE atomics and no fallback
([steam-for-linux#13288](https://github.com/ValveSoftware/steam-for-linux/issues/13288)). A scan of
every arm64 ELF in the client (`llvm-objdump`, manifest version 1788652215) found ~13,700 unguarded
LSE instructions -- 12,909 `ldaddal`, then `ldadd`, `swpal`, `casal`, `swpa`, `ldumaxah`, `casl`, `caspal` and
the rest, every size and ordering -- in steamclient.so, steamui.so, streaming_client, steamwebhelper,
the `steam` binary itself and others. Nothing else beyond ARMv8.0 matters: the `ldapur`/fp16 hits
are OpenSSL constant tables decoded as code, and libcef's dot-product code is runtime-dispatched
(libcef itself has only 51 LSE sites). The first crash on the Air X, reproduced: `vulkandriverquery`
SIGILL at its first atomic; the client's first SIGILL in a worker thread is
`ldaddal x1, x0, [x0]` in `ThreadInterlockedExchangeAdd64` (libtier0_s.so +0x21960).

## The fix

`kernel/patches/0025-arm64-emulate-lse-atomics-on-cpus-without-them.patch`: the EL0
undefined-instruction path emulates LDADD/LDCLR/LDEOR/LDSET/LD{S,U}{MAX,MIN}, SWP, CAS, CASP (and
LDAPR) as LDXR/STXR compare-exchange loops between full barriers, on CPUs without LSE only.
HWCAP_ATOMICS stays clear, so outline-atomics software keeps its native path. It is the general fix
for every ARMv8.0 board, and needs nothing from the client.

Measured with the userspace twin on the Air X (`tools/lse/`): all 55,288 semantic checks and both
contended counters pass; the Steam client emulated ~9,000 atomics/s (4.18 M in an ~8-minute run,
the self-update included), which at 0.86 us each through a signal is under 1% of one core. The
kernel trap costs less than a signal round trip.

## What else running the client needs

Found on the way, independent of the CPU:

1. **A few host libraries, and no runtime container.** `steamui.so` links GTK2
   (`libgtk-x11-2.0`), `steamwebhelper` links `libibus-1.0` and does not load without it, and the
   client maps each localhost connection to a process with `lsof`, rejecting its own UI's
   websocket when it cannot ("Unexpected Transport Error", no UI). The image has all three
   (`rootfs/customize-base.sh`), and `steam` runs `steamrtarm64/steam` raw on the host from
   `steamrtarm64/`, with `steamrtarm64` and `steamrtarm64/video` (the client's own libav* and
   libvpx) first on `LD_LIBRARY_PATH`, as Nova-Deck runs it. Valve's arm64 Steam Runtime
   container (steamrt3c, `<runtime>/run -- steamrtarm64/steam`) runs the client too, but no game
   starts from it: Steam runs every game in Steam Linux Runtime 4.0's own pressure-vessel
   container, and that does not start nested inside another (`bwrap: execvp true: No such file or
   directory`, Hades on the KONKR Pocket FIT, 2026-10-19). (The manifest's
   `runtime_steamrt_linuxarm64` is the x86_64/i386 runtime for FEX games, not either of these.)
2. **`~/.steam/steam` and `~/.steam/root`** pointing at the client root ("Steam data link does
   not exist, client is misconfigured").
3. **A clean environment for pressure-vessel**, which games run in: a `DBUS_SESSION_BUS_ADDRESS`
   from another user (root's, over SSH) makes bwrap fail on `/run/user/0/bus`.
4. **Something to relaunch it after a self-update.** The client exits after installing an
   update ("Update complete, launching Steam...") and expects its wrapper script to start it again.
5. The client zips use backslash paths; extract with the separators converted.

Test install on the Air X: `/home/player/steamtest/` (client, runtime, `lse_shim.so`), started by
`/home/player/steamtest/run-steam.sh`.

## In the image: `/usr/bin/steam`

The OGUI Steam plugin launches games with
`steam -gamepadui -steamos3 -steampal -steamdeck ... steam://rungameid/<appid>`. The image now has
that `steam`, which does the five things above. The client does not ship in the image, because a
root slot is 2 GB and the client updates itself to ~3 GB. It is installed into the
player's home from the shell's store (next section); `steam` itself downloads nothing for a client
that is not there, and says where to install it.

## Installing: Main menu > Emulators

Steam shows in the shell's Emulators screen as one entry, with Download and its progress:

- **Steam Client** (`/usr/lib/retroforge/steam-install install client`): the client's arm64
  binaries (`steam-bootstrap --install`), the x86 guest for FEX (`steam-x86-guest
  fetch`, below), then the client's own update by Valve's updater (`steam -steamdeck -exitsteam`
  through the wrapper, with no display), so its first Open starts at once instead of downloading
  ~650 MB with nothing on screen. If that update does not finish, the install still succeeds and
  the client finishes it on its first Open. The update runs the client under the install
  (`RETROFORGE_STEAM_KEPT=1`), never as the kept unit, whose output would miss the bar; and not at
  all while a Steam client runs (opened during the install), which updates itself: handed to the
  kept client, it was ignored and the install waited an hour at 63% (MANGMI Air X, 2026-11-21).
  Steam's default Proton on ARMv8.0 is then set at the client's next start (a kept client is
  restarted for it, see the ARMv8.0 Proton section). Steam is not started
  during the install: Main menu > Steam stays hidden while its progress file is there (one from
  before this boot does not count, and `steam-install status` removes one a killed install left),
  and `steam` exits 1 with one line while the install holds its lock, except for the install's own
  run of the client. Installed, the entry
  offers Open (Steam's UI: `steam -gamepadui -steamos3 -steampal -steamdeck
  steam://open/bigpicture`) and Repair (the install again, fetching only what is missing). There
  is no Steam library card.

`retroforge-emu` lists it beside the emulators (`kind: steam`, from `steam-install status`) and
hands its install to `steam-install`, whose `N%` lines and exit statuses are its own. The page
reads the percentage from `~/.cache/retroforge/steam-install-steam-client.progress`. The client
updates itself, so it has no Update, Check, Revert or Delete. Before Steam Client is installed,
`steam` exits 1 with one line pointing at it, and nothing is downloaded behind the player's back.

There is no Steam CLI (Valve's steamcmd, for the OGUI Steam plugin's own sign-in): the RetroForge
plugin reads the player's Steam games from the client itself (next section). Earlier builds of this
branch installed Valve's arm64 steamcmd as a second entry; nothing needs it any more.

No version is pinned. `/usr/share/retroforge/steam/steam.pin` names Valve's client CHANNEL, and
the bootstrap installs whatever Valve publishes on it when it downloads, still checked against the
sha256 Valve publishes next to it. A fixed version went stale on its own: the client's package
files are replaced on every release.

- **Client** (`client_channel: steamdeck_stable`): only its arm64 binaries
  (`bins_linuxarm64_linuxarm64`, where `steamrtarm64/` comes from), with the file name and sha256
  from the channel's manifest `steam_client_steamdeck_stable_linuxarm64`. They go into
  `~/.local/share/Steam`, only when missing; the client updates itself from there. The bootstrap
  writes the channel to `package/beta` when it installs the client, and when the file is missing,
  and otherwise leaves it alone. The client owns that file and repoints it to match its launch
  flag. `-steamdeck` keeps either `steamdeck_` line, but a line it does not accept gets repointed,
  which costs a ~631 MB client download on the device. That is why the channel is a `steamdeck_`
  line, and never the gated `-deckard` one (`steam.pin` has the details).
- **No Steam Runtime.** Earlier builds also downloaded Valve's steamrt3c runtime (~52 MB) to
  `~/.local/share/retroforge/steam-runtime/` and ran the client in it; the bootstrap now removes
  that folder when it finds it.

Measured on 2026-10-16: `steam_client_steamdeck_stable_linuxarm64` and Valve's default line
`steam_client_linuxarm64` (which the bootstrap read before) both serve build 1791918634
(`steamdeck_publicbeta`: 1792192922).

Valve's manifest has no arm64 bootstrapper: its one `IsBootstrapperPackage`, `steam_linuxarm64`,
holds the i386 `ubuntu12_32/steam`. That is why the bootstrap starts from the binaries package.

The channel bootstrap against Valve's servers, when it still installed the runtime too, as a
non-root user in a linux/arm64 container on 2026-10-16: on a fresh home it resolved `latest-public-stable` to 3c.0.20260824.257593, checked
the tarball against that snapshot's SHA256SUMS and the client zip against the `steamdeck_stable`
manifest, installed both (runtime 222 MB, client 325 MB) and wrote `package/beta` =
`steamdeck_stable`, in 6 s. The next start, with the channel unchanged, took 160 ms and said
nothing. It left a repointed `package/beta` alone. With Valve unreachable it started with the
installed snapshot and logged one line.

Checked in a linux/arm64 container on 2026-10-15, before the channel pins:
- The bootstrap took 9 s.
- In the runtime's container, `steam` and `steamclient.so` resolve every library.
- The client then updated itself headless: a 667 MB download, ~3 GB on disk, because the
  linuxarm64 manifest also carries the x86 client and runtimes. It stopped at "Unable to open
  X11 display".
- On the second start it verified every executable checksum and found nothing to update.

On hardware (KONKR Pocket FIT, 2026-10-19), running on the host: Steam Client installed from
Emulators, the client signed in and showed Big Picture, and Hades launched from it, under Proton
11.0 (ARM64) in Steam Linux Runtime 4.0 - Arm64, with Turnip's swapchain on gamescope and the
game's window focused. In the steamrt3c container the same launch had ended at once (`bwrap: execvp
true`).

Not yet seen: the 42 restart from a real client, an x86-only Linux game. Nor, here, that
`-steamdeck` keeps `package/beta` on `steamdeck_stable` through a client update: that was measured
upstream, not on this tree.

## Steam games in OGUI's library, without a second sign-in

The OGUI Steam plugin fills the library from a sign-in of its own, through steamcmd, on top of the
client's. The RetroForge plugin lists the player's Steam games from the signed-in client's own files
instead, so signing into Steam Client is enough (`apps/ogui-retroforge-plugin`: `library_steam.gd`,
`steam_apps.gd`; `/usr/lib/retroforge/steam-library` reads the files):

- **Owned games**: the account's licenses, as the client caches them in `appcache/packageinfo.vdf`
  (binary VDF): each package lists its app ids. Package 0 is left out: every account has it, and it
  holds Valve's default free apps (Team Fortress 2, Dota 2, the Spacewar test app). Of those apps,
  the ones the client's app cache types as a game, named from there: no DLC, demos, tools (Proton,
  the Steam Linux Runtimes, FEX), applications or soundtracks. A delisted or shut-down game the
  player owns stays, as in Steam's own library. The app cache is 256 shards,
  `appcache/appinfo/appinfo_00.vdf` ... `appinfo_ff.vdf` (magic `0x0756442A`, each with its own index
  and string table; the Air X's client, 2026-11-26), or the single `appcache/appinfo.vdf` (binary
  VDF, v27-v29) of older clients; with both there, the one written last is read. An app's shard does
  not follow from its id, so each shard's index is read (the Air X's 256 shards, 365 apps: ~11 ms
  for one app there, the owned list of 69 games in 0.26 s with Python's start). Measured on a real
  account (a Mac client's caches, 2026-10-21): 64 packages, 349 apps, 66 owned games, in 0.04 s;
  only the owned and installed apps' entries are parsed, and the list is cached in
  `~/.cache/retroforge/steam-library.json` until the app cache or `packageinfo.vdf` changes.
- **Installed**: one app manifest per installed app, `steamapps/appmanifest_<appid>.acf`, in the
  client's root and every other folder `steamapps/libraryfolders.vdf` names (an SD card), with the
  fully-installed bit (4) in its `StateFlags`. An installed game the licenses do not list (shared by
  family) is listed too. Before the client has signed in once, only the installed games are listed.
- **Launch**: `steam -gamepadui -steamos3 -steampal -steamdeck -silent steam://rungameid/<appid>`,
  as the Steam plugin starts them. OGUI takes the Steam app id from that argument, so gamescope
  focuses the game's window and OGUI's Steam handling (and patches 0017 and 0020) applies.
  `/usr/bin/steam` may then start a game Steam has started here before without the client
  ("Starting games without Steam", below).
- **Install and Uninstall** (OGUI's own buttons on a game). Steam has no command line that installs
  quietly: `steam://install` always opens its dialog, and steamcmd's `app_update` cannot use the
  client's sign-in. So an Install calls Big Picture's own `InstallApp` over the client's DevTools
  port (127.0.0.1:8080; `.cef-enable-remote-debugging` in the Steam folder, which `/usr/bin/steam`
  keeps there), through `/usr/lib/retroforge/steam-install-app`, with Steam kept running (below):
  - First in the background, with nothing of Steam's shown (`steam-install-app --quiet`): Steam's
    web helper is woken for it and frozen again after, and Steam starts the download when it has
    nothing to ask. The player stays in OGUI.
  - Steam asks for a EULA still to accept (`SteamClient.Apps.LoadEula`; Dispatch's), several library
    folders, too little space, a non-default or unmounted folder. Then the background install is
    cancelled before Steam continues it (without Big Picture, Steam's questions are desktop pop-ups a
    gamepad cannot drive), and the Install is handed to Steam's UI, `steam -gamepadui -steamos3
    -steampal -steamdeck steam://install/<appid>`: `/usr/bin/steam` opens Big Picture, makes the same
    call, Steam asks there, and once the player has answered and Steam has queued the download
    (`Update Queued` for the game in `logs/content_log.txt`), Big Picture closes and the player is
    back in OGUI, Steam minimal again.
  - Not asked: Steam's UI counting its hidden desktop window as active, a LAN peer that has the game
    but is off or not sharing (a note: the download comes from Steam's servers), and the Steam Deck
    compatibility warning (the Deck's ratings do not describe this device).

  An Uninstall, and an Install with Steam not kept running, open Steam's own dialog in Big Picture,
  started as Emulators > Steam Client > Open starts it. The game's app manifest gives the download's
  end (fully installed, nothing still going) and its progress, `BytesDownloaded` of
  `BytesToDownload`, which Steam writes only when the download starts and ends; in between, the
  progress is what the client has written since the install began (`write_bytes` of its
  `/proc/<pid>/io`) of the manifest's `BytesToStage`, held below 100% until the manifest says
  installed. Steam downloads while its client runs: the install's card follows the download while
  the client runs (`~/.steam/steam.pid` names a live `steam`), and ends as failed when the client is
  gone first; Steam carries on with it at its next start. Steam updates installed games itself.
- **Art**: what the client cached for its own library, `appcache/librarycache/<appid>/`
  (`library_600x900.jpg` for cards, `header.jpg`, `library_hero.jpg`, `logo.png`), else the same file
  from Valve's CDN (`steamcdn-a.akamaihd.net/steam/apps/<appid>/`, what the Steam plugin fetches),
  kept in `~/.cache/retroforge/steam-art/`. Art the CDN does not have is not asked for again for a
  day.
- **Refresh**: the plugin polls the manifests and the two caches every 5 s, as it polls `~/roms`,
  and reloads the list once a change has settled, never while a game runs. Steam's own UI counts as
  one, so a game installed, uninstalled or bought shows once Steam's UI is left.
- The games get a Steam tab beside the systems' tabs, and show in OGUI's Installed and All Games.

With the OGUI Steam plugin installed too, OGUI shows a game both list as one card with two launch
items; the plugin is not needed, and its steamcmd (x86, downloaded by the plugin) cannot run here.

## Keeping Steam running in the background (Settings > Steam, on by default)

Without it, a game started from OGUI starts Steam first, and OGUI stops Steam when the game ends.
Measured on the KONKR Pocket FIT (Hades, Proton 11 ARM64, 2026-10-21): the launch at 44.5 s of uptime,
Steam ready at ~62.5 s (its cold start, ~18 s), Proton at 70.6 s (Steam's own preparation), the game's
processes at 85.6 s, its first frame at 95 s. So ~30 s from the press to the game, more than half of it
Steam's.

Settings > Steam > "Steam: keep running in the background" (`retroforge-steam-keep`, `KEEP_RUNNING=` in
`~/.config/retroforge/steam.conf`, on unless the player turned it off) leaves Steam running instead,
minimal while nothing needs its UI (below). `/usr/bin/steam` then:

- starts the client, the first time, as the user unit `retroforge-steam.service` (`systemd-run
  --user`, with the launch's environment and arguments), outside OGUI's process tree: OGUI's "stop
  Steam" when a game's windows are gone (`RunningApp.find_steam`) only looks inside that tree, and
  its reaper only kills what is under it;
- hands every later launch to that client: a second client process passes its arguments over
  Steam's pipe and exits, as `steam steam://...` always did with a client running;
- for a game, stays as OGUI's launch for exactly as long as Steam's own launch of it runs. Steam
  runs a game under `<Steam>/.../reaper SteamLaunch AppId=<appid>`, which exits with the game's last
  process, but a launch can take two: the game's install scripts run under one first (on every
  launch, ~5 s for Hades), and the game under another once they are done. Ending OGUI's launch with
  the first sent OGUI back to its menu a second before the game came up (Pocket FIT, 2026-10-22). So
  the launch's steps come from Steam's own log, `<Steam>/logs/console_log.txt` (`GameAction [AppID
  <appid>, ActionID <n>] : LaunchApp changed task to <step>`): once it reaches `Completed` (the
  game's process is created), the launch lasts while the game's reaper runs. `Failed` ends it, unless
  the game already runs (`AppError_16`, the game started again from OGUI): then it follows that one.
  OGUI then returns to its menu as it does for any app. OGUI finds the game's windows by their app
  id, which gamescope reads from that same reaper, and Steam's own windows for the launch
  ("Launching...", an error) by the same id, which Steam gives them. `OGUI_ID` (how OGUI ties
  processes to its launches) is `Steam` for the kept client and everything it starts;
- on OGUI's Exit (a TERM), ends the game (that reaper and everything under it: TERM, then KILL 5 s
  later), not Steam;
- for Steam's own UI (Emulators > Steam Client, an install from the library: launches named "Steam",
  whose `OGUI_ID` matches the kept client's, so OGUI finds and focuses its windows), stays until OGUI
  stops it or Steam exits.

Turning it off stops a kept Steam that runs no game; one that does stops when that game ends. Without
the user's systemd (`systemd-run` fails), Steam runs with the launch as when it is off. A launch Steam
has not picked up within 300 s ends with "Steam did not start app <id>", and Main menu > Emulators >
Steam Client shows why. Measured warm, on the Pocket FIT (Hades, 2026-10-22): ~12 s from the press to
the game's window (Steam's install scripts 5 s, its process at 7 s), against ~30 s cold.

Steam's windows belong to no OGUI launch between games, and OGUI checks for such orphan windows every
second: its patch 0022 warns about them once per change, not on every check (two journal lines a
second, idle, before it). Not covered while it is on: what `/usr/bin/steam` sets when the client starts
(the x86 guest after its first download, an OGUI per-game environment) reaches games from
Steam's next start: turn the setting off and on, or restart.

**Minimal in the background** (`retroforge-steam-keep minimal|full`). Idle and signed in, the client
held ~1.2 GB of RAM and swap on the MANGMI Air X (`-steamdeck -silent -nofriendsui`, 2026-10-24): the
client itself 135-170 MB (PSS) plus ~25 MB of swap, its web helper (Chromium, 8 processes: Steam's
UI) 710-1100 MB plus up to 300 MB of swap and its GPU buffers. Capping or paging out the helper is not
enough: the paused helper kept 252 MB of GPU buffers, which cannot be swapped, and earlyoom killed
Hades with it (2026-10-24, 07:01). Killing it does not last: the client starts it again at once (14
times in 2 minutes). So `minimal` kills it and freezes (SIGSTOP) the one the client starts next, 0.3 s
later at ~7 MB, and anything it has started. The client waits for it indefinitely (6 minutes seen)
without starting another, stays signed in, and costs ~240 MB in all while idle; under a game's memory
pressure the kernel moves most of that into zram, and at Hades's peak it cost ~75 MB (the table
below). `full` brings Steam's UI back: it kills the frozen helper (SIGKILL) and the client starts a
working one at once, its UI up ~4 s later. It is not let go on (SIGCONT): minimal killed what it had
started, so a thawed helper failed to launch its GPU process 9 times, exited FATAL ("GPU process
isn't usable"), and the client waited out systemd-coredump writing that crash (16 s) before it started
the next: Steam's UI 36 s after the open (Air X, 2026-11-23). The restarted helper has to be caught
early: with its files cached (after Steam's UI has run) it is past 100 MB within a fraction of a
second. `minimal` looks for it every 50 ms, through the kernel's list of the client's children, with
shell builtins only: a `cat` per thread of the client (60) made each look ~0.2 s, and the helper was
frozen at 170-230 MB, ~110 MB of it anonymous and shared memory, instead of 2-4 MB (Air X, 2026-11-23,
three times each; Steam's UI still came back whole from it). The launches that need the UI hold it (`full $$`,
a file per launch in `$XDG_RUNTIME_DIR/retroforge-steam-full/`): Steam's own UI until OGUI closes it,
and a game the client starts (Steam's launch dialogs, install scripts and shader prompt need the UI)
until Steam has switched the controller to it (`OnFocusWindowChanged to game window type` in its
`controller_ui.txt`) and 5 s more (`RETROFORGE_STEAM_MINIMAL_DELAY`). Frozen before that, Steam never
switched it, and the game had no controls (2026-10-25). Steam's own UI opened from a minimal client
(Main menu > Emulators > Steam Client) is handed over once the new helper has created the UI's main
window (`SP BPM_uid0: STARTUP BrowserCreated`, or `SP Desktop`, in `webhelper.txt`) and 2 s more:
sent at once, `steam://open/bigpicture` was lost, Steam's window stayed unmapped and OGUI on its
loading screen (2026-10-25). It waited for `SlowJSMethodCall` in `console_log.txt` until the client
stopped writing that (2026-11-22), and every open then waited out the 30 s. So Steam's UI takes ~10 s
from a minimal client (Air X, page cache dropped, 2026-11-23), against ~37 s before. Closed from OGUI, Steam's UI
first leaves Big Picture (`steam://close/bigpicture`, back to the hidden desktop window a client
started `-silent` has), then goes minimal: a client keeps Big Picture open while its helper is killed,
and the next game launch's helper showed it again with the game's id on it, which OGUI took for the
game's window and kept in front; the game ran hidden behind it, and Steam, never seeing the game
focused, kept its UI full (2026-11-23). A game started without the client (below) gets the kept
client beside it, minimal; the client logs it with an empty command, which is not a launch to replay.

A game's Steam API works with the minimal client, whoever started the game. Hades's first room, then
quit from its menu, same launch option (Air X, MemTotal 3621 MiB, 2026-10-25):

| mode | RAM+swap in use, peak | swap free, least | Steam features |
|---|---|---|---|
| without the client, alone | 5735 MiB | 1428 MiB | none (`SteamAPI failed to initialize!`) |
| without the client, the minimal client beside it | 5810 MiB | 1311 MiB | all but the Cloud download before play |
| the client starts it, minimal 15 s in | 6274 MiB | 833 MiB | all |

Beside a game started without it, the client logs `PID ... was launched outside Steam, using container
PID ... as root`, Hades logs `Steam initialized`, playtime counts, Steam Input follows its window
(`OnFocusWindowChanged to game window type: AppID 1145360`), and when it ends Steam uploads its new and
changed saves (Auto-Cloud: `No launch record found. Skipping looking for files added/removed while the
game was running`, then `Upload OK`). A Steamworks probe as app 480 (Spacewar) showed the Cloud API
(`ISteamRemoteStorage::FileWrite`, uploaded when it let go) and achievements (`SetAchievement` +
`StoreStats`, stored) work the same way. What only Steam's own launch does is the Cloud download before
the game (`Starting sync (AC Launch,down,)`): saves changed on another device in between meet Steam's
cloud-conflict check when the game ends. A game the minimal client launches itself (an x86 game,
through FEX) gets both: Megabonk on the Air X (2026-11-23) logged `Starting sync (AC Launch,down,)`
and `Download complete` before each launch, and after a run that changed its stats, `Need to upload
file .../stats.json`, `Upload OK`, `Upload complete, result OK`. When the client launches the game,
its web helper peaks at ~2 GB during Steam's launch steps, and what it pushed into swap stays there for
the game.

`systemctl --user status retroforge-steam` and `journalctl --user -u retroforge-steam` (as the
player) show a kept client; the launches log to OGUI's journal as before.

**Started after boot (2026-11-23).** The first Steam game after a boot started the client first:
Megabonk's window 57 s after its launch, against 44 s with Steam already kept (Air X, page cache
warm). So `retroforge-session` runs `steam -gamepadui -steamos3 -steampal -steamdeck -silent` with
`RETROFORGE_STEAM_PRESTART=1` on the games' Xwayland, `RETROFORGE_STEAM_PRESTART_DELAY` s (30) after
the shell starts (`off`: not at all), unless the shell has ended by then. In that mode `/usr/bin/steam`
starts the kept client as a launch would, waits for its sign-in and leaves it minimal (the same steps
as beside a game started without it), and only with "Keep Steam running" on, a remembered sign-in,
and no kept client running yet: a game or Steam's UI opened first is left alone. Without Steam Client
installed, or while its install runs, it stops at the bootstrap and downloads nothing. On the Air X
the client was kept and minimal 47 s after a session start (17 s of it Steam's own), and the first
launch's window came at 46 s.

## Starting games without Steam (Settings > Steam, on by default)

**Why.** On the MANGMI Air X (SM6115, 3.5 GB, zram 3.5 GB) earlyoom killed Hades (Proton 11.0
ARM64, Vulkan, 1280x720) every time it loaded, last as it entered its first room. It never crashed
by itself. With the client running, RAM plus swap in use reached 6.95-6.98 of 7.13 GB and swap ran
out. Hades held ~2.4 GB (RAM, swap and ~1 GB of GPU buffers that cannot be swapped), and the client
and its web helper held 1.0-1.2 GB beside it (up to 2.1 GB while Steam started the game). The same
launch without the client (2026-10-22, `hades-memlog` every 2 s):

| run | RAM+swap in use, peak | swap free, least | Steam client | outcome |
|---|---|---|---|---|
| with Steam, 09:18 | 6978 MiB | 0 | 1030 MiB | killed while loading |
| with Steam, 09:50 | 6954 MiB | 0 | 1200 MiB | killed |
| with Steam, 10:05 | 6982 MiB | 29 MiB | 1039 MiB | killed entering the first room |
| without the client, 15:32 | 5494 MiB | 1515 MiB | none | menu, first room, played, quit |

So ~1.5 GB of RAM and swap is freed, and swap no longer runs out. RAM itself stays tight (the GPU
buffers and ~0.9 GB of compressed zram). Hades's own log shows it carry on without Steam:
`Initializing steam`, then `SteamAPI failed to initialize!` and `Steam not initialized`, then
the main menu ~35 s after the press, and `RoomOpening` loaded. Its window came up 24 s after the
press. With Steam, the install-script step alone took 19 s of the launch on this device.

**How** (`/usr/bin/retroforge-steam-direct`, asked by `/usr/bin/steam` at every game launch). A game
Steam has started on this device before is started the way Steam started it, without the client.
Steam logs every launch in `<Steam>/logs/console_log.txt`:

```
[2026-10-22 10:07:35] Game process added : AppID 1145360 "<Steam>/linuxarm64/steam-launch-wrapper --oom-score-adjust 900 -- <Steam>/steamrtarm64/reaper SteamLaunch AppId=1145360 -- '<SteamLinuxRuntime_4-arm64>'/_v2-entry-point --verb=waitforexitandrun -- '<Proton 11.0 (ARM64)>'/proton waitforexitandrun  '<Hades>/x64Vk/Hades.exe' /c=..\\ /steampowered ...", ProcID 8664, IP 0.0.0.0:0
```

and ran that command with `/bin/sh -c`. The helper runs it the same way, so these stay Steam's:
- the launch option Steam chose (Hades has 18 of them, for betas and the Steam Deck);
- the player's own launch options;
- the compat tool and the runtime it needs.

Steam's own `steam-launch-wrapper` and `reaper` stay too, so gamescope gives the game's windows its
app id and OGUI's Steam handling (patch 0017) works as with the client.

- **Where it is kept.** A game's newest such line is its last one in `console_log.previous.txt`,
  then `console_log.txt`: chosen by place in the log, not by its stamp, which a handheld's unset
  clock can get wrong. It is kept in `~/.cache/retroforge/steam-direct/<appid>.json` when read, and
  `/usr/bin/steam` keeps every game's (`retroforge-steam-direct remember`) before each start of the
  client, so a log the client rotates away does not lose one. Install scripts are logged otherwise
  (`Running install script evaluator for AppID ...`), so the line is the game's own.
- **Environment.** The variables Steam gives a game (`steamclient.so` names them), added to the
  launch's own: `SteamAppId`, `SteamGameId`, `SteamOverlayGameId` and `STEAM_COMPAT_APP_ID`;
  `STEAM_COMPAT_CLIENT_INSTALL_PATH`; `STEAM_COMPAT_DATA_PATH` (the prefix, in the game's
  library); `STEAM_COMPAT_INSTALL_PATH`; `STEAM_COMPAT_SHADER_PATH`; `STEAM_COMPAT_LIBRARY_PATHS`
  (every library); `STEAM_COMPAT_TOOL_PATHS` (the command's compat tools, Proton first);
  `SteamDeck=1` (the client runs with `-steamdeck`).
- **Valve's per-game Proton setting.** `STEAM_COMPAT_CONFIG` comes from `app_compat_configs` of
  app 891390, "SteamPlay 2.0 Manifests", in the client's app cache. Hades has none.
- **Working folder.** The working folder of the app cache's launch entry that runs that
  executable (Hades: `x64Vk\`), else the executable's own folder.
- **Before it runs.** `/usr/bin/steam` still does the D-Bus check, then execs the
  helper. It skips the kept client and the x86 guest. `check` has already checked everything `run`
  needs, because once `/usr/bin/steam` has exec'd `run` nothing can fall back to Steam. So `run`
  does not ask again about the setting or a client. SIGPIPE and SIGXFSZ go back to their defaults
  before the exec: Python ignores them, and an ignored signal stays ignored in everything it execs.

**Left to the client.** For these, `retroforge-steam-direct check` says why in OGUI's journal, and
`/usr/bin/steam` starts Steam as before:
- the setting is off (nothing is said);
- a client already runs (`~/.steam/steam.pid` names a live `steam`; the client leaves a stale one
  behind when OGUI stops it), other than the kept one in the background (its cgroup is
  `retroforge-steam.service`). That client, Steam's UI opened from OGUI, gets the game;
- Steam has not started the game on this device yet. Its first launch goes through Steam, which
  also runs the game's install scripts (DirectX, VC++ redistributables) and sets up its prefix;
- the game is not fully installed, or its StateFlags have any bit other than fully installed (4),
  update queued (2) and a run Steam did not see end (64): an update, a download, a validation, files
  missing. An update Steam has only queued does not stop a launch: the game runs its installed
  version until Steam runs (Main menu > Emulators > Steam Client) and updates it;
- an x86 game or an x86 Proton: Steam runs those through its FEX tool (app 3127680) and an x86
  Steam Linux Runtime, with settings only the client makes;
- the logged command names no compat tool, or no file of the game;
- a path in it is in a folder that is gone (the compat tool was changed or uninstalled), or Steam's
  launch wrapper or reaper is gone. A file not written yet, in a folder that exists (a log the game
  is told to write), is fine. Paths are compared resolved, so a library named through a link works.

A launch option or compat tool the player changes in Steam reaches a game started this way only
once Steam has started it again. Open Main menu > Emulators > Steam Client and start the game from
there once.

**The kept client beside it.** With Steam kept running in the background (on by default),
`/usr/bin/steam` makes sure the kept client runs beside the game, minimal, before it starts the game.
When it has to start it (the first launch after boot), with the launch's arguments but the game's URI,
it waits for it to sign in (`Logged On ... processing complete` in Steam's `connection_log.txt`, ~20 s;
45 s at most, `RETROFORGE_STEAM_SIGNIN_WAIT`), since a game's `SteamAPI_Init` does not wait. Not when
Steam has no remembered sign-in (`"RememberPassword" "1"` in `loginusers.vdf`). The game's Steam API
then works ("Minimal in the background" above).

**What goes without the client** (the setting's description says what):
- **The Cloud download before the game**, which only Steam's own launch makes. Saves changed on
  another device in between meet Steam's cloud-conflict check when the game ends. Without the kept
  client, the upload goes too: saves stay on the device until Steam next syncs the game.
- **The overlay.**
- **Without the kept client:** achievements, playtime and Steam Input too (the game reads the
  gamepad itself: InputPlumber's virtual pad), and games that require Steam (Steam DRM (SteamStub), an
  online license check, a game that quits when `SteamAPI_Init` fails) close right after they start.
- **The install scripts** Steam runs before each launch (Hades: 19 s on the Air X), the Steam Linux
  Runtime's own update, and anything Steam would update before a launch.

**The setting.** `DIRECT_LAUNCH=on|off` in `~/.config/retroforge/steam.conf`, beside `KEEP_RUNNING`. The player changes it in Settings > Steam > "Steam: start games without Steam"
(`steam_direct.gd`), or with `retroforge-steam-direct on|off|status` over SSH. Never set, it is on, on
every board: with the kept client beside the game, Steam's full client comes up only when the player
opens Steam (2026-10-25; it was on only for the SM6115 and the 4 GB boards before).
`RETROFORGE_STEAM_DIRECT=on|off` overrides it, for testing. A launch item stays `steam ... steam://rungameid/<appid>`, so the setting applies from the
next launch without a library rescan. Keeping Steam running applies to all of them: a game started
without the client gets the kept client beside it, and first launches and Steam's own UI go to it.

**Per game** (Game settings > RetroForge, `game_settings_page.gd`): a Steam game's FEX TSO (on or off),
launch option and resolution, and an x86 game's graphics driver ("The device's own driver", below:
set before every launch, through the client too). (Its own Proton, ARMv8.0 stable or experimental, went with the Valve-based
ARMv8.0 builds on 2026-11-01: there is one ARMv8.0 Proton, and Steam's Properties > Compatibility picks
any other.) `retroforge-steam-direct game APPID [set KEY VALUE]` keeps them in
`~/.config/retroforge/steam-games.json`. A launch without the client applies them to Steam's logged
command: the tool when it runs on the same runtime; the launch option's executable, its arguments and
its working folder, the arguments in place of those of the entry Steam ran (the player's own launch
options after them stay); `STEAM_FEX_TSOENABLED`, which Proton writes into the
game's `proton-fex-config.json` (its default, `files/share/fex-emu/Config.json`, is on; the arm64 client sets no
FEX settings itself): the player's choice, else Valve's appinfo hint
`common/steam_frame_compatibility/configuration/tso_enable`, as Valve's client sets it on the Steam
Frame, else nothing (shown beside the row; Hades, hint off, Air X 2026-11-24: its menu 181-185% of a
core against 188-189% with TSO on, the same 59-60 frames a second). An x86 game, which never starts
without the client, gets the same choice through its FEX app config (`TSOEnabled`, below); a Proton
game the client starts gets it through `compatdata/<appid>/user_settings.py`, which `/usr/bin/steam`
has `retroforge-steam-direct fex` write before such a launch and which our Proton-CachyOS reads before
it writes the game's FEX config (Valve's Proton 11 reads only its own `user_settings.py`); the
resolution (below). The launch options are the ones
Steam's dialog offers on a Steam Deck, as the client runs with `-steamdeck`: Windows, 64-bit, not
`type none`, not another branch's (`BetaKey`), not `steamdeck 0`. Hades offers two, DirectX and
"Vulkan - Steam Deck". A launch through the client does not use them.

**Resolution.** The client gives a game's X server the game's Game resolution (Properties > General;
`ResolutionOverride2 "800x450"` in `userdata/<account>/config/localconfig.vdf`) through gamescope before
it starts it: `GAMESCOPE_XWAYLAND_MODE_CONTROL` on the server's root, `[server id, width, height, 0]`,
the id from its `GAMESCOPE_XWAYLAND_SERVER_ID`. A launch without the client does the same, with the size
chosen in Game settings over Steam's. It leaves a watcher outside the game's process tree
(`systemd-run --user`, `restore-resolution`) that gives the server its old size back when the launch
ends: the one Settings > Display > Game resolution gives every game (`display_settings.gd`; its
Default is the board's `RETROFORGE_GAMESCOPE_NESTED_W/H`, 1280x720 on the Air X), so the next game or
emulator gets that again. Game settings offers the same sizes (Native, 900p, 720p, 540p, 480p at the
panel's aspect) and keeps the one chosen as `WxH`.

**umu-launcher** was the other way to do this. Upstream (2026-08) supports aarch64: it maps Proton's
`require_tool_appid` 4185400 to `steamrt4-arm64`. But it downloads its own copy of that runtime from
repo.steampowered.com into `~/.local/share/umu`, instead of the one Steam installed. It checks for a
newer one at each online launch. It needs a Python stack the image does not ship (python-xlib,
urllib3, vdf, filelock). And it leaves choosing the executable and its launch option to the caller.
Replaying Steam's own launch needs none of that.

**Not yet seen on hardware:** a game on an SD card library, a game with a `STEAM_COMPAT_CONFIG`,
Proton-CachyOS with DXVK-Sarek started this way, and a game that requires Steam (expected to close).

## x86 games: the FEX guest

Valve's arm64 client runs x86 games, and x86 Protons, through its FEX tool (Steam app 3127680,
which Steam downloads itself). That tool needs an x86_64 + i386 **graphics provider**: a tree with
`ld.so`, glibc and x86 Mesa (Turnip), with `graphics_provider.json` at its root. SteamOS ships one
at `/usr/share/guestos/fex-mesa` (Valve's `deckard-mesa-linux-x86_64`). We can't: a root slot is
2 GB, and `rootfs/guard-rootfs.sh` section 9 keeps `usr/share/guestos` and FEX out of the image. The
tool also honours `STEAM_COMPAT_GRAPHICS_PROVIDER=/abs/path/graphics_provider.json`, and the
parent directory then becomes both pressure-vessel's graphics provider and FEX's RootFS. Symlinks
from that tree into another one reportedly do not work, so it has to be a real tree.

**The guest:** FEX's own ArchLinux RootFS. `/usr/share/retroforge/steam/x86-guest.pin` pins a
**channel**, not a version: FEX's `https://rootfs.fex-emu.gg/RootFS_links.json` (the file
`FEXRootFSFetcher` reads) and the entry with `DistroMatch: arch` and `Type: squashfs`, "ArchLinux
(SquashFS)". FEX lists one entry per rolling distro and type, its newest, so the device takes
whatever FEX publishes there now. Two matching entries are refused rather than guessed between.

**Our Mesa over it.** FEX's RootFS carries upstream Arch Mesa. The image carries our own, built for
x86_64 and i686 from `packages/mesa`'s pin and patches by `packages/mesa-x86` (Turnip, freedreno, the
GL front ends, the VRAM layer; `make mesa-x86`, in an x86_64 Arch container locked to the guest's
Arch snapshot), at `/usr/lib/retroforge/x86-mesa/root`, with `payload.conf` naming that snapshot.
It is the image's one x86 payload and nothing on the host runs it. `steam-x86-guest` lays the
payload over the guest on `fex-guest/root`, read-only (lower layers only): with the kernel's overlayfs
when root mounts the guest (**The mount**, below), else with `fuse-overlayfs` over a squashfuse mount
on `fex-guest/base`. Our files replace the guest's at the same paths, everything else is the guest's,
and `graphics_provider.json` is still the guest's. A guest older than the payload's
snapshot (it could lack the glibc the payload links against) is mounted as it is, and so is any
guest on an image built with `RETROFORGE_X86_MESA=0`.

Each entry has a `URL` (a dated directory, `.../ArchLinux/2026-08-11/ArchLinux.sqsh`) and a `Hash`.
That hash is FEX's XXH3-64 (`XXH3_64bits`, seed 0), in hex without leading zeros, not a sha256. The
image checks it with `xxhsum -H3`, from the `xxhash` package (`rsync` already pulls it in; it is in
`PKGS` so the check does not depend on that). XXH3 is not a cryptographic hash: it catches a broken
or wrong download, and the trust is in reading the links file over HTTPS from rootfs.fex-emu.gg. So
an entry has to name an https URL (or one with the channel's own scheme, which the tests use).

What FEX published on 2026-10-16, checked by hand: `2026-08-11/ArchLinux.sqsh`, Hash
`23350f949fc1413d`, 1,359,826,944 bytes. The image's own `xxhsum` (xxhash 0.8.3-1, the package
`rootfs/manifest.lock` names) gives `XXH3_23350f949fc1413d` for it. With `unsquashfs`:
- It is squashfs 4.0, zstd.
- `graphics_provider.json` is at its root: x86_64 from `/usr/lib`, i386 from `/usr/lib32`.
- `freedreno_icd.x86_64.json` and `freedreno_icd.i686.json` point at
  `/usr/lib{,32}/libvulkan_freedreno.so`, Mesa 26.2.0.
- Both arches have glibc and `ld.so`.

A later image FEX publishes is used without that check, so x86 games keep working only as long as FEX
keeps those paths. The pin also takes a **fixed** image (`version`, `url`, `sha256` instead of
`channel`, `distro`, `type`), for an image of our own: then the sha256 is checked, and a new version
downloads when the pin changes.

The squashfs is the smaller build (the EroFS one is ~2.18 GB), and the image already ships
squashfuse. Steam leaves FEX's thunks off (`ThunksDB_GL:0,ThunksDB_Vulkan:0`); RetroForge turns the GL
one on per game ("The device's own driver", below).

**How it gets there** (`/usr/lib/retroforge/steam-x86-guest`, separate from `steam-bootstrap`). No
`steam` waits for the network:
- `steam` runs `steam-x86-guest start $$` before the client. That mounts what is installed and
  starts `fetch` detached in its own session, logging to steam's stderr, and returns at once. With a
  channel it does this at every start; with a fixed pin only while its image is missing.
- `fetch` reads the links file (one ~5 kB GET, 15 s at most) and picks the entry. When that image is
  not there yet, it downloads it to `~/.local/share/retroforge/fex-guest/.<name>-<version>.sqsh.part`,
  resuming a cut-off download with a Range request. It checks the XXH3 (or a fixed pin's sha256) and
  renames the file to `<name>-<version>.sqsh`. For a channel the version is the dated directory and
  the hash: `fex-rootfs-archlinux-2026-08-11-23350f949fc1413d.sqsh`.
- Only then does `fex-guest/current` point at it. Until then the image `current` names is the one
  mounted, so a channel move never leaves Steam without a guest.
- An older image is removed once it is neither current nor mounted: right away, or when the last
  `steam` that has it mounted exits.
- Offline, or a links file that is not JSON, has no such entry, or has two: `fetch` exits 1, logs
  it, and changes nothing. A hash mismatch removes the download. Without `xxhsum` nothing is
  installed; the download is kept and checked at the next start.
- Only one fetch runs at a time, and it refuses to start without ~1.6 GB free.

**The mount.** The image is mounted on `~/.local/share/retroforge/fex-guest/root` with the kernel's
squashfs and overlayfs, by root:
- `steam-x86-guest` (the player's) writes `fex-guest/.kernel-request` (`image=<file>`, `mesa=0|1`) and
  runs `systemctl --no-ask-password start retroforge-x86-guest-mount@<user>.service`, a oneshot that
  runs `/usr/lib/retroforge/steam-x86-guest-kernel mount <user>` as root and waits for it.
  `50-retroforge-x86-guest.rules` grants exactly that start, and `retroforge-x86-guest-release@<user>`'s,
  with the subject's own user name, to an active local wheel session. Steam's client runs in the
  player's user manager (`retroforge-steam.service`), outside the seat0 login, and polkit grants it
  there too (Air X, 2026-11-23); an SSH login as the player gets no grant.
- Root puts the image on a read-only loop device made from a descriptor and mounts it as squashfs on
  `/run/retroforge/x86-guest/<uid>/base`. Then it mounts an overlay with source `rf-x86-guest` on
  `fex-guest/root`, `lowerdir=<mask>:<our Mesa>:<opaque>:<base>`, read-only, nosuid and nodev. The two
  small layers in `/run` do the work of our Mesa's `.wh..wh..opq` markers, which the kernel's overlayfs
  would show as files: `<opaque>` has each marked folder with `trusted.overlay.opaque=y`, under ours;
  `<mask>` has a whiteout for each marker, over ours.
- **The image is the player's own file, mounted as it is** (decided 2026-11-23). FEX's channel only
  checks it with XXH3, which is not a cryptographic hash, so code running as the player (a game) could
  put a crafted image there and reach the kernel's squashfs driver. What root does not take from the
  player: the home comes from the password database, every folder below it is opened one at a time
  without following a symlink (each one the player's, on the home's filesystem), and the mounts go on
  those descriptors, so a symlink or a rename cannot move them onto `/usr` or `/etc`; the image is a
  regular file of the player's in `fex-guest` itself; no setuid program, file capability or device
  node in it works; release takes down only an overlay of its own (mount ids: root cannot even stat the
  player's FUSE mounts).
- When the unit is refused or fails, or mounts nothing, `steam-x86-guest` mounts with squashfuse
  instead, as the player, and logs why; `RETROFORGE_X86_GUEST_KERNEL=0` asks for FUSE only.

`steam` exports `STEAM_COMPAT_GRAPHICS_PROVIDER=<that>/graphics_provider.json` only when
that file is there, i.e. once the guest is mounted. pressure-vessel reads the variable for every
container it starts, and a file that does not exist yet aborts it (`opendir(...): No such file or
directory`): while the client still ran in a container of its own, a client started during the
first download never started (Air X, 2026-10-18). The client's environment is fixed when it starts, so after the first download x86
games get the guest from the next start of Steam; `steam` says so on stderr.
- **Mounted** by `start` when an image is there and nothing is mounted yet: a fixed pin's own image,
  else the current one. A mount is never made twice. A dead one (squashfuse killed: `ENOTCONN`) is
  released and replaced. `fex-guest/.mounted` records which image it is.
- **Download finishes while Steam runs:** it is mounted right then, so the next game has it. If an
  older image is already mounted for a running game, it is left alone, and the first start after
  the last `steam` exits mounts the new one.
- **Released** when the last `steam` exits. `start` leaves a holder process outside steam's process
  tree, so OGUI's Exit cannot reap it, with TERM, INT and HUP ignored. It holds
  `fex-guest/.users.lock` shared, watches steam's PID through a pidfd, and when that PID is gone
  (SIGKILL included) it lets go and unmounts: a kernel mount through `retroforge-x86-guest-release@`
  (lazily, `MNT_DETACH`), a FUSE one with `fusermount3 -u -z`. It skips the unmount if
  another steam still holds the lock. The client does not inherit the lock, so its leftover
  children cannot keep the mount. Mounting, unmounting and removing images run under
  `fex-guest/.mount.lock`.
- squashfuse starts with TERM and INT ignored, like PortMaster's runtimes. A kernel mount has no
  process to kill.

`steam` also links `~/.steam/sdk64` to `<Steam root>/linux64` and `~/.steam/sdk32` to
`<Steam root>/linux32`, which Proton under FEX needs (omarchy-pkgs issue 973).
`RETROFORGE_STEAM_X86_GUEST=0` turns the guest off: no download, no mount, no
`STEAM_COMPAT_GRAPHICS_PROVIDER`. The links are still made. The guest costs 1.36 GB in /home, on
top of the client's ~3 GB.

Checked on 2026-10-16:
- `tests/test-steam-x86-guest.sh`, with stub squashfuse and fusermount3, a local HTTP server and
  links files shaped like FEX's (over HTTP and `file://`): 100/100. It covers the channel picking
  its one entry, a move while Steam runs and with nothing mounted, a wrong XXH3, a hash without
  leading zeros, offline, nine kinds of bad links file, no `xxhsum`, and the fixed pin.
- In a linux/arm64 container, the helper with the real pin read the live `RootFS_links.json`,
  picked `ArchLinux/2026-08-11/ArchLinux.sqsh` and `23350f949fc1413d`, took the real image left as
  its part (FEX's server answered the Range request with 416), checked it with the image's own
  `xxhsum` and installed it. With one byte changed, it was refused and removed.
- With real FUSE, as a non-root player, a channel move from a small image to the real one served
  locally: the old image stayed mounted while the fake `steam` ran, was removed after it was
  SIGKILLed, and the next start mounted the real tree (ICDs, `libvulkan_freedreno.so` and `ld.so`
  for both arches readable).
- In a linux/arm64 container with `/dev/fuse` (Debian's squashfuse 0.5.2 and fuse3 3.17.2; the
  image ships 0.6.1), as a non-root player, with the real helper and wrapper:
  - `fetch` took the real image from a local server and matched the then-fixed pin's sha256
    (`5d0c1a38...5f5f2a`).
  - squashfuse mounted it, and `graphics_provider.json`, both ICDs, both `libvulkan_freedreno.so`
    and both `ld.so` were readable.
  - In Valve's arm64 Steam Runtime (`run --`, pressure-vessel, "Steam Runtime 3c"), the FUSE mount
    under `$HOME` was there and `$STEAM_COMPAT_GRAPHICS_PROVIDER` was readable.
  - The mount was released after `steam` exited normally, after a second `steam` (which neither
    mounted again nor released), after `steam` was SIGKILLed, and after a TERM to every process of
    the launch. A killed squashfuse's dead mount was replaced at the next start.

Not yet seen: the FEX tool using this provider, an x86 game or Proton running, anything on
hardware, and FEX on ARMv8.0.

### FEX's server, started before the launch

Before an x86 game starts, pressure-vessel (Steam Linux Runtime 2.0, soldier, for Megabonk) runs
~25 x86 helpers through FEX: the guest's `ld-linux-x86-64.so.2` and its capsule tools, probing the
libraries it will bring into the container. A FEX with no FEXServer up starts one (`FEXServer
--wait_pipe 4`), which inherits the helper's stdout and stays ~1 s after it, and pressure-vessel reads
that pipe to its end: each helper took ~1.25 s, 28 s in all, with the device mostly idle (exec trace,
MANGMI Air X, 2026-11-23). A FEX that finds the game's server up connects to it: a helper took
0.1-0.3 s. So `/usr/bin/steam` starts that server itself before handing the launch to Steam, as the
user unit `retroforge-fexserver-<appid>` (`FEXServer -f -p 60` with `FEX_PORTABLE=1` and the game's
`STEAM_COMPAT_DATA_PATH`, which put its socket at `compatdata/<appid>/fex-emu/Server/`), for a game
whose `compatdata/<appid>/fex-emu/Config.json` FEX's tool has written on an earlier launch: never for
a native or Proton game, or a first launch. It stays 60 s after its last client. Megabonk's window came
44-48 s after the launch instead of 69-73 s. The server holding the helper's pipe is FEX's
(FEX-2607-76, Valve's FEX-Emu tool), not ours to change.

Only before FEX 2611, which `/usr/bin/steam` reads from the tool's `VERSIONS.txt` (`FEX describe
FEX-2611`). From FEX commit 7a6d04e30 (2026-11-04, in FEX-2611, the tool's beta branch) Steam's FEX
server manager (`Source/Steam/ServerManager.cpp`) deletes the server's socket when the game's session
ends, without asking whose server it is. Ours then stayed up, holding `Server.lock`, with no socket, and
the next launch of that game failed `Couldn't connect to FEXServer socket` / `FEXServerClient: Failure to
setup client` until the unit stopped (Parking Garage Rally Circuit after a crash, Air X, 2026-11-24/25).
On FEX-2611 the server first gained nothing anyway: Megabonk's window 30-38 s after the launch with it or
without (2026-11-24). The runtime's helpers keep running without Multiblock on every version.

### Only our drivers in the guest

Most of those helpers are pressure-vessel's library capture: through the guest's x86 ld.so, for each
arch, every Vulkan driver the guest lists (`no-dependencies:...:path:/usr/lib/libvulkan_*.so`) and the
dependencies of every DRI driver (`only-dependencies:...:path:/usr/lib/dri/*_dri.so`). FEX's guest ships
9 Vulkan drivers and 66 DRI names per arch; four of those captures took 0.9-3.3 s each. The x86 Mesa
stage (`rootfs/lib-assemble-x86-mesa.sh`) keeps only `msm_dri.so`, `kgsl_dri.so` and `libdril_dri.so` in
our layer's `usr/lib/dri` and `usr/lib32/dri` (the msm kernel driver's name picks msm; the other names
Mesa installs with freedreno are display-only kmsro ones) and marks those folders and
`usr/share/vulkan/icd.d` opaque (`.wh..wh..opq`, which fuse-overlayfs honours in a lower layer), so the
guest's own entries there are hidden behind ours. Megabonk's window came 38-39 s after a warm launch
instead of 43-45 s, its capture phase 9 s instead of 14.5 s, and it drew its menu as before (Air X,
2026-11-23). The payload itself is unchanged: `compose.sh` flattens it into a guest with no overlay.

The kernel's squashfs + overlayfs in place of FUSE (squashfuse + fuse-overlayfs), root's mount (**The
mount**, above). Per FEX process it costs nothing measurable (x86 `true` 101-105 ms either way; FEX's own
start is ~20 ms, the rest of a short process is translating its ld.so and libc), but pressure-vessel's
probes read the guest's libraries through it. Megabonk on the Air X, the two in turn, each after a mount
and a launch not counted (2026-11-23, the GL thunk on), mounted by hand: the probes took 6.9-7.9 s on the
kernel's mounts against 11.1 s twice on FUSE, the container 2.4 s against 3.1 s, everything else the
same: ~4 s of every x86 launch. In the game itself nothing reads the guest after its start. TSO off
changed nothing; FEX's code cache made launches slower (below).

As built, mounted by `steam-x86-guest` itself (root's unit, or FUSE with `RETROFORGE_X86_GUEST_KERNEL=0`),
in turn, each after a launch not counted (Air X, 2026-11-23): the probes took 8.1 and 8.7 s against 10.9
and 11.2 s, the container 2.7 s against 3.0-3.1 s, and Megabonk's window came at 35.8 and 38.3 s against
38.5 and 40.2 s (Steam's own steps before the compat tool vary by 3 s from launch to launch either way):
~3 s of every x86 launch. Four more launches on the kernel's mounts: probes 6.8-8.4 s. Mounting takes
0.55 s (systemctl, polkit, root's helper) against 0.46 s with FUSE, once per start of Steam.
`tests/test-steam-x86-guest-kernel.sh` (root, real mounts): 37/37 on the Air X, in a mount namespace of
its own with a throwaway `/etc` and `/home` (OrbStack's kernel has no squashfs); its polkit and unit
cases also run without root.

Against the guest unpacked into a plain folder on `/home` (no mount at all; a copy of the merged tree,
4,474 MB and 99,536 files against the 1.36 GB image, 151 s to copy) and FUSE with `squashfuse_ll`
in place of `squashfuse`, in turn, twice each (Air X, 2026-11-23): probes 7.1 and 8.3 s on the plain
folder, 8.9 and 10.2 s on the kernel's mounts, 10.1 and 12.1 s on `squashfuse_ll`; Megabonk's window at
35.9/37.6, 36.0/37.1 and 39.5/43.0 s. With the page cache dropped, the plain folder and the kernel's
mounts came out the same (window 42.9 and 43.8 s, probes 10.0 and 9.6 s). So the plain folder is as fast
as the kernel's mounts, with no root and no FUSE; it costs ~3.1 GB more in `/home`. `squashfuse_ll` is
no faster than `squashfuse` here. No unprivileged kernel mount of an image exists to try: in 7.3 neither
squashfs nor erofs is `FS_USERNS_MOUNT` (overlayfs and FUSE are), and FEX's own image support runs
`squashfuse` or `erofsfuse` from FEXServer.

### The runtime's helpers without Multiblock

FEX's Multiblock (on by default) compiles several blocks at once, faster code that costs more to
compile. That suits a game, not the runtime's own x86 programs: its probes, shell tools and the scout
layer's scripts, hundreds of short processes that each run their code once. For a game FEX's tool has
set up, the wrapper's FEX step writes `{"Config": {"Multiblock": "0"}}` as `AppConfig/<program>.json`
in the game's `compatdata/<appid>/fex-emu` folder for 54 of them (the x86 ld.so, `ldconfig`, `bash`,
`sh`, coreutils, `capsule-capture-libs`, `detect-*`, `inspect-library`, `check-locale` and the
`steam-runtime-*` tools), only where no file is, so a player's own stays. The game itself keeps
Multiblock. Warm launches on the slim guest, with and without the files in turn (Air X, 2026-11-23):
Megabonk's window came 39.1-40.1 s after the launch instead of 40.9-43.1 s. The scout layer's scripts
took 4.3-4.4 s instead of 5.5-5.8 every time; the probes ~0.9 s less, but they vary by more than that
from one launch to the next. Before the guest was slimmed, the slow captures hid this gain.

### FEX's code cache: measured, left off

Valve's FEX (FEX-2607-76, upstream commit 37265b1) has a code cache, `EnableCodeCachingWIP`, off by
default. With it on, each FEX process records the code it compiled (`codemap/new`, under the game's
shader cache), and at its start asks FEXServer for caches: the server merges the code maps and runs
`FEXOfflineCompiler generate` for every program and library with new code, and the process waits
until it is done. Megabonk with it on (Air X, 2026-11-23, launch option `FEX_ENABLECODECACHINGWIP=1`):
its window came 67.2 s, 58.8 s and 46.1 s after three launches in a row, against ~40 s without, and
504 generations failed in 15 minutes, each tried again at the next process start. The server runs
outside pressure-vessel's container (ours, started before the launch, as does the one a probe starts),
so the runtime's files resolve to the device's own (`/usr/bin/ln` is the arm64 `ln`); FEX's offline
compiler has a `TODO: Pressure vessel hits this` there. The tool's other command, `FEXOfflineCompiler
process-all`, aborts (`std::out_of_range`, `map::at`): it expects an executable marker in every code
map, which FEX no longer writes there, and the check that would say so is compiled out of release
builds. Neither has to do with the ARMv8.0 CPU. What a working cache could save is the short FEX
processes' own translation, ~25 of them per launch, ~9 s summed and partly overlapping: a few seconds
of the launch, nothing of the game once it runs. That needs FEX to build caches for the files in the
container without holding every process start.

The ARMv8.0 cost is elsewhere: FEX logs `Host CPU doesn't support atomics. Expect bad performance` on
the SM6115 (no LSE), and turns every x86 atomic into a load-exclusive/store-exclusive loop.

## x86 games: the guest and its Mesa

Native x86 Linux games run under FEX, which the arm64 client adds to a game as a dependency. An
emulated x86 process loads only x86 libraries, so Steam needs an x86_64 + i386 **graphics
provider**: a root with `/graphics_provider.json` at the top, the x86 dynamic loaders, glibc and an
x86 Mesa, named by `STEAM_COMPAT_GRAPHICS_PROVIDER`. FEX can forward GL and Vulkan to the arm64
driver ("thunks"); Valve's tool leaves them off, so there the guest's x86 Mesa is the driver, compiled
and run under emulation. RetroForge turns the GL one on per game, by default ("The device's own
driver", below); the guest's x86 Mesa then drives Vulkan games and a game the player sets to x86 Mesa.

The guest is downloaded, never shipped: `/usr/share/retroforge/steam/x86-guest.pin` names a
squashfs image that the device fetches and mounts under `/home` with squashfuse. It starts out on
FEX's own ArchLinux RootFS (2026-08-11), whose Mesa is FEX's build of upstream 26.2.0, without our
Adreno patches.

`packages/mesa-x86` builds the replacement: the same Mesa tarball and patches as the host driver,
for x86_64 and i686 (Turnip, and GL on freedreno; Valve's own FEX guest Mesa ships zink over
Turnip instead, which fails inside Steam's runtime container), laid over that same FEX RootFS as `retroforge-fex-guest-<mesa version>-<revision>.sqsh`.
Composing it checks that both arches' ICDs and GL libraries resolve to our build and that every
library we add loads in the guest. `.github/workflows/release-fex-guest.yml` publishes it as a
Release asset (manual dispatch only, tag `fex-guest/v<version>`).

To switch devices to it, set `x86-guest.pin`'s `name`, `version`, `url` and `sha256` to the
published image (the release notes print all four) and ship that in a bundle. The Release asset's
url works as-is since the repo went public (2026-11); before that a device, which has no GitHub
login, could not download it. A Mesa bump in `packages/mesa` carries into the guest with nothing to edit
there; it needs a new dispatch and a pin bump. Details and the bump steps:
[`packages/mesa-x86/README.md`](../packages/mesa-x86/README.md).

Seen on hardware (Air X, 2026-11-23): our guest mounted and driving Megabonk, on its x86 Mesa (GL and
Vulkan) and on the device's own driver (GL).

### The device's own driver: FEX's GL thunk (Game settings > Graphics driver)

FEX's thunks swap a game's `libGL.so.1` (and `libvulkan.so.1`) for FEX's guest thunk libraries
(`GuestThunks/libGL-guest.so`), whose calls run the host's own arm64 Mesa natively (`HostThunks/
libGL-host.so`, which loads the device's `libGL.so.1`; pressure-vessel shows the host's root at
`/run/host`). Valve's tool ships both sides and a thunk database, `usr/share/fex-emu/ThunksDB.json`,
and leaves them off (`ThunksDB_GL:0,ThunksDB_Vulkan:0` unless `STEAM_COMPAT_FEX_CONFIG` says
otherwise). Turned on as FEX documents it, they do nothing here: the database names its paths as
`@PREFIX_LIB@/libGL.so.1`, FEX expands that from where it finds the guest's libraries, and inside the
container the root is empty, so it checks the game's working folder, decides the root is not
multiarch and expands to `lib64` folders. The game opens `libGL.so.1` through pressure-vessel's
overrides and from the graphics provider at `/run/gfx/main/usr/lib`, which match none of them, and
keeps the x86 driver.

So `retroforge-steam-direct fex APPID`, which `/usr/bin/steam` runs before every launch of a game,
writes two kinds of file into the game's FEX folder (`<library>/steamapps/compatdata/<appid>/fex-emu`):
- `ThunksDB.json`, FEX's local database (it replaces Valve's GL entry), with the literal paths the x86
  loader opens there: the overrides, `/run/gfx/main/usr/lib{,32}` and the multiarch folders.
- `AppConfig/Steam_<appid>_<program>.json`, `{"ThunksDB": {"GL": 1}}`, for each x86 program in the
  game's folder (an x86-64 or i386 ELF with an interpreter, three levels deep). FEX
  keys these by app id and program, so pressure-vessel's own x86 probes keep the guest's driver.

Each file carries a `RetroForge` key; one without it is the player's own and stays as it is. That
covers a game's first launch too: an installed game with an x86 program and no Proton prefix in its
compat data is an x86 game. Game settings > RetroForge > "Graphics driver" (shown for x86 games
only) offers Default (x86 Mesa), Native and x86 Mesa; only Native writes these files, and the others
remove ours, from the next launch. It is the `driver` key in `steam-games.json`
(`retroforge-steam-direct game APPID set driver native|x86|default`).

The default is x86 Mesa since 2026-11-25 (it was Native from 2026-11-23). FEX's thunks pass some of a
game's own callbacks to the host's driver as they are, as x86 code the host then jumps into: a debug
messenger chained into Vulkan's instance creation (FEX's host `vkCreateInstance` swaps out only the older
debug-report callbacks), and GL functions the game fetches through `glXGetProcAddress`, which FEX's
generic host-pointer wrapper calls with every argument as it came, past the callback stubs its direct
thunks use. Parking Garage Rally Circuit (Godot 4.5, verbose output, so it sets both) died of SIGILL on
the Vulkan thunk and on the GL thunk (`--rendering-driver opengl3`), the core's pc in the game and its
return address in the host's `libvulkan.so.1` or `libgallium`; on x86 Mesa it ran (Air X). The fix is
FEX's, in its thunk libraries.

Megabonk on the Air X, with and without in turn (2026-11-23): the game maps `libGL-host.so` and the
host's `libgallium-26.3.1-retroforge` (`/run/host/usr/lib`, no x86 Mesa), Unity reports `FD610`, `Mesa 26.3.1-retroforge1.1.1`, GL 4.6, and the
menu draws as on x86 Mesa (screenshots). Its menu ran at 14-15 frames a second either way, the GPU at
its top clock (1050 MHz): there the A610 is the limit. The game's CPU time fell from 116-117% of a
core to 92-99%, and the Unity load from its first log line to its window from 13.0-13.4 s to
10.5-10.7 s. In a run (Forest, 20 s in): 15 frames a second either way, the game's CPU 137-163% of a
core against 185-197% on x86 Mesa, its window 38.2-40.5 s after the launch against 40.8-41.5 s.

Vulkan stays on the guest's x86 Turnip. FEX's Vulkan thunk needs two more things here: the host
side's loader sees only the container's manifests, so it needs the device's own (`VK_DRIVER_FILES`,
through FEX's `HostEnv`, naming `/run/host/usr/lib/libvulkan_freedreno.so`), and Steam's
`VK_INSTANCE_LAYERS` (`VK_LAYER_VALVE_rpo:VK_LAYER_VALVE_fdm_injection`) dropped there. With both,
Megabonk on Vulkan (`-force-vulkan`) found the device's Turnip and opened its window, then died a
minute in: `Vulkan - Out of memory! (allocating memory for buffer)`, SIGSEGV. On x86 Turnip it ran
(17 frames a second in its menu, 106% of a core).

That out-of-memory was not the thunk's (2026-11-23, Air X). No Vulkan call failed and memory was
plentiful: Unity stops using a memory type once its usage passes ~92% of the budget it is shown, and
it was shown a 512 MiB heap. The shell's VRAM report limit (`retroforge-session` starts OGUI with
mesa's vram-report-limit layer on) reached the game: OGUI's environment was `/usr/bin/steam`'s, a
client started there copied it, and the host side's loader loads the arm64 layer. With the layer off
for the host side, Megabonk ran on the thunk past the 2-minute test. The fault was the layer's: it
scaled the budget down to the reported heap but passed the driver's usage through, so a game saw
its heap fuller than it was by the same ratio (about 6.6 times here). Mesa patch 0025 scales the
usage too (2026-11-24). Air X, the same launch with the 512 MiB report: the image's layer, out of
memory ~40 s in; 0025's, still running at 165 s. So the variables reach Steam's and the stores' games
again, as the shell's report, and the client the session starts at boot gets them as well
(`/usr/bin/steam` and `store` had dropped them from 2026-11-23); Proton's DXVK sees the same 512 MiB
heap. `retroforge-launch` still drops them for emulators, which get their own report.

With Native, Vulkan goes through the thunk too (since 2026-11-24), for 64-bit programs (Valve's tool
has no 32-bit Vulkan guest library): `retroforge-steam-direct fex` adds the Vulkan entry to the
game's `ThunksDB.json`, writes `retroforge-vulkan-icd.json` (the host's Turnip manifest with the
library under `/run/host`) beside it, and each program's app config names it (`HostEnv
VK_DRIVER_FILES`) and empties `VK_INSTANCE_LAYERS` on the host side (`AppOverrides "*"`, one
`HostEnv` per block). Megabonk on Vulkan, Air X: its menu 108-111% of a core against 116-118% on x86
Turnip, a run 207-233% against 237-244%, 19-20 frames a second against 18; it also gets the gamescope
WSI layer, which x86 Turnip does not load. Game settings > Graphics driver > Native turns these
thunks on for a game; the default, x86 Mesa, keeps GL and Vulkan on the guest's driver (above). The
same app config carries the game's FEX TSO either way.

## Proton-CachyOS arm64, and DXVK-Sarek for the Adreno 610/613 (downloaded, not shipped)

**Why the A610 needs it (2026-10-16).** Turnip in Mesa 26.2.5 (`packages/mesa`) gives the A610 only
Vulkan 1.0. It reaches 1.3 because `etc/retroforge/session.conf` exports `TU_DEBUG=noconform` on the
SM6115, and that also fakes `multiViewport`. Mesa 26.3 (final ~2026-11-04) removes noconform and keeps
multiViewport off on a6xx_gen1_low (Mesa 82b86896). Every upstream DXVK (1.10.3, 2.x, 3.x) requires
multiViewport, so after that bump DXVK-Sarek is the only DXVK that creates a device on the A610. The
A650 (SM8250) runs Valve's Proton 11 (DXVK 2.7) but not DXVK 3.x (Proton Experimental,
Proton-CachyOS), because it has no `storageBuffer8BitAccess`. The A740 and A750 run anything. The
SM4450's Adreno 613 is a6xx_gen1_low like the A610.

Proton-CachyOS publishes an arm64 build with an ARM64EC DXVK-Sarek (`files/lib/wine/dxvk-sarek/
aarch64-windows/`), turned on by `PROTON_DXVK_SAREK=1`. Its `toolmanifest.vdf` requires tool appid
4185400 (Steam Linux Runtime 4.0, arm64), which Steam downloads itself. Its maintainers call the arm64
build untested. A local ISA scan of `cachyos-11.0-20261005-slr` found nothing beyond ARMv8.0 except
LSE atomics (covered by `0025`), apart from libraries that pick their code path at run time. Its
`proton` also turns Sarek on by itself when the GPU lacks Vulkan 1.3 with `descriptorIndexing`, but
under noconform the A610 reports 1.3, so that check does not pick Sarek today.

**Sarek follows the GPU, with no setting (2026-10-31).** On the Adreno 610 (SM6115) and 613 (SM4450)
DXVK-Sarek is the only DXVK that will run, so it is not a choice: every Proton of ours installed there
(Proton-CachyOS, or its ARMv8.0 rebuild) gets a `user_settings.py` holding `PROTON_DXVK_SAREK=1`, which the
tool applies to every game it runs, with the client or without it. Every other GPU runs upstream DXVK,
and nothing of ours turns Sarek on there: a player who wants it for one game sets
`PROTON_DXVK_SAREK=1 %command%` in its launch options in Steam, as for any other Proton option.
`steam-compat-tools install` decides from device-env's SoC class (`RETROFORGE_STEAM_SAREK=on|off`
overrides it, for testing) and makes every tool of ours agree: it writes the file where it is
needed, and deletes ours (only ours) elsewhere. Nothing exports `PROTON_DXVK_SAREK` (Valve's Proton
ignores it anyway). Until 2026-10-31 there was a `DXVK_SAREK` setting (`retroforge-steam-sarek`, a
"Steam: DXVK-Sarek (low-end GPUs)" toggle, and a per-game DXVK-Sarek row): its toggle said it turned
Sarek on, but only downloaded a tool nothing selected. A leftover `DXVK_SAREK=` line in `steam.conf`
is ignored, and a `user_settings.py` that toggle wrote is still recognised as ours.

**Steam's driver query ends at once there (2026-11-23).** At every start the client runs
`proton run d3ddriverquery64.exe` (and `-d3d12`) with its default tool, inside Steam Linux Runtime 4.0,
to pick that tool's shader-cache buckets (`CGetCompatToolBucketJob` in `shader_log.txt`). On the SM6115,
where our ARMv8.0 build is that default, the two Wine starts took ~50 s beside the first game after a
boot and slowed its start ~10 s (Megabonk's window 69-78 s after a cold launch, 61-65 s without them,
page cache dropped); the D3D12 one fails on the A610 anyway, so the result is never kept. Nice 19 and
idle I/O for it changed nothing: it costs the SD card and memory, not CPU time. The caches those
buckets brought had no shader module in common with what Hades created on the Air X (Steam's own
recording, `steamapp_pipeline_cache.foz`: 74 modules; the tool's bucket 193, the generic one 155, none
shared). So our `user_settings.py` ends the query at once (`d3ddriverquery64.exe` in Proton's arguments:
exit 1). Steam then picks no per-tool bucket for it; the generic Vulkan bucket (`G7:VulkanPipelinesV6`)
does not depend on the query. A `user_settings.py` with only the Sarek line, which earlier releases
wrote, is still ours and is rewritten.

**D3D12 with Sarek on (2026-11-26).** vkd3d-proton does D3D12 on these GPUs, but with Sarek on, Proton
copies Sarek's `dxgi.dll` too, and two things stood between a D3D12 game and its first frame
(Ghostrunner with `-dx12`, Epic, Air X):
- *Its swap chain.* Sarek's DXGI (a DXVK 1.10 fork) makes swap chains only for devices offering Wine's
  `IWineDXGISwapChainFactory` (`53cb4ff0-…`). vkd3d-proton dropped that in 2.8 for DXVK 2.x's
  `IDXGIVkSwapChainFactory` (`e7d6c3ca-…`). Logged: vkd3d's `d3d12_command_queue_QueryInterface:
  {53cb4ff0-c25a-4164-a891-0e83db0a7aac} not implemented`, Sarek's `DXGI: CreateSwapChainForHwnd:
  Unsupported device type`, Unreal's `WindowsD3D12Viewport.cpp:224 … DXGI_ERROR_UNSUPPORTED`. Upstream
  DXVK's DXGI is no way out: it lists only adapters with DXVK's required features, multiViewport among
  them, so none on the A610, and it cannot sit beside Sarek's `d3d11.dll` (the two pass C++ objects). Our
  ARMv8.0 build patches Sarek's DXGI (retroforge-linux/proton-cachyos-armv8,
  `patches/extras/dxvk-sarek/0001`): vkd3d-proton's presenter goes behind Sarek's swap chain through a
  small adapter; D3D10/11 swap chains take the same path as before. Sarek keeps D3D12 out of its scope
  (pythonlover02/DXVK-Sarek#51). The SM4450 keeps CachyOS's own build, so its D3D12 games still fail
  here until CachyOS or Sarek carries the patch.
- *Descriptor sets.* Turnip offers 4 (`maxBoundDescriptorSets`): a6xx has 5 and Turnip keeps one for
  dynamic offsets (driconf `tu_dont_reserve_descriptor_set` frees it, but DXVK-Sarek uses dynamic
  buffers, so not for every game). With descriptor buffers, vkd3d-proton keeps typed and raw views in two
  sets beside the samplers, and a root signature with static samplers and root descriptors then needs 5:
  `Root signature requires 5 descriptor sets, but device only supports 4`, and Unreal's
  `CreateRootSignature … failed`. Our Sarek `user_settings.py` sets `VKD3D_CONFIG=mutable_single_set` and
  `VKD3D_DISABLE_EXTENSIONS=VK_EXT_descriptor_buffer` (the second is needed: vkd3d-proton ignores the
  first with descriptor buffers): one mutable set, 4 in all. Only vkd3d-proton reads them. The previous
  text of the file is still ours and is rewritten.

Measured on the Air X with the patched `dxgi.dll` (built in Proton's steamrt4 arm64-llvm SDK as ARM64X,
as CachyOS builds Sarek) placed next to the game's exe, which Wine loads before system32's: Ghostrunner
made its swap chain (1280x720, 3 buffers) and presented its intro; about a minute in, msm reported a GPU
hang (`offending task: vkd3d_queue`) on a kernel without patch 0295, most likely the same hangcheck kill
of a long submit as on its D3D11 path (0295), not re-tested with 0295. D3D11
was unchanged: Greak: Memories of Azur (GOG, Unity) gave the same DXGI log, D3D11 log and screenshot with
the patched and the shipped `dxgi.dll` (a black intro video in both: Sarek cannot open the video's shared
textures, `OpenSharedResourceGeneric: Handle not found`, also separate).

**Apps > Proton (2026-10-31).** One entry of the Apps list for the Proton RetroForge keeps for
Windows games, because Steam, GOG and Epic share it: on a CPU with LSE atomics Proton-CachyOS arm64, on
an ARMv8.0 CPU its ARMv8.0 rebuild (below). The plugin adds the entry itself (`proton_tool.gd`; no
`retroforge-emu` catalog row), credited to the releases' GitHub owner (CachyOS, retroforge-linux). Its
page is the tool's row, with its installed release and a Download button (Update once installed) that
shows the download's percentage. Steam Client's page keeps only Steam's own rows (keep it running,
start games without it). Until 2026-10-31 a "CachyOS Proton arm64" row sat under Apps > Steam Client,
where a GOG- or Epic-only player would not look; until 2026-11-01 ARMv8.0 CPUs also had a **Channel**
dropdown (the Valve-based builds' stable or experimental).

The row runs `/usr/bin/retroforge-proton install`, which runs `steam-compat-tools install` as the user
unit `retroforge-steam-compat-tools` and waits for it (a run of that unit already going, a `steam`
start's, is waited for first). A user unit is not under OGUI's reaper, and the
download goes on if OGUI restarts. `install` puts the newest release in place as below, and never
selects it in Steam. The percentage is `~/.local/share/retroforge/steam-compat-tools.progress` (0-100,
then `unpacking`; gone when the run ends). `retroforge-proton status` (`steam-compat-tools status`)
prints the tool this device takes as JSON: `name`, `display_name`, `author`, `homepage`, `installed`
(the release tag, or null) and `armv8`. The store launcher (GOG, Epic) uses the same tool, with the same
`install`, at a game's first install and each launch when the game has no Proton of its own: one
download serves both. Log: `~/.local/share/retroforge/steam-compat-tools.log`.

**Which release: a channel.** `/usr/share/retroforge/steam/proton-cachyos-arm64.pin` names a channel,
not a version: the device resolves what is published now. Each `install` makes one request to GitHub's
API (`/repos/CachyOS/proton-cachyos/releases?per_page=20`; 60 an hour are allowed without a token: one
per Download/Update press or store launch) and takes the newest release that has
`proton-cachyos-*-slr-arm64.tar.xz` and its `.sha512sum`. Newest means the
highest Proton version, then the latest published: `cachyos-10.0-sunset-slr` was published a week after
`cachyos-11.0-20260601-slr`, and a newest-by-date rule would have moved every player back to 10.0.
Drafts, prereleases and assets still uploading are skipped. The tarball (~356 MB) has to match the
`.sha512sum`, and the sha256 GitHub's API lists for it. Offline, rate-limited, or on any API error or
answer without an arm64 build, the installed release stays (exit 0, and the log says why); on a card
with nothing installed yet, it fails (exit 1) and the row says so. A `tag:` in the pin holds one release
instead (reproducible builds, or keeping players off a bad release), optionally with its `sha512:`;
once that release is installed nothing is asked. On 2026-10-16 the channel resolves to
`cachyos-11.0-20261005-slr`.

**One name.** Whatever the release, the tool is
`~/.local/share/Steam/compatibilitytools.d/proton-cachyos-arm64-retroforge/`, and its
`compatibilitytool.vdf` is rewritten so that its internal name is `proton-cachyos-arm64-retroforge` and
its display name "Proton-CachyOS arm64 (RetroForge)" (only those two strings change; the comments,
`install_path`, `from_oslist` and `to_oslist` stay the release's). Steam records a game's tool in
`config.vdf`'s `CompatToolMapping` by that internal name, so a game set to the tool keeps it through
updates.

**Updates.** A new release is downloaded, checked and unpacked (~2.2 GB) under a temporary name in the
Steam root, renamed to the tool's name, and swapped in by two renames (the old tree out, the new one
in), so Steam never sees half a tool. A player's own `user_settings.py` moves into the new tree. A game
running from the old tree would, after the swap, start wine processes and load DLLs from the new one
by path, and wine refuses a wineserver of another build. So while a process of the player's runs from
the tool (its program, its working folder, or a file it maps), the new tree waits, checked, in
`~/.local/share/Steam/.retroforge-compat-tools.next/`, and goes in at the next `install` that finds
nothing running from it, without a second download. One withdrawn upstream meanwhile is dropped. A
running Steam reads the new `toolmanifest.vdf` at its next start.

**Using it.** Steam reads `compatibilitytools.d` only when it starts, so restart Steam once the row
says it is installed. Then select "Proton-CachyOS arm64 (RetroForge)" per game (Properties >
Compatibility > Force the use of a specific Steam Play compatibility tool), or for every game
(Settings > Compatibility > Default compatibility tool). Nothing edits Steam's `config.vdf`: choosing
the tool is the player's, once.

**What it never touches.** Each folder it installs carries `.retroforge-pin` (name, tag, asset, sha512,
sha256). A folder without one is someone else's: other tools, and a Proton-CachyOS the player installed,
even under the tool's name. A `user_settings.py` the player edited is theirs too.

**From the per-release folders.** The first version of this installed each release under its own name
(`compatibilitytools.d/proton-cachyos-11.0-20261005-slr-arm64/`, with a `.retroforge-pin`). Those are
removed once the one-name folder is in place, each when nothing runs from it, and a player's own
`user_settings.py` in one moves into the new folder. A game set to one has to be set to "Proton-CachyOS
arm64 (RetroForge)", once.

**Removing it.** Delete
`~/.local/share/Steam/compatibilitytools.d/proton-cachyos-arm64-retroforge/` (and
`~/.local/share/Steam/.retroforge-compat-tools.next/`, if there), and set games that used it back to
another tool. Steam Linux Runtime 4.0 (arm64) can then be uninstalled from Steam's library like any
tool.

Checked in a linux/arm64 container on 2026-10-16: the image's pin against the live API resolved to
`cachyos-11.0-20261005-slr` (sha256 `e59b646e...cd06c37` as GitHub lists it, the live `.sha512sum`
`81ca1b66...b1c0fa`, the same as a local copy's). Through the live API's own JSON, with that release's
two URLs pointed at local copies, `steam-compat-tools on` (now `install`) installed it in 5 s: 2,191 MB, 1,972
symlinks, none broken, `toolmanifest.vdf` the release's (require 4185400), `compatibilitytool.vdf`
renamed as above, `user_settings.py` importing as `{'PROTON_DXVK_SAREK': '1'}`. A second `on` made its
one API request and touched nothing, and `off` then `on` removed and restored `user_settings.py`.
Updates, the wait while a process runs from the tool, and the move from per-release folders are covered
by `tests/test-steam-compat-tools.sh` with small fake releases and a fake API.

Not yet seen:
- Whether the arm64 client lists the tool. Its `compatibilitytool.vdf` says `to_oslist linux`, and
  steamclient.so has "Ignoring tool %s as it's for a different target platform %s.".
- Whether the arm64 client keeps a game's tool across an update under the rewritten name (that Steam
  keys `CompatToolMapping` by the internal name is how it works on x86; not watched on this client).
- Whether a game in Steam Linux Runtime 4.0 (pressure-vessel) shows the tool's path in
  `/proc/<pid>/maps` as the check expects; if not, an update goes in while the game runs.
- Whether the client's environment reaches games: the client runs on the host, games in Steam
  Linux Runtime 4.0. `user_settings.py` covers that either way.
- Steam fetching 4185400 on arm64, a game run with the tool, Sarek on an A610 or A613, the plugin's
  Download row on a device, anything on hardware. A release after `cachyos-11.0-20261005-slr` is not ISA-scanned before
  players get it.

## ARMv8.0 CPUs: Proton-CachyOS rebuilt for them (downloaded, not shipped)

Valve's Proton ARM64 and Proton-CachyOS are built with `-march=armv8.2-a`. On the SM6115 they run only
through kernel patch 0025, and that costs a lot. Measured on the Air X (2026-10-22): an emulated atomic
costs 276 ns on the A73 and 487 ns on the A53, against ~11 ns for LL/SC. While Hades loaded, emulations
peaked at 3.36M/s, about 1-1.5 cores. ~94% came from Proton's `aarch64-windows/ntdll.dll`
(RtlEnter/LeaveCriticalSection, RtlAllocateHeap). LSE instructions in `ntdll.dll`: Valve 245, Proton-CachyOS
252; in CachyOS's Sarek `d3d11.dll`: 6,048.

[retroforge-linux/proton-cachyos-armv8](https://github.com/retroforge-linux/proton-cachyos-armv8) rebuilds
each new Proton-CachyOS `cachyos-*-slr` release on GitHub's arm64 runners: CachyOS's own arm64 build
(`configure.sh --target-arch=arm64 --without-nvidia-libs`, `make redist`) with `Makefile.in`'s arm64
targets at `-march=armv8-a` (C), `-Ctarget-cpu=generic` (Rust) and FEX at `TUNE_CPU=generic`. When those
lines change upstream the build stops instead of shipping LSE, and a release (`<tag>-armv8`) goes out only
when its LSE scan (`scan-lse.py`, from sunshineinabox/proton-armv8) finds no inline LSE/RCpc. Being
Proton-CachyOS, it carries DXVK-Sarek and umu-protonfixes, and runs a game without the Steam client when
`UMU_ID` is set, which the store's launcher needs.

When `/proc/cpuinfo` has no `atomics`, `steam-compat-tools` takes `proton-cachyos-armv8.pin` instead of
`proton-cachyos-arm64.pin`: assets `proton-cachyos-*-slr-armv8.tar.zst`, each checked by its `.sha512`
(`sidecar: .sha512`), installed as `compatibilitytools.d/proton-cachyos-armv8-retroforge`, "Proton-CachyOS
ARMv8.0 (RetroForge)". Everything else works as for Proton-CachyOS above: the newest release, one request
per run, the one-name folder, the wait while a game runs from it, and Sarek through `user_settings.py`.
Sarek follows the GPU in every folder RetroForge installed, so a Proton-CachyOS left on such a device
follows it too.

**When it is installed.** On these CPUs it is not an optional download:
- **Steam:** part of Steam Client's install (`steam-install`, a stage of its bar after the x86 guest and
  before the client's own update; the install fails without it). Then `retroforge-steam-proton apply`
  makes it Steam's default compatibility tool and each installed Windows-only game's own. The client
  writes `config.vdf` only at its first real start, so when there is none yet `apply` writes one holding
  just that default, which the client reads and keeps; the first Windows game already runs with it. It
  does so again at each `steam` start (updating it in the
  background). Never while the client runs: `config.vdf` is the client's then. A client kept running in
  the background may not start again before the next boot, so one that started without it (opened
  while Steam Client's install or the build's download ran, or a Windows game installed under it,
  which Valve's recommended Proton would otherwise take: priority 85 over the default's 75) is
  stopped before the next launch from the shell that finds no game running and no other launch
  holding its UI (`retroforge-steam-proton pending`, `retroforge-steam-keep stop-unused`). That
  launch starts Steam cold, with the tool set. Once per entry and boot: an entry the client drops
  after it was written does not restart it again. A game started from inside Steam's own UI while
  it is open still gets the old tool. On CPUs with LSE atomics Proton-CachyOS stays an optional
  download (Apps > Proton) and is never made a default.
- **GOG and Epic:** part of the first game's install (`store install`: its download is 85-99% of that
  bar), on every CPU, as the tool this CPU takes.

**The Valve-based builds before it (until 2026-11-01).** ARMv8.0 CPUs took
[sunshineinabox/proton-armv8](https://github.com/sunshineinabox/proton-armv8)'s rebuild of Valve's Proton
(stable `proton-armv8.pin`, experimental `proton-armv8-experimental.pin`, a Channel dropdown, a per-game
choice). Valve's `proton` always starts a game through its own `steam.exe`, which asserts without the
client (`steamclient_main.c "!status"`), so GOG and Epic games could not run with it. Its folders
(`proton-armv8-retroforge`, `proton-armv8-experimental-retroforge`, by their `.retroforge-pin`) are
removed once Proton-CachyOS ARMv8.0 is in place, each when nothing runs from it, and a Steam game set to
them moves to the new tool. A leftover `PROTON_CHANNEL=` line in `steam.conf` is ignored. Seen with that
build on the Air X (2026-10-22/23): emulations fell from ~3.36M/s to ~1,000/s at their peak, none from
`ntdll.dll`.

**FEX: Valve's, untouched.** Valve's FEX tool (app 3127680, `steamapps/common/FEX-Emu`, for native x86 Linux
games) is built for ARMv8.1+ as well: 388 inline LSE sites in its seven binaries. An ARMv8.0 build of it,
swapped into Valve's tool or installed as a tool of its own, ran SuperTux on the Air X with no emulations
(2026-10-23), but it was dropped (2026-10-28): nothing RetroForge ships replaces or adds a FEX. On ARMv8.0
CPUs native x86 Linux games are not supported; a game with a Windows build runs it with Proton-CachyOS
ARMv8.0 (Steam's default there, or Properties > Compatibility). Proton's own FEX, inside Wine for x86
Windows code, is part of the Proton build and unaffected (the per-game FEX TSO row, above).

## Remote Play (the handheld as a client)

Valve's arm64 client has the whole Remote Play client (`steamrtarm64/streaming_client`): a PC's
games show a Stream button in Big Picture, and nothing gates it to the Frame. Its Frame-only
paths (VR streaming, pairing over the Frame's own hotspot, echo cancellation) switch on with
`-steamframe`/`-deckard`, which we never pass. What the image adds:

- **A way in.** Open on Main menu > Apps > Steam Client (`apps_page.gd`) starts
  `steam -gamepadui -steamos3 -steampal -steamdeck steam://open/bigpicture`. Not `steam://rungameid/`:
  OGUI treats that as one game and SIGTERMs Steam once only Steam's own windows are left, which would
  end a stream. There is no Steam library card.
- **Controllers.** Valve's `60-steam-input.rules` (steam-devices, verbatim, MIT): uaccess on the
  hidraw nodes of Steam, Sony, Nintendo, 8BitDo and other pads, so Steam Input reads them directly
  and forwards gyro, trackpads and paddles. The handheld's own controls reach Steam as InputPlumber's
  virtual Xbox Elite 2 pad.
- **Hardware decode.** The client decodes H.264/HEVC through its own stateful V4L2 decoder
  (`CV4L2Accel`): it probes `/dev/video-dec0..99` and `/dev/video0..99` for a mem2mem device, so
  iris (every SoC; SM6115 and SM4450 since 2026-11-23 through `kernel/patches/1095`, venus before)
  needs no package in the image. `70-retroforge-video-codec.rules` links `/dev/video-enc0`, and
  `/dev/video-dec0` on the SM6115 only: the UI's Chromium decodes on the codec only when
  `/dev/video-dec0` exists, and on SM8250/8550/8650 that is slower and hotter than its CPU decode
  (four cores at 95 C on the Pocket FIT at its first sign-in, 2026-10-29; Nova-Deck measured the
  same and ships no link). The SM4450 gets none until measured. On the SM6115 the codec decodes the
  UI's video up to its 1920x1088 frame limit, which `kernel/patches/1097` makes it report (larger
  video, such as Steam's 1920x1200 startup movies, stays in software). Chromium reads every decoded
  frame on the CPU, so `1098` maps the frames cached: uncached, a 1080p30 VP9 clip in Steam's UI
  showed 180-188 of 300 frames at 167-175% CPU, worse than software; cached, 297-298 at 106-112%,
  against software's 300 at 161-170% (venus on the MANGMI Air X, 2026-11-22; the iris ports of both
  patches are not measured yet). Without a decoder the client falls back to software (FFmpeg 8 in
  `libvideo.so`).
- **Network.** The image has no firewall: discovery (UDP broadcast on 27036) and the stream
  (UDP 27031-27036, TCP 27036-27037) are open. A firewall added later must keep those open.
- **Audio** goes through pipewire-pulse, as for everything else.

Hosting is not offered: the client's encoders are x264, VA-API and NVENC, and Adreno has no VA-API,
so the handheld would encode in software next to the game.

To check on hardware, per board: the Stream button finding a PC over Wi-Fi; the client naming
"V4L2 ... hardware decoding" as its decoder (and no `CV4L2Accel:` errors); a stall after the first
frame (Steam starts both V4L2 queues before any bitstream; if upstream Iris waits on it, try
`STEAMLINK_V4L2_RESET_AFTER_LAST_BUF=1`); the stream window taking focus under OGUI's gamescope; who
gets the Guide button ("Hold GUIDE to control remote session"); software-decode load on the SM6115
at 720p60, its decoder's ceiling with 1080p30.

## Open

- Boot the kernel with 0025 and drop the shim (0025 also removes the shim's one weakness: no
  signal is involved, so a thread's signal mask cannot matter).
- On the Adreno 610, Steam's idle sign-in screen alone kept the GPU ~80% busy (its CEF GPU
  thread 49%, webhelper 13%, compositor 8%, Xwayland 6%): the background animates. To measure
  after sign-in.
- One `steamwebhelper` child segfaulted once at startup (Chromium restarted it).
- Integration: who owns the Guide button when OGUI launches Steam -- with Big Picture in front,
  Steam's input takes the quick-bar chord.
- On hardware: the owned list from the device's own caches, and Install and Uninstall through
  Steam's dialog (the formats were checked on a Mac client's caches).
- x86 games need FEX: Valve's on CPUs with LSE; on ARMv8.0 none (Windows build with our Proton instead).
