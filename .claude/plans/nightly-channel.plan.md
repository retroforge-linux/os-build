# Plan: nightly OTA channel

**Complexity**: Medium. **Branch**: `feat/nightly-channel`. **Status**: AGREED 2026-11-12 (D1-D6). Phase 1 pushed (66b58240), smoke run pending. Phase 2 done offline (renew-nightly-cert 321a3770, nightly-bundle.yml 94e71c56; nightly-signing env created 2026-11-12, nightly cert uploaded, R2 secrets pending from the Cloudflare account owner). Phase 3 done offline (plugin 0.1.112); HW check pending. One version field YYYYMMDDHHMM, not .YYYYMMDD.HHMM (semver: no leading zero in a numeric field).

## Summary

Devices get updates from `https://ota.retroforge.org/<channel>/latest.json`. Today the channels are
`stable` and `beta`, and both are published by `release-bundle.yml` on an `ota/v*` tag, behind a
reviewer in the `release-signing` environment. This plan adds a third channel, **nightly**. A
scheduled workflow builds a release (not dev) rootfs from `main`, signs it with its own short-lived
nightly cert and publishes it to `nightly/` with **no approval**. Settings > General > Updates offers
Nightly next to Stable and Beta.

## Decisions

| | Decision |
|---|---|
| D1 | **Separate nightly signing cert, 90 days**, minted from the root CA (kept in the private `retroforge-linux/secrets` repo) with the same `ota/rauc/release.ext` profile. It lives only in a new **`nightly-signing`** environment: no reviewers, deployment branch `main` only. That environment also holds copies of the R2 secrets and variables. Devices trust the CA, so a nightly-signed bundle installs on any device. That can't be avoided with one keyring, so the short lifetime limits a leaked key to 90 days: rauc checks the signer's validity at install time (`system.conf` has no `use-bundle-signing-time`). The release cert and `release-signing` stay as they are. |
| D1a | **Renewal = `make renew-nightly-cert`, run by hand** (`ota/renew-nightly-cert.sh`). Who can renew = who can read the private `retroforge-linux/secrets` repo: by default the script fetches only `retroforge-pki/ca.cert.pem` + `ca.key.pem` from it with the caller's own `gh` login into a `umask 077` tempdir (`PKIDIR=` uses a local copy instead). No workflow does this, so the root CA key never reaches a CI runner (agreed 2026-11-12). Then: (1) refuses unless that CA has the committed `ota/rauc/retroforge-ca.pem`'s fingerprint; (2) mints a NEW RSA-4096 key + cert every time, CN `retroforge OTA nightly`, random 128-bit serial (the CA is only read, nothing to commit back), `NIGHTLY_DAYS` default 90, `-extfile ota/rauc/release.ext`, verified against the keyring; (3) `gh secret set RAUC_NIGHTLY_KEY_PEM` then `RAUC_NIGHTLY_CERT_PEM --env nightly-signing` from stdin, never argv; (4) shreds the tempdir: the new key and the fetched CA key. Nothing is committed. |
| D1b | **Expiry handling in CI**: 14 days before expiry the nightly run opens or updates ONE issue ("nightly signing cert expires on YYYY-MM-DD -- run `make renew-nightly-cert`"), following `upstream-watch.yml`'s pattern. An expired cert stops the run **before signing**, with the same message. |
| D1c | **Leak response**: delete the `nightly-signing` cert/key secrets, renew, and the leaked cert dies at its expiry (≤ 90 days). Devices check no CRL. |
| D2 | **Version `X.Y.(Z+1)-nightly.YYYYMMDD.HHMM`** (UTC), from the last stable `ota/vX.Y.Z` tag, e.g. `0.0.8-nightly.20261112.0230`. Unique per run, as `publish-bundle.sh`'s never-overwrite rule requires, and it tells the user which channel they are on. The sha travels in `latest.json`'s `git`. An `ota/` tag carrying `-nightly` is REFUSED by `release-bundle.yml`'s prep, because today it would route to beta. |
| D3 | **Daily cron (~02:30 UTC) + `workflow_dispatch`.** Skip when `main`'s HEAD equals `git` in the public `nightly/latest.json`, or when `ci.yml` did not pass on that sha. EXCEPT: rebuild anyway when the published nightly is **more than 30 days old**, so the bundle on offer is always signed by a live cert (D1). A dispatch can force a build past both skips. |
| D4 | **No GitHub Release per nightly.** The commit list since the previous nightly goes into the run's step summary. |
| D5 | **Nightly is an ordinary dropdown entry**, no confirmation, like Beta. While it is selected the section's description says "Daily untested builds". The internal installer may install from Nightly too (the user's choice). |
| D6 | **Nightly is exempt from "every published bundle gets a hardware install first"**, and that is written into `docs/ota.md` and `docs/RUNBOOK.md`. Stable and beta keep the rule. |

## Patterns to Mirror

| Category | Source | Pattern |
|---|---|---|
| Reusable workflow with its own environment | `.github/workflows/image.yml:86-145` | `environment` input declared on the callee's job; a caller cannot attach one from outside |
| Channel from version, fail closed on empty channel | `.github/workflows/release-bundle.yml` prep + publish step | `case "$v"`; `[ -n "$RETROFORGE_OTA_CHANNEL" ] \|\| exit 1` |
| Credentials checked before any work | `release-bundle.yml` "check for publishing credentials" | list missing names, `::error::`, exit 1 |
| Scheduled workflow that files one issue | `.github/workflows/upstream-watch.yml` | `issues: write`, one label, update rather than duplicate |
| Cert minting | `ota/gen-signing-ca.sh` | reads `release.ext`, refuses to write keys inside the repo, `umask 077`, `openssl verify` |
| Channel list + tests | `rootfs/overlay/usr/bin/retroforge-update:110-114`, `tests/test-update.sh` | `OFFERED_CHANNELS`; tests exec the shipped file through env seams |
| Plugin channel names + tests | `apps/ogui-retroforge-plugin/plugin/update_states.gd:11`, `tests/test-plugin.sh:505` | `CHANNEL_NAMES`; `parse_channels` checks |

## Files to Change

| File | Action | Why |
|---|---|---|
| `.github/workflows/sign-publish-bundle.yml` | CREATE | `release-bundle.yml`'s `release` job moved verbatim into a `workflow_call` (inputs: `channel`, `environment`, `publish`, cert secret names) |
| `.github/workflows/release-bundle.yml` | UPDATE | `release` calls the reusable workflow; prep refuses `-nightly` |
| `.github/workflows/nightly-bundle.yml` | CREATE | schedule + dispatch; prep (D2/D3), build (`image.yml` rootfs), cert expiry check + issue (D1b), sign+publish to `nightly` |
| `ota/renew-nightly-cert.sh` | CREATE | D1a |
| `Makefile` | UPDATE | `renew-nightly-cert` target |
| `rootfs/overlay/usr/bin/retroforge-update` | UPDATE | `OFFERED_CHANNELS += nightly`, comment at :110 |
| `apps/ogui-retroforge-plugin/plugin/update_states.gd` | UPDATE | `"nightly": "Nightly"` + D5 description; plugin version bump |
| `apps/ogui-retroforge-plugin/plugin/retroforge_os.gd` | UPDATE | show the D5 description when nightly is selected (if it is not driven from `update_states.gd`) |
| `tests/test-update.sh`, `tests/test-plugin.sh` | UPDATE | nightly in `channels`, `set-channel nightly`, `parse_channels` |
| `tests/test-renew-nightly-cert.sh` | CREATE | throwaway CA, `gh` stubbed (secret set + api contents): wrong-CA refusal, profile (EKU codeSigning, CA:FALSE), 90 d, keys shredded, fetch from the secrets repo, no access |
| `docs/ota.md` | UPDATE | channel list, layout, "Nightly" section (D1-D6), "Nightly signing cert" renewal procedure |
| `docs/RUNBOOK.md` | UPDATE | release section: nightly is automatic and HW-test-exempt |
| `docs/ci.md` | UPDATE | if it lists workflows / environments |

## Tasks

### Phase 1: extract sign+publish (no behaviour change)
1. Move `release-bundle.yml`'s `release` job into `sign-publish-bundle.yml` unchanged, with the tag-only expressions turned into inputs (`publish`, `environment`). Keep every comment that explains a gate.
2. `release-bundle.yml`: `release` calls the reusable workflow with `channel: needs.prep.outputs.channel`; prep refuses `*-nightly*`.
3. **Validate**: `actionlint` (if available); a `workflow_dispatch` smoke run must produce a dev-signed bundle and no publish; the next real `ota/v*` tag behaves as before (approval, publish, notes).

### Phase 2: nightly signing + workflow
4. `ota/renew-nightly-cert.sh` + `make renew-nightly-cert` + `tests/test-renew-nightly-cert.sh` (D1a).
5. **User, in GitHub settings**: create the `nightly-signing` environment (no reviewers, deployment branch `main`); copy `CLOUDFLARE_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` and the `R2_BUCKET` / `R2_PUBLIC_BASE` variables into it; run `make renew-nightly-cert` once (needs read access to `retroforge-linux/secrets`).
6. `nightly-bundle.yml`: `concurrency: nightly-bundle` (cancel in progress); prep computes D2's version and D3's skip (curl `nightly/latest.json`, `gh api` check-runs for `ci.yml` on HEAD, 30-day age); build via `image.yml` (`artifact: rootfs`, `environment: ''`); release via `sign-publish-bundle.yml` (`channel: nightly`, `environment: nightly-signing`, nightly cert secrets); cert-expiry step (D1b) before signing; commit list to the step summary (D4).
7. **Validate**: a dispatch publishes `nightly/latest.json`; `curl https://ota.retroforge.org/nightly/latest.json`; on a device `RETROFORGE_OTA_CHANNEL=nightly retroforge-update check` offers it; a second dispatch with no new commit is skipped; a forced one publishes a new version.

### Phase 3: device side
8. `retroforge-update` `OFFERED_CHANNELS`, plugin `CHANNEL_NAMES` + D5 description, plugin version bump, tests.
9. Docs (`docs/ota.md`, `docs/RUNBOOK.md`, `docs/ci.md`).
10. **Validate**: `tests/test-update.sh`, `tests/test-plugin.sh` (Godot suites with `QEMU_LD_PREFIX=work/base RETROFORGE_GODOT=...`), `tests/test-publish-bundle.sh`.
11. **HW (Pocket ACE)**: Updates shows Nightly; select it -> description shown, Check offers the nightly, Install, Restart boots it; switch to Stable -> the older stable version is offered.

Devices only get the Nightly entry with the next **stable** OTA. Before that, `retroforge-update set-channel nightly` over SSH reaches it.

## Validation

```sh
tests/test-update.sh
tests/test-plugin.sh
tests/test-publish-bundle.sh
tests/test-renew-nightly-cert.sh
actionlint .github/workflows/*.yml   # if installed
```

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Nightly key signs bundles stable devices also accept (one keyring, no per-channel signer check) | Low, HIGH impact | D1 90-day cert; environment deployable from `main` only; fork PRs get no secrets |
| Nightly environment's R2 token can write the whole bucket, `stable/latest.json` included (R2 tokens are not prefix-scoped) | Low | channel hard-coded in `nightly-bundle.yml`; empty channel refused; a separate bucket would need a Worker, deferred |
| Published nightly stops installing when its cert expires | Medium | D3 30-day rebuild + D1b 14-day issue |
| Broken nightly black-screens a device (~6 power cycles to roll back) | Medium | opt-in channel with D5 wording; D3 requires green `ci.yml` |
| Nightly -> stable is a downgrade with `/home` state migrated forward | Low | same as beta today; documented |
| R2 storage: 3 bundles x 3 channels x ~530 MiB ≈ 4.7 GiB of the 10 GB free tier | Low | `RETROFORGE_OTA_KEEP=3` |
| ~64 min of runner per night | Low | free on a public repo; D3 skip |

## Acceptance

- [ ] An `ota/v*` tag still asks for one approval and publishes exactly as before
- [ ] A scheduled run publishes `nightly/` with no approval, signed by the nightly cert
- [ ] Unchanged `main` is skipped; a 30-day-old nightly is rebuilt
- [ ] Cert expiring in 14 days opens one issue; an expired cert stops the run before signing
- [ ] `make renew-nightly-cert` refuses a wrong CA, uploads, and leaves no local nightly key
- [ ] Nightly selectable in Settings > General > Updates, HW-OK on the Pocket ACE
- [ ] `docs/ota.md` and `docs/RUNBOOK.md` describe the channel, the exemption and the renewal
