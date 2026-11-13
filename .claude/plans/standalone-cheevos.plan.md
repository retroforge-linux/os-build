# RetroAchievements for the standalone emulators — plan

Status: written 2026-11-13 (branch feat/standalone-cheevos), design as agreed in chat 2026-11-13.

## Why

The RetroArch plan gave gb, gbc, gba, snes, md, segacd and n64 RetroAchievements with one sign-in
(Settings > Library > RetroAchievements, `retroforge-cheevos`). Five standalone emulators we ship
have the same rcheevos client built in, and RetroAchievements' login token belongs to the account,
not to the program that asked for it: the token `login2` already gave us signs them in too.

| System(s) | Emulator (catalog pin) | Where it keeps the sign-in (under $HOME) | Hardcore | Booleans |
|---|---|---|---|---|
| psx | DuckStation v0.1-11894 | `.local/share/duckstation/settings.ini` `[Cheevos]` Enabled, Username, **Token encrypted** | ChallengeMode (default false) | true/false |
| ps2 | ARMSX2 2.9 (PCSX2) | `.config/ARMSX2/inis/PCSX2.ini` `[Achievements]` Enabled, Username; `inis/secrets.ini` `[Achievements]` Token | ChallengeMode (default false) | true/false |
| psp | PPSSPP v1.20.4 | `.config/ppsspp/PSP/SYSTEM/ppsspp.ini` `[Achievements]` AchievementsEnable, AchievementsUserName; token = the whole of `PSP/SYSTEM/ppsspp_retroachievements.dat` | AchievementsChallengeMode (**default true**) | True/False |
| gc, wii | Dolphin 2609 (pkgforge) | `.config/dolphin-emu/RetroAchievements.ini` `[Achievements]` Enabled, Username, ApiToken | HardcoreEnabled (**default true**) | True/False |
| dc | Flycast 2.7 (pkgforge) | `.config/flycast/emu.cfg` `[achievements]` Enabled, UserName, Token | HardcoreMode (default false) | yes/no |

Sources read 2026-11-13 at the pinned tags: duckstation `src/core/achievements.cpp` +
`settings.cpp`, ARMSX2 `pcsx2/Achievements.cpp` + `pcsx2-qt/QtHost.cpp` (secrets layer) +
`Pcsx2Config.cpp`, ppsspp `Core/RetroAchievements.cpp` + `UI/NativeApp.cpp` (NativeSaveSecret) +
`Core/Config.cpp`, dolphin `Core/Config/AchievementSettings.cpp` + `CommonPaths.h` (CMake
`USE_RETRO_ACHIEVEMENTS` ON by default), flycast `core/achievements/achievements.cpp` +
`core/cfg/option.cpp`.

Out of reach: melonDS 1.1 has no RetroAchievements; RetroAchievements does not cover 3DS, Wii U,
Xbox or PS3 (Azahar, Cemu, hakux, RPCS3). DS achievements would mean RetroArch's melonDS DS core: a
separate decision, not this plan.

### DuckStation's token

DuckStation keeps `Token` = base64(AES-128-CBC(token zero-padded to 16 bytes)), key = SHA-256 of
(the bytes of `/etc/machine-id`, newline included, then the user name), re-hashed 100 more times;
AES key = its first 16 bytes, IV = its last 16. Not portable mode (our settings are under
`.local/share/duckstation`). A token it cannot decrypt makes it ask for a login. Our machine-id is
made on the device at first boot and kept across OTA updates, so the launcher computes it on the
device at each launch (`openssl enc -aes-128-cbc -nopad`, token on stdin; the key is derived from
world-readable data anyway: obfuscation, not secrecy).

## Decisions (agreed 2026-11-13)

- **D1 One sign-in, the one we have.** `retroforge-cheevos` and RetroArch's `retroarch.cfg`
  (`cheevos_username`, `cheevos_token`, `cheevos_hardcore_mode_enable`) stay the only place the
  sign-in lives. A sign-in or sign-out made in RetroArch's own menu counts too (same file).
- **D2 Written at launch, by the launcher.** Before each start of one of the five (game or Open),
  `retroforge-launch` writes the name, token, enabled flag and hardcore into that emulator's files,
  after the first-run seed (a file made first would keep the seed out for good). The emulator is
  not running then, so its own write-back on exit cannot undo it (why `retroforge-cheevos` refuses
  while RetroArch runs). Stays written, like an emulator-level option: no restore journal.
- **D3 RetroForge owns the sign-in.** Signed out in RetroForge: an empty name and token, achievements
  off, PPSSPP's token file removed. A sign-in or sign-out made in an emulator's own menu is replaced
  at its next launch. (Existing devices: a player who signed in only inside DuckStation/PPSSPP/...
  is signed out there at the first launch after the update, until they sign in in Settings.)
- **D4 One hardcore toggle, always written.** RetroForge's Hardcore row (default off, RetroArch plan
  D3) is written every launch, signed in or not: Dolphin and PPSSPP default to hardcore ON, which
  would block the Guide+L1 load-state hotkey.
- **D5 Data, not code, per emulator.** emulator.json gets an `achievements` list shaped like
  `system_settings` (file, format, separator, set), with placeholders `{user}`, `{token}`,
  `{duckstation_token}`, `{enabled}`, `{hardcore}`, the boolean words per entry (`"bool": ["True",
  "False"]`), and one extra format `secret` (the whole file = the value, removed when empty) for
  PPSSPP. A file that cannot be written is a warning, never a blocked game.
- **D6 Token files 0600.** Every file the launcher writes a non-empty token into is chmod 0600 before
  the token goes in (the emulators may rewrite them 0644 at exit: re-tightened at the next launch,
  HW check below).

## Phase 1 — launcher + definitions (offline)

- `lib/retroforge/python/achievements.py`: read the sign-in from `retroarch.cfg`; validate a
  definition's `achievements` entries; apply them (placeholders, booleans, `secret` format, 0600,
  DuckStation encryption via openssl); warnings only.
- `launch_def.py`: `achievements` key, validated; `retroforge-launch`: apply after
  `seed_first_run`, for games and `--gui`.
- emulator.json rows for duckstation, armsx2, ppsspp, dolphin, flycast; notes line each.
- Tests: new `tests/test-achievements.sh` (in `make test`): each real definition against a sandbox
  $HOME — signed in / signed out / hardcore on/off, seed kept, 0600, PPSSPP file removed on sign-out,
  DuckStation token decrypts back (openssl) with a fake machine-id, a bad definition refused, an
  unwritable file only warns; `test-launch.sh` still green.
- `retroforge-cheevos` header + plugin wording (cheevos_settings.gd / cheevos_text.gd: the systems
  list), plugin version bump, test-plugin.sh strings.
- Security review (token handling, file modes, argv) before commit.

## Phase 2 — HW (dev card)

1. Sign in in Settings; start one game per emulator: each shows its own "logged in as" toast.
2. DuckStation: the token decrypts (no login prompt) — proves the machine-id newline / key details.
3. ARMSX2 2.9 and the pkgforge Dolphin are built with achievements (menu shows them).
4. Hardcore off: Guide+L1 loads a state in each; Hardcore on: refused, the emulator says hardcore.
5. Sign out in Settings: each emulator starts signed out, PPSSPP's `.dat` gone.
6. Modes after each emulator exits: the token files' mode (0644 after exit = acceptable only because
   the next launch re-tightens; note which ones).
7. One unlock in one standalone (softcore), seen on retroachievements.org.
