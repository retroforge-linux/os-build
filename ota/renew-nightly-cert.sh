#!/usr/bin/env bash
# retroforge nightly signing cert — mint a fresh 90-day one under the offline root CA and hand it to
# the `nightly-signing` GitHub environment, where nightly-bundle.yml signs with it.
#
#   make renew-nightly-cert                            # the CA from the secrets repo, via your gh login
#   PKIDIR=~/retroforge-pki make renew-nightly-cert    # or from a local copy of it
#
# WHO CAN RENEW is whoever can read the private retroforge-linux/secrets repo (SECRETS_REPO), and
# that repo's access list is the control: by default the root CA is fetched from it with the caller's
# own `gh` login, used, and shredded with the tempdir — it is not kept on the machine, and it never
# reaches a CI runner (there is deliberately no workflow doing this; plan nightly-channel D1a). Only
# ca.cert.pem and ca.key.pem are fetched, not the rest of the repo.
#
# WHY A SEPARATE, SHORT CERT (plan nightly-channel D1). Nightly bundles are signed and published with
# no reviewer, and devices trust the CA rather than a cert, so a nightly-signed bundle installs on a
# stable device as readily as a release one: one keyring has no per-channel signer check. What a
# short lifetime buys is a bound on a leak. rauc checks the signer's validity at INSTALL time
# (system.conf sets no use-bundle-signing-time), so a leaked nightly key is useless after its expiry,
# at most NIGHTLY_DAYS away, without touching a device. The release cert (~2 years) never enters the
# unreviewed environment.
#
# The same property is why a nightly cert must be renewed before it expires: the bundle on offer
# stops installing the day its signer does. nightly-bundle.yml opens an issue 14 days ahead, stops
# before signing once it has expired, and rebuilds a nightly older than 30 days so the bundle on offer
# is always signed by a live cert.
#
# WHAT IT DOES, IN ORDER, and every step fails closed:
#   0. fetches ca.cert.pem + ca.key.pem from SECRETS_REPO into a private tempdir (umask 077), unless
#      PKIDIR names a local copy.
#   1. checks that the CA IS the one every device trusts (the committed ota/rauc/retroforge-ca.pem).
#      A cert minted under any other CA is refused by every device. The CA is only read, wherever it
#      came from; nothing is written back to SECRETS_REPO or PKIDIR (bar a public nightly.cert.pem).
#   2. mints a NEW key and cert every time, in a private tempdir, with the release profile
#      (ota/rauc/release.ext: codeSigning only, CA:FALSE), and verifies the cert against the
#      committed keyring.
#   3. uploads both to the environment with `gh secret set ... < file`: the key goes through stdin,
#      never argv, so it never shows in `ps` or the shell history.
#   4. shreds the tempdir — the new key and, when fetched, the root CA key with it. The nightly
#      key's only copy is then GitHub's; the next renewal mints a new pair. With a local PKIDIR the
#      public cert is copied to $PKIDIR/nightly.cert.pem so its expiry can be read offline.
#
# Nothing is committed: unlike the release cert, the nightly one changes every 90 days and lives in
# the environment only.
#
# Seams (tests/test-renew-nightly-cert.sh): KEYRING, GH (the gh command), SECRETS_REPO,
# SECRETS_REF, TARGET_REPO, NIGHTLY_ENV, NIGHTLY_DAYS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKIDIR="${PKIDIR:-}"
KEYRING="${KEYRING:-$ROOT/ota/rauc/retroforge-ca.pem}"
RELEASE_EXT="$ROOT/ota/rauc/release.ext"
NIGHTLY_ENV="${NIGHTLY_ENV:-nightly-signing}"
NIGHTLY_DAYS="${NIGHTLY_DAYS:-90}"
GH="${GH:-gh}"
SECRETS_REPO="${SECRETS_REPO:-retroforge-linux/secrets}"
# Named, never inferred: with more than one git remote (a fork, an upstream) gh refuses to guess, and
# a guess that went the wrong way would put a signing key in someone else's repo.
TARGET_REPO="${TARGET_REPO:-retroforge-linux/os-build}"
SECRETS_REF="${SECRETS_REF:-main}"
SECRETS_PATH=retroforge-pki
ORG="${ORG:-retroforge}"
# Distinct from release-signing's RAUC_CERT_PEM/RAUC_KEY_PEM on purpose: a `gh secret set` aimed at
# the wrong environment then adds a stray secret instead of replacing the release cert.
CERT_SECRET=RAUC_NIGHTLY_CERT_PEM
KEY_SECRET=RAUC_NIGHTLY_KEY_PEM

die() { printf '[nightly-cert] %s\n' "$*" >&2; exit 1; }
log() { printf '[nightly-cert] %s\n' "$*" >&2; }
fpr() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }

command -v openssl >/dev/null 2>&1 || die "openssl not found"
command -v "$GH" >/dev/null 2>&1 || die "'$GH' not found: the GitHub CLI uploads the cert to the $NIGHTLY_ENV environment"
case "$NIGHTLY_DAYS" in
  ''|*[!0-9]*|0) die "NIGHTLY_DAYS must be a positive whole number, got '$NIGHTLY_DAYS'" ;;
esac
# An absent or empty profile does not fail openssl loudly: it mints a cert with no extensions, which
# RAUC's check-purpose=codesign then refuses on every device (gen-signing-ca.sh has the same guard).
[ -s "$RELEASE_EXT" ] || die "missing or empty cert profile: $RELEASE_EXT"
[ -s "$KEYRING" ]     || die "missing device keyring: $KEYRING"

# Everything private — the fetched root CA, the new key — lives here and is shredded on any exit.
umask 077
work="$(mktemp -d)"
cleanup() {
  if command -v shred >/dev/null 2>&1; then
    find "$work" -type f -exec shred -u {} + 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# --- 0. the root CA: SECRETS_REPO by default, a local PKIDIR if given ----------------------------
if [ -n "$PKIDIR" ]; then
  CADIR="$PKIDIR"
  CA_FROM="$PKIDIR"
else
  CADIR="$work/ca"
  CA_FROM="$SECRETS_REPO@$SECRETS_REF:$SECRETS_PATH"
  mkdir "$CADIR"
  log "fetching the root CA from $CA_FROM with your gh login"
  for f in ca.cert.pem ca.key.pem; do
    # The raw media type returns the file's bytes; they go to a file under $work, never to argv.
    "$GH" api -H "Accept: application/vnd.github.raw+json" \
      "repos/$SECRETS_REPO/contents/$SECRETS_PATH/$f?ref=$SECRETS_REF" >"$CADIR/$f" 2>"$work/gh.err" \
      || die "cannot read $SECRETS_PATH/$f from $SECRETS_REPO ($(head -c 200 "$work/gh.err")).
  Renewing needs read access to that private repo (and \`gh auth login\`), or PKIDIR= a local copy."
  done
fi
for f in ca.cert.pem ca.key.pem; do
  [ -s "$CADIR/$f" ] || die "no $f in $CA_FROM — it must hold the root CA"
done

# --- 1. the CA is the one devices trust ----------------------------------------------------------
have="$(fpr "$CADIR/ca.cert.pem" 2>/dev/null || true)"
want="$(fpr "$KEYRING")"
[ -n "$have" ] && [ "$have" = "$want" ] || die "REFUSED: ca.cert.pem from $CA_FROM is not the device keyring's CA.
  CA      ${have:-<not a certificate>}
  keyring $want   (${KEYRING#"$ROOT"/})
  A nightly cert minted under it would be refused by every device."

# --- 2. a new key and cert -----------------------------------------------------------------------
log "minting a ${NIGHTLY_DAYS}-day nightly signing cert (RSA-4096) under the CA from $CA_FROM"
openssl req -newkey rsa:4096 -nodes -sha256 \
  -keyout "$work/nightly.key.pem" -out "$work/nightly.csr.pem" \
  -subj "/O=$ORG/CN=$ORG OTA nightly" >/dev/null 2>&1 || die "openssl req failed"
# A random 128-bit serial rather than ca.cert.srl's counter: the CA is then only READ, so a renewal
# from SECRETS_REPO has nothing to commit back.
openssl x509 -req -in "$work/nightly.csr.pem" \
  -CA "$CADIR/ca.cert.pem" -CAkey "$CADIR/ca.key.pem" \
  -set_serial "0x$(openssl rand -hex 16)" \
  -days "$NIGHTLY_DAYS" -sha256 -extfile "$RELEASE_EXT" \
  -out "$work/nightly.cert.pem" >/dev/null 2>&1 || die "signing the nightly cert with ca.key.pem from $CA_FROM failed"

# Against the COMMITTED keyring, not PKIDIR's copy: that is the CA devices actually carry, and it
# also proves ca.key.pem belongs to it (a mismatched key signs a cert that does not verify).
openssl verify -CAfile "$KEYRING" -purpose any "$work/nightly.cert.pem" >/dev/null 2>&1 \
  || die "the new cert does not verify against ${KEYRING#"$ROOT"/} — is ca.key.pem in $CA_FROM the CA's key?"
openssl x509 -in "$work/nightly.cert.pem" -noout -text | grep -q "Code Signing" \
  || die "the new cert carries no codeSigning EKU — devices (check-purpose=codesign) would refuse it"

# --- 3. into the environment ---------------------------------------------------------------------
# Key first: if the second upload fails, the environment holds a new key and the OLD cert, which
# fails signing loudly (rauc refuses a mismatched pair) rather than signing with anything stale.
log "uploading $KEY_SECRET and $CERT_SECRET to $TARGET_REPO's '$NIGHTLY_ENV' environment"
"$GH" secret set "$KEY_SECRET" --env "$NIGHTLY_ENV" --repo "$TARGET_REPO" <"$work/nightly.key.pem" 2>"$work/gh.err" \
  || die "gh secret set $KEY_SECRET failed: $(head -c 300 "$work/gh.err")
  Nothing was changed. The '$NIGHTLY_ENV' environment must exist in $TARGET_REPO and your gh login needs admin there."
"$GH" secret set "$CERT_SECRET" --env "$NIGHTLY_ENV" --repo "$TARGET_REPO" <"$work/nightly.cert.pem" 2>"$work/gh.err" \
  || die "gh secret set $CERT_SECRET failed AFTER the key was replaced: $(head -c 300 "$work/gh.err")
  The environment now holds a mismatched pair and nightly signing will fail until this script is run again."

# --- 4. keep the public half, destroy the key ----------------------------------------------------
[ -z "$PKIDIR" ] || install -m0644 "$work/nightly.cert.pem" "$PKIDIR/nightly.cert.pem"
end="$(openssl x509 -in "$work/nightly.cert.pem" -noout -enddate | cut -d= -f2)"
serial="$(openssl x509 -in "$work/nightly.cert.pem" -noout -serial | cut -d= -f2)"
cat <<EOF

  ok   nightly signing cert  serial $serial
       expires               $end
       uploaded to           $TARGET_REPO, environment $NIGHTLY_ENV ($KEY_SECRET, $CERT_SECRET)
       root CA from          $CA_FROM${PKIDIR:+ (public cert copied to $PKIDIR/nightly.cert.pem)}
       private keys          shredded here; GitHub holds the only nightly key

  Renew before it expires: nightly-bundle.yml opens an issue 14 days ahead.
EOF
