#!/usr/bin/env bash
# Offline test for the logic our OpenGamepadUI patches add, run on a stock Godot.
#
#   tests/test-ogui-patches.sh        (RETROFORGE_GODOT=<godot 4 binary>, or godot on PATH)
#
# WHY THIS EXISTS. A patch's GDScript only runs once the pck is rebuilt and booted, and what it
# gets wrong shows only on a device with the right library. A new file a patch adds needs no OGUI
# types to test, so it is taken out of the COMMITTED patch and run here:
#
#   - 0032 CardArtWindow: a card's art loads within a screen of the visible part and goes past three
#     screens or after the container has been hidden a while. Loading too little shows empty cards;
#     dropping too little keeps a whole library's art in GPU memory (872 MiB, 1,000 games, Air X).
#   - 0053 OguiIdCache: check_running() learns each process's OGUI_ID without reading every
#     environment every second. Reading too little misses a game's processes (OGUI loses the game);
#     reading too much is the 24-40 ms of main thread a second it replaces (Air X).
#   - 0054 InputPlumberRunning: InputManager knows whether InputPlumber runs without a DBus round
#     trip per input event. Asking too often is ~200 round trips a second during a game (Air X);
#     too seldom, or missing started / stopped, and OGUI handles a pad's input twice or not at all.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES="$ROOT/packages/opengamepadui/patches"
P0032="$PATCHES/0032-card-art-only-near-the-screen.patch"
P0053="$PATCHES/0053-launch-manager-reads-a-process-environment-only-while-it-is-new.patch"
P0054="$PATCHES/0054-input-manager-does-not-ask-dbus-whether-inputplumber-runs-on-every-event.patch"

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

for f in "$P0032" "$P0053" "$P0054"; do [ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }; done
T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

# A file the patch adds, as the patch has it: the "+" lines after its "+++ b/<path>" header.
added_file() {
  awk -v path="+++ b/$2" '$0 == path { f = 1; next } f && /^@@/ { next } f && /^\+/ { print substr($0, 2); next } f { exit }' "$1"
}

CASE="card art window (0032)"
GODOT="${RETROFORGE_GODOT:-$(command -v godot || true)}"
if [ -z "$GODOT" ]; then
  printf '  skip %s -- no Godot (set RETROFORGE_GODOT to a Godot 4 binary)\n' "$CASE"
else
  added_file "$P0032" core/ui/components/card_art_window.gd > "$T/card_art_window.gd"
  grep -q '^class_name CardArtWindow$' "$T/card_art_window.gd" \
    && ok "the patch adds core/ui/components/card_art_window.gd" || bad "card_art_window.gd not found in the patch"
  printf 'config_version=5\n[application]\nconfig/name="ogui-patches-test"\n' > "$T/project.godot"
  cat > "$T/card_art_test.gd" <<GD
extends SceneTree
# 60 fake cards, 100 px high, in a 300 px ScrollContainer.

const CardArtWindow := preload("res://card_art_window.gd")
var failed := 0


class FakeCard extends Control:
	var loads := 0
	var releases := 0
	var shown := false

	func _enter_tree() -> void:
		var window = CardArtWindow.of(self)
		if window:
			window.add(self)

	func load_art() -> void:
		loads += 1
		shown = true

	func release_art() -> void:
		releases += 1
		shown = false


func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)


func shown(cards: Array) -> Array:
	var out := []
	for i in cards.size():
		if cards[i].shown:
			out.append(i)
	return out


func frames(n := 3) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	run()


func run() -> void:
	var holder := Control.new()
	root.add_child(holder)
	var scroll := ScrollContainer.new()
	scroll.size = Vector2(200, 300)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	holder.add_child(scroll)
	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 0)
	scroll.add_child(grid)
	var cards := []
	for i in 60:
		var card := FakeCard.new()
		card.custom_minimum_size = Vector2(100, 100)
		grid.add_child(card)
		cards.append(card)
	await frames()
	check("only the cards within a screen of the visible part load (rows 0-5 of 60)", shown(cards), range(0, 6))
	scroll.scroll_vertical = 3000
	await frames()
	var now := shown(cards)
	check("scrolled to row 30: the rows within a screen load, edges exclusive",
		[27 in now, 30 in now, 35 in now, 26 in now, 36 in now], [true, true, true, false, false])
	check("and the first rows, past three screens, drop their art", [cards[0].shown, cards[0].releases], [false, 1])
	scroll.scroll_vertical = 2400
	await frames()
	check("rows past a screen but within three keep theirs", [cards[35].shown, cards[35].releases], [true, 0])
	CardArtWindow.of(cards[0]).hidden_release = 0.3
	holder.visible = false
	await create_timer(0.1).timeout
	check("a hidden container (its parent hidden) keeps its art a while", shown(cards).is_empty(), false)
	await create_timer(0.4).timeout
	check("then drops it all", shown(cards), [])
	holder.visible = true
	await frames()
	check("shown again, the rows on screen load again", 24 in shown(cards), true)
	cards[25].visible = false
	cards[26].visible = false
	await frames()
	scroll.scroll_vertical = 0
	await frames()
	check("hidden cards are skipped and the window still finds its rows", shown(cards).slice(0, 3), [0, 1, 2])
	# A tab built while hidden: its grid never placed its cards (all at 0) until it is shown. Read
	# then, every card looked on screen and all 1,000 loaded at once (Air X, 2026-10-24).
	var holder2 := Control.new()
	holder2.visible = false
	root.add_child(holder2)
	var scroll2 := ScrollContainer.new()
	scroll2.size = Vector2(200, 300)
	scroll2.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	holder2.add_child(scroll2)
	var grid2 := VBoxContainer.new()
	grid2.add_theme_constant_override("separation", 0)
	scroll2.add_child(grid2)
	var cards2 := []
	for i in 60:
		var card := FakeCard.new()
		card.custom_minimum_size = Vector2(100, 100)
		grid2.add_child(card)
		cards2.append(card)
	await frames()
	holder2.visible = true
	await frames(5)
	var loads := 0
	for card in cards2:
		loads += card.loads
	check("a tab built while hidden, then shown: only its first rows ever load, not all 60", [loads, shown(cards2)], [6, range(0, 6)])
	quit(1 if failed else 0)
GD
  out="$(HOME="$T/home" XDG_CONFIG_HOME="$T/config" timeout 60 "$GODOT" --headless --path "$T" --script res://card_art_test.gd 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
fi

CASE="OGUI_ID cache (0053)"
if [ -z "$GODOT" ]; then
  printf '  skip %s -- no Godot (set RETROFORGE_GODOT to a Godot 4 binary)\n' "$CASE"
else
  P53="$T/p53"; mkdir -p "$P53"
  added_file "$P0053" core/systems/launcher/ogui_id_cache.gd > "$P53/ogui_id_cache.gd"
  grep -q '^func sweep(pids: PackedInt64Array)' "$P53/ogui_id_cache.gd" \
    && ok "the patch adds core/systems/launcher/ogui_id_cache.gd" || bad "ogui_id_cache.gd not found in the patch"
  grep -q '_ogui_ids.sweep(all_pids)' "$P0053" && ! grep -q '^-.*_ogui_ids' "$P0053" \
    && ok "and check_running() takes its OGUI_ID -> pids map from it" || bad "check_running() does not use the cache"
  printf 'config_version=5\n[application]\nconfig/name="ogui-patches-test"\n' > "$P53/project.godot"
  cat > "$P53/ogui_id_test.gd" <<GD
extends SceneTree
# A fake /proc: pid -> its environment. read_env() records what is read.

const OguiIdCache := preload("res://ogui_id_cache.gd")
var failed := 0
var envs := {}


func check(what: String, got, want) -> void:
	if str(got) == str(want):
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)


func read_env(pid: int) -> Dictionary:
	return envs.get(pid, {})


func _initialize() -> void:
	for pid in range(1000, 1300):
		envs[pid] = {"HOME": "/home/player"}
	envs[1100] = {"OGUI_ID": "Hades"}
	envs[1101] = {"OGUI_ID": "Hades", "SteamGameId": "1145360"}
	envs.erase(1102)   # a root process: its environment cannot be read
	var pids := PackedInt64Array(range(1000, 1300))
	var cache = OguiIdCache.new(read_env)
	var got: Dictionary = cache.sweep(pids)
	check("first check: every environment read, the app's processes found by OGUI_ID",
		[cache.reads, got], [300, {"Hades": PackedInt64Array([1100, 1101])}])
	cache.sweep(pids)
	cache.sweep(pids)
	check("a pid is read again in its first 3 checks (a fork that execs with its own environment)", cache.reads, 900)
	var before: int = cache.reads
	for i in 30:
		got = cache.sweep(pids)
	check("then once every 30 checks: 300 reads over 30 checks instead of 9,000, the same map",
		[cache.reads - before, got], [300, {"Hades": PackedInt64Array([1100, 1101])}])
	envs[2000] = {}   # forked, not exec'd yet
	pids.push_back(2000)
	cache.sweep(pids)
	envs[2000] = {"OGUI_ID": "Steam"}   # exec'd as the kept Steam unit
	got = cache.sweep(pids)
	check("a new process that execs with OGUI_ID set by its next check is found", got.get("Steam"), PackedInt64Array([2000]))
	envs[1200] = {"OGUI_ID": "Late"}
	var seen := -1
	for i in 30:
		got = cache.sweep(pids)
		if "Late" in got and seen < 0:
			seen = i
	check("an old process whose environment changes is found within 30 checks", seen >= 0, true)
	got = cache.sweep(PackedInt64Array([1100, 2000]))
	check("processes that have gone are forgotten; the rest keep their OGUI_ID",
		[cache.size(), got], [2, {"Hades": PackedInt64Array([1100]), "Steam": PackedInt64Array([2000])}])
	quit(1 if failed else 0)
GD
  out="$(HOME="$T/home" XDG_CONFIG_HOME="$T/config" timeout 60 "$GODOT" --headless --path "$P53" --script res://ogui_id_test.gd 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
fi

CASE="InputPlumber running cache (0054)"
if [ -z "$GODOT" ]; then
  printf '  skip %s -- no Godot (set RETROFORGE_GODOT to a Godot 4 binary)\n' "$CASE"
else
  P54="$T/p54"; mkdir -p "$P54"
  added_file "$P0054" core/systems/input/input_plumber_running.gd > "$P54/input_plumber_running.gd"
  grep -q '^func is_running() -> bool:$' "$P54/input_plumber_running.gd" \
    && ok "the patch adds core/systems/input/input_plumber_running.gd" || bad "input_plumber_running.gd not found in the patch"
  # Every per-event call goes through the cache: none of the removed lines' direct calls is added back.
  if grep -q '^-.*input_plumber\.is_running()' "$P0054" && ! grep -q '^+.*input_plumber\.is_running()' "$P0054" \
      && [ "$(grep -c '^+.*input_plumber_running\.is_running()' "$P0054")" -eq 4 ]; then
    ok "both input managers' _input(), is_action_pressed() and the D-Pad check use it"
  else
    bad "a direct input_plumber.is_running() is left in the patched input managers"
  fi
  # The joypad drop comes first in _input(), before the debug message is built.
  awk '/^\+\+\+ b\/core\/systems\/input\/(input|overlay_mode_input)_manager.gd/ { f = 1 } f && /func _input\(event: InputEvent\)/ { inside = 1; next }
       inside && /logger\.debug\("Got input event/ { print (seen ? "first" : "late"); inside = 0; seen = 0 }
       inside && /input_plumber_running\.is_running\(\) and not/ { seen = 1 }' "$P0054" | sort | uniq -c | grep -q '^ *2 first$' \
    && ok "in both _input()s the joypad drop comes before the debug message" || bad "a joypad event still builds the debug message first"
  printf 'config_version=5\n[application]\nconfig/name="ogui-patches-test"\n' > "$P54/project.godot"
  cat > "$P54/ip_running_test.gd" <<GD
extends SceneTree
# A fake InputPlumberInstance that counts its DBus checks, and a fake clock.

const InputPlumberRunning := preload("res://input_plumber_running.gd")
var failed := 0
var now_ms := 5000


class FakePlumber extends RefCounted:
	signal started
	signal stopped
	var running := true
	var calls := 0

	func is_running() -> bool:
		calls += 1
		return running


func clock() -> int:
	return now_ms


func check(what: String, got, want) -> void:
	if str(got) == str(want):
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)


func _initialize() -> void:
	var plumber := FakePlumber.new()
	var cache = InputPlumberRunning.new(plumber, clock)
	var answers := []
	for i in 200:
		answers.append(cache.is_running())
		now_ms += 4
	check("200 events in 0.8 s: one DBus check, the same answer", [plumber.calls, answers.count(true)], [1, 200])
	plumber.running = false
	now_ms += 250
	check("a second after the last check it asks again and sees InputPlumber gone", [cache.is_running(), plumber.calls], [false, 2])
	plumber.running = true
	plumber.started.emit()
	check("started: running at once, without asking", [cache.is_running(), plumber.calls], [true, 2])
	plumber.running = false
	plumber.stopped.emit()
	check("stopped: not running at once, without asking", [cache.is_running(), plumber.calls], [false, 2])
	now_ms += 999
	cache.is_running()
	check("the signal's answer counts as a check (next ask a second after it)", plumber.calls, 2)
	now_ms += 1
	cache.is_running()
	check("and then it asks", plumber.calls, 3)
	var plain = InputPlumberRunning.new(FakePlumber.new())
	check("with no clock given it runs on Time.get_ticks_msec()", plain.is_running(), true)
	quit(1 if failed else 0)
GD
  out="$(HOME="$T/home" XDG_CONFIG_HOME="$T/config" timeout 60 "$GODOT" --headless --path "$P54" --script res://ip_running_test.gd 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
