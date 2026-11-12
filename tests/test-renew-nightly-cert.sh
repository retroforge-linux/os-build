#!/usr/bin/env bash
# Offline test for ota/renew-nightly-cert.sh: the 90-day cert nightly-bundle.yml signs with.
#
#   tests/test-renew-nightly-cert.sh
#
# WHY THIS EXISTS. The script runs once every 90 days, on a workstation, against the offline root
# CA, and each way it can go wrong shows up only later and somewhere else: a cert under the wrong CA
# or without the codeSigning EKU is refused by every device on the nightly channel; a key that
# reached argv or stayed on disk has leaked; a failed upload that is not loud leaves the environment
# signing with a cert that is about to expire. So most cases here must go RED.
#
# Real openssl against a throwaway CA; `gh` is a stub that records its arguments and stdin.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RENEW="$ROOT/ota/renew-nightly-cert.sh"
[ -f "$RENEW" ] || { echo "missing: $RENEW" >&2; exit 1; }
command -v openssl >/dev/null || { echo "needs openssl" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# A CA shaped like gen-signing-ca.sh's (pathlen 0, keyCertSign) in $1.
mkca() {
  mkdir -p "$1"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
    -keyout "$1/ca.key.pem" -out "$1/ca.cert.pem" -subj "/O=test/CN=test CA $2" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
}
mkca "$T/ca" one
mkca "$T/other" two

# gh stub. `gh secret set NAME --env ENV` -> $GHLOG gets the argv, $GHOUT/NAME gets stdin;
# GH_FAIL=NAME makes that one upload fail. `gh api ... <url>` (the CA fetch) -> $GHLOG.api gets the
# argv and stdout gets $GHAPI/<file named by the url>; GH_API_FAIL=1 answers like a 404.
cat >"$T/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = api ]; then
  printf '%s\n' "$*" >>"$GHLOG.api"
  [ -n "${GH_API_FAIL:-}" ] && { echo "HTTP 404: Not Found" >&2; exit 1; }
  url="${*: -1}"; f="${url%%\?*}"; f="${f##*/}"
  cat "$GHAPI/$f"; exit
fi
printf '%s\n' "$*" >>"$GHLOG"
[ "${GH_FAIL:-}" = "$3" ] && exit 1
cat >"$GHOUT/$3"
EOF
chmod +x "$T/gh"

# run <case-dir> [VAR=value ...]: a local PKIDIR copied from $T/ca, a fresh TMPDIR, the stub.
run() {
  local d="$1"; shift
  rm -rf "$d"; mkdir -p "$d/pki" "$d/gh" "$d/tmp"
  cp "$T/ca/ca.cert.pem" "$T/ca/ca.key.pem" "$d/pki/"
  : >"$d/gh.log"
  env PKIDIR="$d/pki" KEYRING="$T/ca/ca.cert.pem" GH="$T/gh" GHLOG="$d/gh.log" GHOUT="$d/gh" \
    TMPDIR="$d/tmp" "$@" bash "$RENEW" >"$d/out" 2>"$d/err"
}

# --- green -------------------------------------------------------------------------------------
CASE="mint"; D="$T/mint"
run "$D"; rc=$?
if [ "$rc" = 0 ]; then ok "exits 0"; else bad "exit $rc: $(cat "$D/err")"; fi
C="$D/gh/RAUC_NIGHTLY_CERT_PEM"; K="$D/gh/RAUC_NIGHTLY_KEY_PEM"
if [ -s "$C" ] && [ -s "$K" ]; then ok "uploaded both secrets"; else bad "uploads: $(ls "$D/gh")"; fi
if grep -qx "secret set RAUC_NIGHTLY_KEY_PEM --env nightly-signing --repo retroforge-linux/os-build" "$D/gh.log" \
   && grep -qx "secret set RAUC_NIGHTLY_CERT_PEM --env nightly-signing --repo retroforge-linux/os-build" "$D/gh.log"; then
  ok "into os-build's nightly-signing environment (repo named), under the nightly names"
else bad "gh argv: $(cat "$D/gh.log")"; fi
if [ "$(head -1 "$D/gh.log")" = "secret set RAUC_NIGHTLY_KEY_PEM --env nightly-signing --repo retroforge-linux/os-build" ]; then
  ok "key uploaded before cert"; else bad "upload order: $(cat "$D/gh.log")"; fi
if grep -q "PRIVATE KEY" "$D/gh.log"; then bad "key material in gh's argv"; else ok "key never in argv"; fi
if openssl verify -CAfile "$T/ca/ca.cert.pem" -purpose any "$C" >/dev/null 2>&1; then
  ok "cert chains to the keyring CA"; else bad "cert does not verify"; fi
txt="$(openssl x509 -in "$C" -noout -text 2>/dev/null)"
if grep -q "Code Signing" <<<"$txt" && grep -q "CA:FALSE" <<<"$txt"; then
  ok "release.ext profile (codeSigning, CA:FALSE)"; else bad "profile missing from the cert"; fi
if openssl x509 -in "$C" -noout -checkend $((89*86400)) >/dev/null \
   && ! openssl x509 -in "$C" -noout -checkend $((91*86400)) >/dev/null; then
  ok "valid for 90 days"; else bad "validity: $(openssl x509 -in "$C" -noout -enddate)"; fi
if [ "$(openssl x509 -in "$C" -noout -pubkey)" = "$(openssl pkey -in "$K" -pubout 2>/dev/null)" ]; then
  ok "uploaded key matches uploaded cert"; else bad "key/cert mismatch"; fi
if grep -rlq "PRIVATE KEY" "$D/pki" --exclude=ca.key.pem; then bad "a private key was left in PKIDIR"
else ok "no nightly key left in PKIDIR"; fi
if [ -z "$(ls -A "$D/tmp")" ]; then ok "tempdir removed"; else bad "left in TMPDIR: $(ls -A "$D/tmp")"; fi
if cmp -s "$D/pki/nightly.cert.pem" "$C"; then ok "public cert copied to PKIDIR"; else bad "no PKIDIR/nightly.cert.pem"; fi
if cmp -s "$D/pki/ca.key.pem" "$T/ca/ca.key.pem"; then ok "ca.key.pem untouched"; else bad "ca.key.pem changed"; fi

CASE="renew-twice"; D2="$T/mint2"
run "$D2"
if [ -s "$D2/gh/RAUC_NIGHTLY_KEY_PEM" ] && ! cmp -s "$D2/gh/RAUC_NIGHTLY_KEY_PEM" "$K"; then
  ok "a new key every run"; else bad "the key was reused"; fi

CASE="days"; D="$T/days"
run "$D" NIGHTLY_DAYS=7
if openssl x509 -in "$D/gh/RAUC_NIGHTLY_CERT_PEM" -noout -checkend $((6*86400)) >/dev/null \
   && ! openssl x509 -in "$D/gh/RAUC_NIGHTLY_CERT_PEM" -noout -checkend $((8*86400)) >/dev/null; then
  ok "NIGHTLY_DAYS sets the lifetime"; else bad "NIGHTLY_DAYS ignored"; fi

# --- red ---------------------------------------------------------------------------------------
# refuses <why>: nonzero exit, and gh never ran.
refuses() {
  if [ "$rc" != 0 ] && [ ! -s "$D/gh.log" ]; then ok "refused, nothing uploaded ($1)"
  else bad "rc=$rc, gh: $(cat "$D/gh.log" 2>/dev/null) ($1)"; fi
}

CASE="wrong-ca"; D="$T/wrong-ca"
run "$D" KEYRING="$T/other/ca.cert.pem"; rc=$?
refuses "PKIDIR's CA is not the keyring's"
grep -q "REFUSED" "$D/err" && ok "says why" || bad "no REFUSED line: $(cat "$D/err")"

CASE="wrong-key"; D="$T/wrong-key"
rm -rf "$D"; mkdir -p "$D/pki" "$D/gh" "$D/tmp"; : >"$D/gh.log"
cp "$T/ca/ca.cert.pem" "$D/pki/"; cp "$T/other/ca.key.pem" "$D/pki/"
PKIDIR="$D/pki" KEYRING="$T/ca/ca.cert.pem" GH="$T/gh" GHLOG="$D/gh.log" GHOUT="$D/gh" TMPDIR="$D/tmp" \
  bash "$RENEW" >"$D/out" 2>"$D/err"; rc=$?
refuses "ca.key.pem is another CA's key"


CASE="bad-days"; D="$T/bad-days"
run "$D" NIGHTLY_DAYS=0; rc=$?
refuses "NIGHTLY_DAYS=0"

CASE="key-upload-fails"; D="$T/key-fails"
run "$D" GH_FAIL=RAUC_NIGHTLY_KEY_PEM; rc=$?
if [ "$rc" != 0 ] && [ ! -e "$D/gh/RAUC_NIGHTLY_CERT_PEM" ]; then ok "stops, cert not uploaded"
else bad "rc=$rc, uploads: $(ls "$D/gh")"; fi
[ -z "$(ls -A "$D/tmp")" ] && ok "tempdir removed on failure" || bad "left in TMPDIR: $(ls -A "$D/tmp")"

CASE="cert-upload-fails"; D="$T/cert-fails"
run "$D" GH_FAIL=RAUC_NIGHTLY_CERT_PEM; rc=$?
if [ "$rc" != 0 ] && grep -q "mismatched pair" "$D/err"; then ok "fails and names the mismatched pair"
else bad "rc=$rc: $(cat "$D/err")"; fi

# --- the default: the root CA comes from the secrets repo -----------------------------------------
# fetch <case-dir> <ca-dir served by gh api> [VAR=value ...]: no PKIDIR at all.
fetch() {
  local d="$1" served="$2"; shift 2
  rm -rf "$d"; mkdir -p "$d/gh" "$d/tmp"; : >"$d/gh.log"
  env -u PKIDIR KEYRING="$T/ca/ca.cert.pem" GH="$T/gh" GHLOG="$d/gh.log" GHOUT="$d/gh" GHAPI="$served" \
    TMPDIR="$d/tmp" "$@" bash "$RENEW" >"$d/out" 2>"$d/err"
}

CASE="fetch"; D="$T/fetch"
fetch "$D" "$T/ca"; rc=$?
if [ "$rc" = 0 ]; then ok "exits 0 with no PKIDIR"; else bad "exit $rc: $(cat "$D/err")"; fi
if grep -qx "api -H Accept: application/vnd.github.raw+json repos/retroforge-linux/secrets/contents/retroforge-pki/ca.key.pem?ref=main" "$D/gh.log.api" \
   && grep -q "contents/retroforge-pki/ca.cert.pem?ref=main" "$D/gh.log.api"; then
  ok "reads ca.cert.pem + ca.key.pem from retroforge-linux/secrets@main"
else bad "gh api calls: $(cat "$D/gh.log.api" 2>/dev/null)"; fi
if [ "$(wc -l <"$D/gh.log.api")" = 2 ]; then ok "fetches those two files only"; else bad "$(wc -l <"$D/gh.log.api") api calls"; fi
if openssl verify -CAfile "$T/ca/ca.cert.pem" -purpose any "$D/gh/RAUC_NIGHTLY_CERT_PEM" >/dev/null 2>&1; then
  ok "cert minted under the fetched CA"; else bad "cert does not verify"; fi
if [ -z "$(ls -A "$D/tmp")" ]; then ok "fetched CA key shredded with the tempdir"; else bad "left in TMPDIR: $(ls -A "$D/tmp")"; fi
grep -q "retroforge-linux/secrets@main" "$D/out" && ok "says where the CA came from" || bad "summary: $(cat "$D/out")"

CASE="target-repo"; D="$T/target-repo"
run "$D" TARGET_REPO=someone/fork
grep -q -- "--repo someone/fork" "$D/gh.log" && ok "TARGET_REPO honoured" || bad "gh argv: $(cat "$D/gh.log")"

CASE="fetch-repo"; D="$T/fetch-repo"
fetch "$D" "$T/ca" SECRETS_REPO=someone/pki SECRETS_REF=v2
grep -q "repos/someone/pki/contents/retroforge-pki/ca.key.pem?ref=v2" "$D/gh.log.api" \
  && ok "SECRETS_REPO / SECRETS_REF honoured" || bad "gh api calls: $(cat "$D/gh.log.api" 2>/dev/null)"

CASE="fetch-denied"; D="$T/fetch-denied"
fetch "$D" "$T/ca" GH_API_FAIL=1; rc=$?
refuses "no read access to the secrets repo"
grep -q "needs read access" "$D/err" && ok "says access is what is missing" || bad "message: $(cat "$D/err")"
[ -z "$(ls -A "$D/tmp")" ] && ok "tempdir removed" || bad "left in TMPDIR: $(ls -A "$D/tmp")"

CASE="fetch-wrong-ca"; D="$T/fetch-wrong-ca"
fetch "$D" "$T/other"; rc=$?
refuses "the secrets repo's CA is not the keyring's"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
