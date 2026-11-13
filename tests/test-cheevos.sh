#!/usr/bin/env bash
# Offline test for /usr/bin/retroforge-cheevos -- the RetroAchievements sign-in behind Settings >
# Library > RetroAchievements (plans retroarch Phase 3, standalone-cheevos).
#
#   tests/test-cheevos.sh
#
# WHY THIS EXISTS. The player's RetroAchievements password must never be kept, shown or leaked:
#
#   - it reaches the tool on stdin, and curl reads it from stdin too (-K -): never in any argv, where
#     every process of the player could read it from /proc;
#   - only the token RetroAchievements hands back is written, into RetroForge's own
#     ~/.config/retroforge/retroachievements.json, which is 0600 before the token is in it;
#   - a refused sign-in (wrong password) is told apart from a network failure, and changes nothing;
#   - no emulator's file is written here (the launcher does that at each start), so nothing is
#     refused while RetroArch runs, and a home where RetroArch never ran gets no retroarch.cfg (one
#     holding only the sign-in would keep RetroArch's first-run seed out for good);
#   - a home that signed in before that file existed (the sign-in in retroarch.cfg) stays signed in,
#     and its first change moves the sign-in into the file, which wins from then on.
#
# HOW: the shipped tool with its seams (RETROFORGE_CURL, HOME) pointing into a sandbox; curl is a stub
# that answers like retroachievements.org's login2. No network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/rootfs/overlay/usr/bin/retroforge-cheevos"
[ -f "$TOOL" ] || { echo "no retroforge-cheevos: $TOOL" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)" && [ -d "$W" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
PW='p4ss "word" \with\ quotes'

# The curl stub: logs its argv and the config it read on stdin; answers like login2. A good login is
# user Player1 + $PW (RetroAchievements spells the name its own way: "player1" -> "Player1").
cat > "$W/bin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$W/curl.argv"
cfg="\$(cat)"
printf '%s\n' "\$cfg" >> "$W/curl.stdin"
[ -f "$W/offline" ] && exit 6
if [ -f "$W/server-error" ]; then printf '<html>busy</html>\n503'; exit 0; fi
user=\$(sed -n 's/^data-urlencode = "u=\(.*\)"\$/\1/p' <<<"\$cfg")
pass=\$(sed -n 's/^data-urlencode = "p=\(.*\)"\$/\1/p' <<<"\$cfg")
if [ "\${user,,}" = player1 ] && [ "\$pass" = 'p4ss \"word\" \\\\with\\\\ quotes' ]; then
  printf '{"Success":true,"User":"Player1","Token":"AbCdEf0123456789","Score":10}\n200'
else
  printf '{"Success":false,"Status":401,"Code":"invalid_credentials","Error":"Invalid user/password combination. Please try again."}\n401'
fi
EOF
chmod +x "$W/bin/curl"

H="$W/home"; STORE="$H/.config/retroforge/retroachievements.json"; CFG="$H/.config/retroarch/retroarch.cfg"
run() {  # run [stdin] -- <args...>: sets OUT, ERR, RC
  local input="$1"; shift; [ "$1" = -- ] && shift
  OUT="$(printf '%s' "$input" | HOME="$H" RETROFORGE_CURL="$W/bin/curl" python3 "$TOOL" "$@" 2>"$W/err")"
  RC=$?; ERR="$(cat "$W/err")"
}
reset() { rm -rf "$H" "$W/curl.argv" "$W/curl.stdin" "$W/offline" "$W/server-error"; mkdir -p "$H"; }
store() { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print(json.dumps(v) if isinstance(v, bool) else v)' "$STORE" "$1" 2>/dev/null; }
mode() { stat -c %a "$STORE" 2>/dev/null; }
status_is() { python3 -I -c 'import json,sys; sys.exit(json.loads(sys.argv[1]) != json.loads(sys.argv[2]))' "$OUT" "$1"; }

# =================================================================================================
CASE="bad invocations"
reset
run "" --;                    [ "$RC" = 2 ] && ok "no command: exit 2" || bad "exit $RC"
run "$PW" -- login;           [ "$RC" = 2 ] && ok "login without a user: exit 2" || bad "exit $RC"
run "" -- login Player1;      [ "$RC" = 2 ] && ok "login without a password on stdin: exit 2" || bad "exit $RC"
run "$PW" -- login 'a"b';     [ "$RC" = 2 ] && ok "a user name with a quote: exit 2" || bad "exit $RC"
run "$PW" -- login Player1 "$PW"; [ "$RC" = 2 ] && ok "a password on the command line is refused" || bad "exit $RC"
run "" -- hardcore maybe;     [ "$RC" = 2 ] && ok "hardcore needs on or off" || bad "exit $RC"
[ ! -e "$W/curl.argv" ] && ok "nothing reached the network" || bad "curl ran"

# =================================================================================================
CASE="sign in"
reset
run "$PW" -- login player1
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $ERR"
[ "$(store user)" = Player1 ] && ok "user is the name RetroAchievements gave back" || bad "user '$(store user)'"
[ "$(store token)" = AbCdEf0123456789 ] && ok "token is the token" || bad "token '$(store token)'"
[ "$(store hardcore)" = false ] && [ "$(store version)" = 1 ] && ok "hardcore off, version 1" || bad "$(cat "$STORE")"
! grep -rqF 'p4ss' "$H" && ok "the password is nowhere in the home" || bad "the password was written: $(grep -rlF p4ss "$H")"
[ "$(mode)" = 600 ] && ok "the sign-in file is 0600 (it holds the token)" || bad "mode $(mode)"
[ ! -e "$CFG" ] && ok "no retroarch.cfg made (it would keep RetroArch's seed out for good)" || bad "retroarch.cfg written"
! grep -qF 'p4ss' "$W/curl.argv" && ok "the password is not in curl's argv" || bad "password in argv: $(cat "$W/curl.argv")"
grep -q -- '-K -' "$W/curl.argv" && grep -q 'https://retroachievements.org/dorequest.php' "$W/curl.stdin" \
  && ok "curl reads its URL and data from stdin" || bad "curl argv: $(cat "$W/curl.argv")"
grep -q -- '--proto =https' "$W/curl.argv" && ok "https only, redirects included" || bad "no --proto =https"
grep -q '^user-agent = "RetroForge' "$W/curl.stdin" && ok "it says who it is (User-Agent RetroForge)" || bad "user agent: $(grep -i agent "$W/curl.stdin")"
run "" -- status
status_is '{"signed_in": true, "user": "Player1", "hardcore": false}' && ok "status: signed in as Player1, hardcore off" || bad "status: $OUT"
! grep -q AbCdEf <<<"$OUT" && ok "status never prints the token" || bad "token in status"

# =================================================================================================
CASE="a refused sign-in"
reset; run "$PW" -- login Player1; before="$(cat "$STORE")"
run "wrong" -- login Player1
[ "$RC" = 7 ] && ok "wrong password: exit 7" || bad "exit $RC"
grep -q "Invalid user/password" <<<"$ERR" && ok "stderr gives RetroAchievements' reason" || bad "stderr: $ERR"
[ "$(cat "$STORE")" = "$before" ] && ok "the sign-in unchanged" || bad "the sign-in changed"

CASE="network and server failures"
reset; touch "$W/offline"
run "$PW" -- login Player1
[ "$RC" = 3 ] && ok "offline: exit 3" || bad "exit $RC"
reset; touch "$W/server-error"
run "$PW" -- login Player1
[ "$RC" = 8 ] && ok "an answer that is not login2's JSON: exit 8" || bad "exit $RC"
[ ! -e "$STORE" ] && ok "nothing written" || bad "the sign-in file written"

# =================================================================================================
CASE="hardcore, sign out"
reset; run "$PW" -- login Player1
run "" -- hardcore on
[ "$RC" = 0 ] && [ "$(store hardcore)" = true ] && [ "$(store user)" = Player1 ] && ok "hardcore on, the sign-in kept" || bad "exit $RC, $(cat "$STORE")"
run "" -- logout
[ "$RC" = 0 ] && [ -z "$(store user)" ] && [ -z "$(store token)" ] && ok "logout empties the name and the token" || bad "exit $RC"
[ "$(store hardcore)" = true ] && ok "logout keeps the Hardcore choice" || bad "hardcore '$(store hardcore)'"
run "" -- status
status_is '{"signed_in": false, "user": null, "hardcore": true}' && ok "status: signed out" || bad "status: $OUT"
run "" -- hardcore off
[ "$RC" = 0 ] && [ "$(store hardcore)" = false ] && ok "hardcore off while signed out" || bad "exit $RC"
reset
run "" -- hardcore on
[ "$RC" = 0 ] && [ "$(store hardcore)" = true ] && [ ! -e "$CFG" ] && ok "hardcore on a home that never signed in: the file made, nothing else" || bad "exit $RC"

# =================================================================================================
CASE="a sign-in from before (in retroarch.cfg)"
old_cfg() { reset; mkdir -p "$(dirname "$CFG")"
  printf 'video_driver = "vulkan"\ncheevos_enable = "true"\ncheevos_username = "OldPlayer"\ncheevos_token = "OldToken12345678"\ncheevos_hardcore_mode_enable = "true"\n' > "$CFG"
  chmod 600 "$CFG"; cfg_before="$(cat "$CFG")"; }
old_cfg
run "" -- status
status_is '{"signed_in": true, "user": "OldPlayer", "hardcore": true}' && ok "still signed in, hardcore kept" || bad "status: $OUT"
[ ! -e "$STORE" ] && ok "status creates nothing" || bad "status wrote the sign-in file"
run "" -- hardcore off
[ "$RC" = 0 ] && [ "$(store user)" = OldPlayer ] && [ "$(store token)" = OldToken12345678 ] && [ "$(store hardcore)" = false ] \
  && ok "the first change moves the sign-in into RetroForge's file" || bad "exit $RC, $(cat "$STORE" 2>/dev/null)"
[ "$(cat "$CFG")" = "$cfg_before" ] && ok "retroarch.cfg is never written here" || bad "retroarch.cfg changed"
old_cfg
run "" -- logout
[ "$RC" = 0 ] && [ -z "$(store user)" ] && [ "$(store hardcore)" = true ] && ok "a sign-out on such a home: the file says signed out" || bad "exit $RC"
run "" -- status
status_is '{"signed_in": false, "user": null, "hardcore": true}' && ok "...and wins over the old retroarch.cfg" || bad "status: $OUT"
old_cfg
run "$PW" -- login Player1
[ "$(store user)" = Player1 ] && [ "$(store hardcore)" = true ] && ok "a new sign-in replaces the old one, Hardcore kept" || bad "$(cat "$STORE")"

# =================================================================================================
CASE="RetroArch running does not matter"
reset; run "$PW" -- login Player1
run "" -- hardcore on
[ "$RC" = 0 ] && ok "no emulator file is written here, so nothing waits on RetroArch" || bad "exit $RC"

# =================================================================================================
CASE="a sign-in file that is not one"
reset; mkdir -p "$(dirname "$STORE")"; printf 'not json\n' > "$STORE"
run "" -- status
[ "$RC" = 5 ] && ok "status: exit 5 (the plugin shows signed out)" || bad "exit $RC: $OUT"
run "" -- hardcore on
[ "$RC" = 5 ] && [ "$(cat "$STORE")" = "not json" ] && ok "hardcore will not overwrite it blind" || bad "exit $RC"
run "$PW" -- login Player1
[ "$RC" = 0 ] && [ "$(store user)" = Player1 ] && ok "a sign-in replaces it (the player is never stuck)" || bad "exit $RC: $ERR"
printf '{"version": 1, "user": "Player1", "token": "bad token!", "hardcore": false}\n' > "$STORE"
run "" -- status
status_is '{"signed_in": false, "user": null, "hardcore": false}' && ok "a token that is not one: signed out" || bad "status: $OUT"
! grep -qF 'bad token' <<<"$ERR" && ok "...and never echoed" || bad "stderr: $ERR"

CASE="files the tool makes"
reset; run "$PW" -- login Player1
[ "$(stat -c %a "$(dirname "$STORE")")" = 700 ] && ok "a retroforge folder it creates is 0700 (umask 077)" || bad "folder mode $(stat -c %a "$(dirname "$STORE")")"
[ -z "$(find "$H" -name '*.retroforge-*')" ] && ok "no temporary file left beside the sign-in file" || bad "leftover: $(find "$H" -name '*.retroforge-*')"
grep -q -- '^-q ' "$W/curl.argv" && ok "curl runs with -q first (no ~/.curlrc)" || bad "curl argv: $(head -1 "$W/curl.argv")"
chmod 644 "$STORE"
run "" -- hardcore on
[ "$(mode)" = 600 ] && ok "an existing 0644 file is tightened to 0600" || bad "mode $(mode)"

echo
echo "test-cheevos: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
