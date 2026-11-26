# Emulators follow upstream's newest release — plan

Status: decisions D1-D7 + Phase 4 AGREED 2026-10-16 (branch plan/emulator-latest). Phase 1
(retroforge-emu) DONE 2026-10-17, offline tests + a live `check` of rpcs3/duckstation/armsx2/xemu/cemu;
D4 corrected (prerelease flag is not a filter, newest by published_at). Phase 2 (plugin) DONE
2026-10-17 offline (emu_state.gd tests in Godot 4.7.1; page compile-checked against OGUI stubs), not on
HW. Phase 3 (catalog) DONE 2026-10-17: every entry has a tag_pattern, verified live
(`RETROFORGE_NET_TEST=1 tests/test-catalog.sh`, 246 ok); `channel` removed from catalog and
retroforge-emu. Phase 4 (key drift) DONE 2026-10-17: .github/workflows/emu-key-drift.yml (weekly) +
.github/emu-key-drift.py + .github/emu-sources.json, tests/test-key-drift.sh; first local run over
all 13 newest sources: 0 missing after composed-key rules (digits, '/' segments, printf formats).
Issue title = emulator + missing keys (not the build: RPCS3 builds per commit). Next: the HW gate.

## Why, and what it reverses

Today every emulator but Cemu installs ONE pinned tag from `catalog.json` (tag + sha256 + size),
and a new version reaches players only when we bump the pin and ship the catalog in an image or OTA.
Thirteen pins, several of them on upstreams that release weekly or per commit, is a maintenance
cost that is not buying much: we HW-test a handful of them per bump at best.

This REVERSES a decision in retroforge.plan.md (Phase 4, item 4, decided 2026-10-03): "No 'newest'
mode (armada follows upstream's newest; an upstream change could break a seed or the launch args
unnoticed)". That risk is real and this plan keeps it visible rather than pretending it away: the
pin survives as the TESTED marker, the player sees when they run something newer, and going back
is one button.

It also DROPS the hosted catalog (retroforge.plan.md Phase 4/5, never built): with "latest" as the
default, a hosted catalog would only move tested markers, and the image + OTA already carry the
catalog (D7).

## Decisions (agreed 2026-10-16)

- **D1 Default = latest.** Download and Update install the newest upstream release whose asset
  matches; the pinned build is no longer what a player gets by default.
- **D2 The pin stays, as "tested".** `tag` + `sha256` + `size` keep their meaning: the build
  RetroForge checked. The page labels the installed build Tested / Newer than tested, and offers
  "Install tested version" whenever it is not the installed one.
- **D3 One-press rollback.** `activate()` already keeps the previous AppImage; the page offers
  "Revert to <previous>" when one is on disk.
- **D4 "Newest release" is per-emulator, by tag pattern, never by date alone.** Drafts are
  skipped; a release counts only when its tag matches the entry's `tag_pattern` AND exactly one
  asset matches `asset`. Rolling tags that replace their asset in place (DuckStation's `latest`)
  never match. CORRECTED 2026-10-17 (live API): the prerelease flag is NOT a filter -- Cemu's
  `nightly` and every ARMSX2 nightly carry it, so skipping it would leave both with nothing; the
  pattern alone decides (DuckStation `preview`, xemu `pre-release` are kept out by theirs). And
  "newest" = by `published_at` over `/releases/latest` + the first page of `/releases`: RPCS3's
  list is sorted by tag name (every release has the same `created_at`), its newest build is only
  in `/releases/latest`.
- **D5 Cemu's nightly channel folds into this.** Same code path, `tag_pattern: ^nightly$`; its
  `nightly-<id>` naming stays.
- **D6 PortMaster: latest FIRST install, then it updates itself.** The first install takes the
  newest release (not the pin); after that PortMaster's own updater runs as today, and
  retroforge-emu never offers it an update. The unpack check "version file == pinned tag" becomes
  "version file == the tag being installed".
- **D7 No online catalog.** The only catalog is `/usr/share/retroforge/catalog.json` in the
  image; an OTA bundle is how tested pins and tag patterns change on a device. retroforge-emu stops
  reading `~/.cache/retroforge/catalog.json`, and the plugin never fetches a catalog. The
  `$RETROFORGE_CATALOG` override stays (test seam).

## Risks this plan accepts, and what it does about each

| Risk | Visible? | Mitigation in this plan |
|---|---|---|
| Config key renamed upstream: our seed/options silently ignored | NO | Phase 4 key-drift check in CI against the newest upstream source; "Newer than tested" label explains "my option does nothing" |
| A launch workaround breaks (sigdefer for Snes9x, SDL_NO_SIGNAL_HANDLERS Exit, melonDS/Azahar dual-screen layout) | at launch | Revert button; the HW gate per tested-pin bump stays |
| Broken build (ARMSX2/RPCS3 nightlies) | at launch | Revert button |
| No arm64 asset in the newest release / asset renamed | loud (exit 4) | "newest" = newest release WITH exactly one matching asset; a rename fails the check, never installs |
| Untrusted bytes (8/13 come from pkgforge-dev, a third-party repackager) | no | GitHub per-asset sha256 digest REQUIRED (exit 4 without), https-only, as the nightly path does today. Same trust as Cemu now; no human vetting of a given build |
| "Which version are you on?" for bug reports | — | the installed tag is in `retroforge-emu list` and on the page |
| GitHub API rate limit (60/h unauthenticated, per IP) | — | `check` caches for 1 h; a failed check never reads as "up to date" |

## Phase 1 — retroforge-emu

Catalog source (D7): `CATALOGS` becomes `$RETROFORGE_CATALOG`, else the image's file; the
`~/.cache/retroforge/catalog.json` entry and the header's "hosted catalog" wording go.

Catalog (schema stays 1; all additions optional, so an entry without them keeps working off the pin):
- `tag_pattern`: anchored regex over release tags. Present = the entry follows latest (D1); absent
  = pinned-only, today's behaviour (kept as a per-entry escape hatch; no entry uses it after
  Phase 3).
- `asset` becomes version-agnostic (today most embed the version, e.g.
  `^Azahar-2126\.1\.2-anylinux-aarch64\.AppImage$` → `^Azahar-[0-9.]+-anylinux-aarch64\.AppImage$`).
  The pinned tag must still match exactly one asset (test-catalog.sh).
- `channel` is dropped once Cemu moves to `tag_pattern` (D5); `version_text()` keeps reading
  `nightly-<id>`.

Commands:
- `retroforge-emu check [<emu>]` → JSON on stdout per emulator: `{"latest": tag|null,
  "error": str|null}` (a pinned-only entry: its pin, no network). `GET .../releases/latest` (a 404
  is fine) + `GET .../releases?per_page=30` per emulator, sorted by `published_at`, first release
  that is not a draft, matches `tag_pattern`, and has exactly one asset matching `asset` (D4).
  Cached in `~/.cache/retroforge/emu-check.json` for 1 h, keyed by github+tag_pattern+asset (an
  OTA catalog change asks again); `--refresh` bypasses; failures are not cached; exit 0 always
  (a rate limit is that emulator's `error`).
- `retroforge-emu install <emu> [--tested]` → latest by default when the entry has `tag_pattern`;
  `--tested` installs the pin with today's digest+size-equal-to-catalog check. A latest install
  requires GitHub's `sha256:` digest and checks the bytes against it (the nightly path's code).
  Same tag as `current`: nothing downloaded, stderr "already the latest".
- `retroforge-emu rollback <emu>` → flip `current` to the kept previous AppImage (exit 2 if none).
  After a rollback the "previous" is the build we left, so Revert toggles between the two.
- `list` grows `tested` (= the pin), `previous` (tag of the kept AppImage or null) and
  `follows_latest` (bool). `update` stays offline-only and means "installed != tested and the
  entry is pinned-only"; for latest entries the page asks `check`.

Tests (`tests/test-emu.sh`, fake curl serving a releases list): draft skipped, prerelease kept; tag
not matching skipped; release with 0 or 2 matching assets skipped (not an error unless none
qualifies); missing digest → exit 4; `--tested` path unchanged; rollback toggles; check cache
honoured and `--refresh` bypasses it; a failed check is reported as `error`, never as "current".

## Phase 2 — plugin (emulators_page.gd)

Main row, installed:
- `Version X · Tested` when installed == tested.
- `Version X · Newer than RetroForge tested (Y)` otherwise; description says it came straight
  from upstream.
- Update button when `check` says latest != installed ("Update to Z, ~N MB").

Extra rows, before Delete:
- `Revert to <previous>` when `previous` is set.
- `Install tested version (Y)` when installed != tested.

`check` runs ONLY when the player presses "Check for a newer version" (changed 2026-10-17 on HW:
the unauthenticated 60 requests/hour per IP ran out; an automatic check on list focus spent 2 per
emulator scrolled past). It says what it found; an Update replaces Open when there is a newer build.
A used-up rate limit is retroforge-emu exit 6, shown as GitHub's limit with the wait, never as
"check the network connection". Credits keep showing the installed tag.

## Phase 3 — catalog migration

Per entry: `tag_pattern` + version-agnostic `asset`, pins untouched. Every pattern below must be
verified against the live releases list before it lands (`RETROFORGE_NET_TEST=1
tests/test-catalog.sh` gains a "latest resolves to exactly one asset" check):

| Emulator | tag_pattern (verified live 2026-10-17) | note |
|---|---|---|
| armgba | `^v[0-9]+(\.[0-9]+)+$` | upstream's own AppImage (replaced mGBA 2026-10-25); v0.1 has no AppImage asset, so the asset pattern keeps it out |
| armsx2 | `^[0-9]+(\.[0-9]+)+$` | stable since 2.9 (2026-10-26, its first stable Linux AppImage; nightlies before); asset must stay the 4K-pages build |
| azahar, clownmdemu, dolphin, flycast, melonds, snes9x | `^[0-9][0-9.]*(-[0-9]+)?@[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]+$` | pkgforge-dev `<ver>@<date>_<id>`; Azahar's repo also has a `nightly` (prerelease) tag, kept out by the pattern |
| cemu | `^nightly$` | replaces `channel` |
| duckstation | `^latest$` | was `^v0\.1-[0-9]+$`; 2026-11-26 upstream dropped the Linux AppImages from every numbered release, so no tested build, as Cemu |
| ppsspp | `^v[0-9]+\.[0-9]+(\.[0-9]+)?$` | |
| rpcs3 | `^build-[0-9a-f]{40}$` | a build per upstream commit |
| xemu | `^v[0-9]+\.[0-9]+\.[0-9]+$` | |
| portmaster | `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{4}$` | D6: first install only, `self_update` stays |

## Phase 4 — CI (agreed: in this plan; it is what covers the invisible risk)

- **Key drift**: a weekly job resolves each emulator's latest tag, shallow-clones that tag of
  the UPSTREAM source (not the pkgforge repackage), and greps every key our seeds and
  `options.json` write. A key that disappeared files ONE issue (title = emulator + tag, the
  upstream-watch dedupe) naming the key and the file. This is the only check for risk 1.
- **Tested-pin bump PR** (later, maybe): moves `tag`/`sha256`/`size` to a newer build once it has
  been HW-checked; until then pins move by hand as today.

## HW gate before merge

On one board per GPU generation: fresh install of every emulator through the page (latest),
launch + Exit each; Revert and Install tested on two of them; an offline open of the Emulators
screen shows no Update and no error.
