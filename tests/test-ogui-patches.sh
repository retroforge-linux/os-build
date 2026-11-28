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
#   - 0060 SteamGameFocus: which window of a game a running Steam client started may have the focus.
#     Steam's hidden desktop window given the focus hid the game, which ran behind it (Air X); keeping
#     Steam's windows from it before the game has a window would hide Steam's launch dialogs instead.
#   - 0061 VolumeStep: what one press of a volume key does to the level. Off the 5 grid it must land
#     on it, in the key's direction; a press wrote nine racing levels before, and the speaker moved by
#     0 to 10 (Air X).
#   - 0062 DeclaredProfile: whose game a launcher's declared gamepad profile is for. Given to any
#     focused app, a game started beside an emulator got the emulator's hotkeys (Air X); given to
#     none, an emulator loses them.
#   - 0064 FocusOffers: which windows gamescope has newly made focusable, by OGUI's own record. Told
#     by the signal's "from" list, half of a game's launches beside another game left it hidden behind
#     it for good (Air X); a record that never forgets would miss the next launch, whose windows get
#     the same ids.
#   - 0065 GameBeside: which game L1 or R1 shows next on a game's page. Stepping onto Home's Library
#     card, or a card a search has hidden, would open the page on no game; stepping past the ends of
#     a row or grid must do nothing.
#   - 0066 ShownDisks: which disks and partitions the Disks settings menu shows, from the mount table
#     and sysfs. /home's partition alone on its disk, and an internal install's mounted SD card; any
#     more is the vendor's ~85 internal partitions it listed before (Air X), any less hides the disk
#     RetroForge keeps its data on.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES="$ROOT/packages/opengamepadui/patches"
P0032="$PATCHES/0032-card-art-only-near-the-screen.patch"
P0053="$PATCHES/0053-launch-manager-reads-a-process-environment-only-while-it-is-new.patch"
P0054="$PATCHES/0054-input-manager-does-not-ask-dbus-whether-inputplumber-runs-on-every-event.patch"
P0060="$PATCHES/0060-launch-manager-a-steam-window-never-takes-the-focus-from-the-game.patch"
P0061="$PATCHES/0061-audio-a-volume-key-press-is-written-once-on-the-5-grid.patch"
P0062="$PATCHES/0062-launch-manager-a-declared-profile-is-its-launchers-apps-a-missing-one-is-passed-over.patch"
P0064="$PATCHES/0064-launch-manager-a-newly-focusable-window-is-told-by-our-own-record.patch"
P0065="$PATCHES/0065-game-page-l1-and-r1-show-the-game-before-or-after.patch"
P0066="$PATCHES/0066-disks-menu-shows-home-and-the-sd-card-only.patch"

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

for f in "$P0032" "$P0053" "$P0054" "$P0060" "$P0061" "$P0062" "$P0064" "$P0065" "$P0066"; do [ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }; done
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

CASE="Steam game focus (0060)"
if [ -z "$GODOT" ]; then
  printf '  skip %s -- no Godot (set RETROFORGE_GODOT to a Godot 4 binary)\n' "$CASE"
else
  P60="$T/p60"; mkdir -p "$P60"
  added_file "$P0060" core/systems/launcher/steam_game_focus.gd > "$P60/steam_game_focus.gd"
  grep -q '^static func may_focus(' "$P60/steam_game_focus.gd" \
    && ok "the patch adds core/systems/launcher/steam_game_focus.gd" || bad "steam_game_focus.gd not found in the patch"
  # Every place OGUI picks a window of a running app asks it: a new window, a newly focusable one,
  # the window focused when focusable windows change, the dropped-focus fallback, and grab_focus().
  [ "$(grep -c '^+.*may_focus(' "$P0060" | tr -d ' ')" -ge 5 ] && grep -q '^+.*newest: int = app.steam_game_window(to)' "$P0060" \
    && ok "new, newly focusable and already focused windows, the fallback and grab_focus() all ask it" \
    || bad "a window choice in launch_manager.gd or running_app.gd does not go through it"
  # Asked inside gamescope's signal, godot-rust refuses the call and any window may have the focus
  # (1,554 panics in one launch, Air X): the choice of a window runs deferred. The focused window
  # that is gone still loses the focus inside the signal: decided later, a check in between has
  # already cleared it and no other app's window gets the screen.
  grep -q '^+.*_focus_focusable_window\.call_deferred(from, to, dropped)' "$P0060" \
    && grep -q '^+func _focus_focusable_window(from: PackedInt64Array, to: PackedInt64Array, dropped: bool) -> void:$' "$P0060" \
    && ok "the choice of a focusable window asks out of gamescope's signal (deferred)" \
    || bad "the focusable-windows handler still chooses inside gamescope's signal"
  ! grep -q '^-.*_xwayland_primary.remove_baselayer_window()' "$P0060" && ! grep -q '^-.*dropped = true' "$P0060" \
    && ok "a focused window that is gone still loses the focus at once" \
    || bad "the focus of a window that is gone is no longer dropped inside the signal"
  printf 'config_version=5\n[application]\nconfig/name="ogui-patches-test"\n' > "$P60/project.godot"
  cat > "$P60/steam_focus_test.gd" <<GD
extends SceneTree
# Window 10: Steam's desktop window. 20 and 30: the game's (a process with its SteamGameId). 40: another
# window of the app's, neither Steam's nor the game's.

const SteamGameFocus := preload("res://steam_game_focus.gd")
var failed := 0


func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)


func _init() -> void:
	var steam := PackedInt64Array([10])
	var game := PackedInt64Array([20])
	var all := PackedInt64Array([10, 20, 40])
	check("no game window: none", SteamGameFocus.game_window(all, all, PackedInt64Array(), steam), -1)
	check("the game's window once gamescope can focus it", SteamGameFocus.game_window(all, all, game, steam), 20)
	check("not before", SteamGameFocus.game_window(all, PackedInt64Array([10, 40]), game, steam), -1)
	check("the newest of the game's windows",
		SteamGameFocus.game_window(PackedInt64Array([10, 20, 30]), PackedInt64Array([10, 20, 30]), PackedInt64Array([20, 30]), steam), 30)
	check("a Steam window is never the game's",
		SteamGameFocus.game_window(PackedInt64Array([10, 20]), PackedInt64Array([10, 20]), PackedInt64Array([10, 20]), steam), 20)
	check("while the game has a window, Steam's never gets the focus", SteamGameFocus.may_focus(10, 20, steam), false)
	check("the game's window does", SteamGameFocus.may_focus(20, 20, PackedInt64Array()), true)
	check("and another window of the app that is not Steam's", SteamGameFocus.may_focus(40, 20, PackedInt64Array()), true)
	check("before the game has a window, Steam's does (its launch dialogs, a prompt)", SteamGameFocus.may_focus(10, -1, steam), true)
	quit(1 if failed else 0)
GD
  out="$(HOME="$T/home" XDG_CONFIG_HOME="$T/config" timeout 60 "$GODOT" --headless --path "$P60" --script res://steam_focus_test.gd 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
fi

CASE="volume key step (0061)"
if [ -z "$GODOT" ]; then
  printf '  skip %s -- no Godot (set RETROFORGE_GODOT to a Godot 4 binary)\n' "$CASE"
else
  P61="$T/p61"; mkdir -p "$P61"
  added_file "$P0061" core/global/volume_step.gd > "$P61/volume_step.gd"
  grep -q '^static func next(' "$P61/volume_step.gd" \
    && ok "the patch adds core/global/volume_step.gd" || bad "volume_step.gd not found in the patch"
  # The keys go through it, and a slider shown a level does not write it back (both menus).
  [ "$(grep -c '^+.*audio_manager.call_deferred("step_volume", -\{0,1\}1)' "$P0061" | tr -d ' ')" -eq 4 ] \
    && ! grep -q '^+.*VOLUME.RELATIVE' "$P0061" \
    && ok "both input managers' volume keys call step_volume()" || bad "a volume key still makes a relative change"
  [ "$(grep -c '^+	if _showing_volume:$' "$P0061" | tr -d ' ')" -eq 2 ] \
    && ok "neither menu writes back a level it is shown" || bad "a volume slider still writes back the level it is shown"
  printf 'config_version=5\n[application]\nconfig/name="ogui-patches-test"\n' > "$P61/project.godot"
  cat > "$P61/volume_step_test.gd" <<GD
extends SceneTree

const VolumeStep := preload("res://volume_step.gd")
var failed := 0


func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)


func _init() -> void:
	check("up from the grid: one step", VolumeStep.next(55, 1), 60)
	check("down from the grid: one step", VolumeStep.next(55, -1), 50)
	check("up from off the grid: the next multiple of 5", VolumeStep.next(52, 1), 55)
	check("down from off the grid: the one below", VolumeStep.next(52, -1), 50)
	check("just under a multiple, up: that multiple", VolumeStep.next(59, 1), 60)
	check("just over a multiple, down: that multiple", VolumeStep.next(51, -1), 50)
	check("never below silence", VolumeStep.next(0, -1), 0)
	check("3 down is silence, not -5", VolumeStep.next(3, -1), 0)
	check("never above the limit", VolumeStep.next(100, 1), 100)
	check("98 up stops at the limit", VolumeStep.next(98, 1), 100)
	check("a higher limit is reached in steps", VolumeStep.next(100, 1, 200), 105)
	var level := 52
	var seen := []
	for i in 4:
		level = VolumeStep.next(level, 1)
		seen.append(level)
	check("presses in a row stay on the grid", seen, [55, 60, 65, 70])
	quit(1 if failed else 0)
GD
  out="$(HOME="$T/home" XDG_CONFIG_HOME="$T/config" timeout 60 "$GODOT" --headless --path "$P61" --script res://volume_step_test.gd 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
fi

CASE="declared profile owner (0062)"
if [ -z "$GODOT" ]; then
  printf '  skip %s -- no Godot (set RETROFORGE_GODOT to a Godot 4 binary)\n' "$CASE"
else
  P62="$T/p62"; mkdir -p "$P62"
  added_file "$P0062" core/systems/launcher/declared_profile.gd > "$P62/declared_profile.gd"
  grep -q '^static func applies(' "$P62/declared_profile.gd" \
    && ok "the patch adds core/systems/launcher/declared_profile.gd" || bad "declared_profile.gd not found in the patch"
  grep -q '^+.*DeclaredProfile.applies(declarer_id, app != null' "$P0062" && grep -q '^+	var declared := _get_declared_profile(app)$' "$P0062" \
    && ok "the declared profile is asked for the focused app" || bad "the declared profile is still loaded for any app"
  # A game profile that is gone is passed over before it is asked for (nothing was loaded: no input).
  grep -q '^+	if not profile_path.is_empty() and not (profile_path.ends_with(".json") and FileAccess.file_exists(profile_path)):$' "$P0062" \
    && ok "a game's own profile that is gone is passed over" || bad "a missing game profile is still asked for"
  printf 'config_version=5\n[application]\nconfig/name="ogui-patches-test"\n' > "$P62/project.godot"
  cat > "$P62/declared_profile_test.gd" <<GD
extends SceneTree
# applies(declarer's OGUI_ID, an app has the focus, its OGUI_ID, OpenGamepadUI started it)

const DeclaredProfile := preload("res://declared_profile.gd")
var failed := 0


func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)


func _init() -> void:
	check("the emulator its launcher started", DeclaredProfile.applies("shadowdemo", true, "shadowdemo", true), true)
	check("not a game started beside it", DeclaredProfile.applies("shadowdemo", true, "Hollow Knight", true), false)
	check("not an app OpenGamepadUI took up beside it", DeclaredProfile.applies("shadowdemo", true, "", false), false)
	check("not when OpenGamepadUI cannot name the focused app", DeclaredProfile.applies("shadowdemo", false, "", false), false)
	check("a launcher started elsewhere: the app OpenGamepadUI did not start", DeclaredProfile.applies("", true, "", false), true)
	check("and the app it cannot name", DeclaredProfile.applies("", false, "", false), true)
	check("but not a game OpenGamepadUI started", DeclaredProfile.applies("", true, "Hollow Knight", true), false)
	quit(1 if failed else 0)
GD
  out="$(HOME="$T/home" XDG_CONFIG_HOME="$T/config" timeout 60 "$GODOT" --headless --path "$P62" --script res://declared_profile_test.gd 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
fi

CASE="focus offers (0064)"
if [ -z "$GODOT" ]; then
  printf '  skip %s -- no Godot (set RETROFORGE_GODOT to a Godot 4 binary)\n' "$CASE"
else
  P64="$T/p64"; mkdir -p "$P64"
  added_file "$P0064" core/systems/launcher/focus_offers.gd > "$P64/focus_offers.gd"
  grep -q '^static func fresh(' "$P64/focus_offers.gd" \
    && ok "the patch adds core/systems/launcher/focus_offers.gd" || bad "focus_offers.gd not found in the patch"
  # The handler no longer asks the signal's "from" list, and a window focused as it is first listed
  # is recorded, so it is not given the focus a second time later.
  grep -q '^-			if window in from or not window in app.window_ids:$' "$P0064" && grep -q '^+		for window in fresh:$' "$P0064" \
    && ok "a newly focusable window is told by the record, not by the signal's from list" \
    || bad "the handler still tells a newly focusable window by the signal's from list"
  grep -q '^+				_focus_offered.append(window)$' "$P0064" \
    && ok "a window focused as it is first listed is recorded" || bad "switch_to_new_window does not record the window it focuses"
  printf 'config_version=5\n[application]\nconfig/name="ogui-patches-test"\n' > "$P64/project.godot"
  cat > "$P64/focus_offers_test.gd" <<GD
extends SceneTree
# gamescope's list: window id, app id, pid for each window. 67108865: Hollow Knight's window (the same
# id at every launch), 23068679: the emulator's.

const FocusOffers := preload("res://focus_offers.gd")
var failed := 0


func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)


func ids(a: Array) -> PackedInt64Array:
	return PackedInt64Array(a)


func _init() -> void:
	var both := ids([67108865, 367520, 126829, 23068679, 212526005, 125947])
	check("the list's window ids, without app ids and pids", FocusOffers.windows(both), ids([67108865, 23068679]))
	check("a list that is not in threes is taken as it is", FocusOffers.windows(ids([5, 6])), ids([5, 6]))
	check("an empty list has none", FocusOffers.windows(ids([])), ids([]))
	var emulator := ids([23068679])
	var game := ids([67108865])
	var known := ids([23068679, 67108865, 33554434])
	# The emulator has the screen; the game's window becomes focusable. The signal's from list
	# already had it: only the record says it is new.
	check("a window gamescope lists that was not offered the focus is new", FocusOffers.fresh(ids([67108865, 23068679]), known, emulator), game)
	check("in gamescope's order when there are several", FocusOffers.fresh(ids([67108865, 23068679]), known, ids([])), ids([67108865, 23068679]))
	check("one already offered is not", FocusOffers.fresh(ids([67108865, 23068679]), known, ids([67108865, 23068679])), ids([]))
	check("a window no app has listed yet is not offered", FocusOffers.fresh(ids([67108865, 23068679]), emulator, emulator), ids([]))
	check("nor remembered, so it is new once its app lists it",
		FocusOffers.fresh(ids([67108865, 23068679]), known, FocusOffers.remember(ids([67108865, 23068679]), emulator)), game)
	var record := FocusOffers.remember(ids([67108865, 23068679]), known)
	check("the record holds the apps' focusable windows", record, ids([67108865, 23068679]))
	# The game ends: its window leaves the list. The next launch's window gets the same id.
	record = FocusOffers.remember(ids([23068679]), known)
	check("a window gamescope can no longer focus is forgotten", record, emulator)
	check("so the next launch's window with that id is new again", FocusOffers.fresh(ids([67108865, 23068679]), known, record), game)
	check("an empty list forgets all", FocusOffers.remember(ids([]), known), ids([]))
	quit(1 if failed else 0)
GD
  out="$(HOME="$T/home" XDG_CONFIG_HOME="$T/config" timeout 60 "$GODOT" --headless --path "$P64" --script res://focus_offers_test.gd 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
fi

CASE="game beside (0065)"
if [ -z "$GODOT" ]; then
  printf '  skip %s -- no Godot (set RETROFORGE_GODOT to a Godot 4 binary)\n' "$CASE"
else
  P65="$T/p65"; mkdir -p "$P65"
  added_file "$P0065" core/ui/card_ui/launch/game_beside.gd > "$P65/game_beside.gd"
  grep -q '^static func beside(' "$P65/game_beside.gd" \
    && ok "the patch adds core/ui/card_ui/launch/game_beside.gd" || bad "game_beside.gd not found in the patch"
  # The page takes L1 and R1 (OGUI's tab actions) only while it is the menu shown, and the library's
  # tab header, which has them in the library, is left alone.
  grep -q '^+	var step := int(event.is_action_pressed("ogui_tab_right")) - int(event.is_action_pressed("ogui_tab_left"))$' "$P0065" \
    && [ "$(grep -c '^+	set_process_input(false)$' "$P0065" | tr -d ' ')" -eq 2 ] \
    && ok "the game page steps on L1 and R1, and only while it is shown" || bad "the game page does not take L1 and R1, or takes them while hidden"
  ! grep -q '^diff --git a/core/ui/components/tabs_header' "$P0065" \
    && ok "the tab header's own script is untouched: L1 and R1 still change tab in the library" || bad "the patch touches the tab header's script"
  # The header fades out for a moment after the library is left and took an R1 pressed then (the
  # library changed tab behind the page, Air X): its input stops with the library.
  grep -q '^+	tabs_container.set_process_input(false)$' "$P0065" && grep -q '^+	tabs_container.set_process_input(true)$' "$P0065" \
    && ok "the library's tabs give up L1 and R1 as the library is left and take them back when it is entered" \
    || bad "the library's tabs still take L1 and R1 while they fade out"
  # The bottom bar names the two buttons, hidden until the page says a game is that way, and the
  # page says so each time it shows a game and takes them away as it is left.
  grep -q '^+func show_game_steps(previous: bool, next: bool) -> void:$' "$P0065" \
    && [ "$(grep -c '^+visible = false$' "$P0065" | tr -d ' ')" -eq 2 ] \
    && grep -q '^+text = "Previous"$' "$P0065" && grep -q '^+text = "Next"$' "$P0065" \
    && ok "the bottom bar has Previous and Next, hidden until asked for" || bad "the bottom bar's Previous and Next are missing or shown everywhere"
  grep -q '^+	_hint_steps(true)$' "$P0065" && grep -q '^+	_hint_steps(false)$' "$P0065" \
    && ok "the page shows them with each game and hides them as it is left" || bad "the page does not show or does not hide the bottom bar's hints"
  # Two games' art can load at once now: the one no longer shown must not set its art.
  [ "$(grep -c '^+	if launcher_state.data.get("item") != library_item:$' "$P0065" | tr -d ' ')" -eq 2 ] \
    && ok "art that arrives for a game no longer shown is dropped" || bad "a late logo or banner can still land on another game's page"
  printf 'config_version=5\n[application]\nconfig/name="ogui-patches-test"\n' > "$P65/project.godot"
  cat > "$P65/game_beside_test.gd" <<GD
extends SceneTree
# Home's row: a spacer, the games' cards, the Library card, a spacer. A game is any object here.

const GameBeside := preload("res://game_beside.gd")
var failed := 0


class FakeCard extends Control:
	var library_item: Object


func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)


func card(row: Array, game: Object) -> FakeCard:
	var c := FakeCard.new()
	c.library_item = game
	row.append(c)
	return c


func _init() -> void:
	var games := []
	for i in 8:
		games.append(RefCounted.new())
	var row := [Control.new()]
	var cards := []
	for i in 4:
		cards.append(card(row, games[i]))
	row.append(Control.new())  # the Library card: no game
	row.append(Control.new())
	check("R1: the game after", GameBeside.beside(row, games[0], 1), cards[1])
	check("L1: the game before", GameBeside.beside(row, games[1], -1), cards[0])
	check("L1 on the first game: none (the spacer is no game)", GameBeside.beside(row, games[0], -1), null)
	check("R1 on the last game: none (the Library card is no game)", GameBeside.beside(row, games[3], 1), null)
	check("a game with no card in the row: none", GameBeside.beside(row, games[7], 1), null)
	check("no game: none", GameBeside.beside(row, null, 1), null)
	cards[2].visible = false
	check("a card a search has hidden is passed over", GameBeside.beside(row, games[1], 1), cards[3])
	check("in both directions", GameBeside.beside(row, games[3], -1), cards[1])
	check("and has no neighbours itself", GameBeside.beside(row, games[2], 1), null)
	cards[2].visible = true
	cards[1].queue_free()
	check("a card being removed is passed over", GameBeside.beside(row, games[0], 1), cards[2])
	# A library grid, six cards to a row: the order its cards are laid out in.
	var grid := []
	var grid_cards := []
	for i in 8:
		grid_cards.append(card(grid, games[i]))
	check("R1 at the end of a grid's row: the first game of the next row", GameBeside.beside(grid, games[5], 1), grid_cards[6])
	check("L1 at the start of a row: the last game of the row above", GameBeside.beside(grid, games[6], -1), grid_cards[5])
	check("card_of: the game's card", GameBeside.card_of(grid, games[4]), grid_cards[4])
	check("card_of: none for a game not there", GameBeside.card_of(row, games[6]), null)
	quit(1 if failed else 0)
GD
  out="$(HOME="$T/home" XDG_CONFIG_HOME="$T/config" timeout 60 "$GODOT" --headless --path "$P65" --script res://game_beside_test.gd 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
fi

CASE="shown disks (0066)"
if [ -z "$GODOT" ]; then
  printf '  skip %s -- no Godot (set RETROFORGE_GODOT to a Godot 4 binary)\n' "$CASE"
else
  P66="$T/p66"; mkdir -p "$P66"
  added_file "$P0066" core/systems/disks/shown_disks.gd > "$P66/shown_disks.gd"
  grep -q '^static func partitions(' "$P66/shown_disks.gd" \
    && ok "the patch adds core/systems/disks/shown_disks.gd" || bad "shown_disks.gd not found in the patch"
  # The menu builds from ShownDisks, not from udisks2's unprotected devices (which leave out the disk
  # holding /home and are read over D-Bus partition by partition), and a drive card shows only the
  # partitions it is given.
  grep -q '^+	var shown := ShownDisks.partitions(ShownDisks.read_file("/proc/self/mounts"))$' "$P0066" \
    && grep -q '^-	_on_drives_updated(udisks2.get_unprotected_devices())$' "$P0066" \
    && ! grep -q '^+.*get_unprotected_devices' "$P0066" \
    && ok "the menu shows what ShownDisks names, without udisks2's unprotected devices" \
    || bad "the menu still builds from udisks2's unprotected devices"
  grep -q '^+		if not shown_partitions.is_empty() and partition.dbus_path not in shown_partitions:$' "$P0066" \
    && ok "a drive card shows only the partitions it is given" || bad "a drive card still shows every partition"
  grep -q '^+	var main := ShownDisks.main_mount(ShownDisks.read_file("/proc/self/mountinfo"),$' "$P0066" \
    && grep -q '^+		mounts = PackedStringArray(\[main\])$' "$P0066" \
    && ok "a partition card shows its main mount point alone, not udisks2's bind mounts" \
    || bad "a partition card still lists every bind mount (/opt, /root, /var/log, ...)"
  grep -q '^+		var space := ShownDisks.free_of_total(mounts\[0\])$' "$P0066" \
    && ok "a mounted partition's size is its free space of its size" || bad "a partition card shows no free space"
  # An SD card is mounted after udisks2 reports it, with no signal: the mount table is read at each show.
  grep -q '^+		_stale = true$' "$P0066" \
    && ok "the menu reads the mount table again each time it is shown" || bad "the menu keeps cards built before an SD card was mounted"
  grep -q '^+	if ShownDisks.partitions(ShownDisks.read_file("/proc/self/mounts")) != _shown:$' "$P0066" \
    && grep -q '^+		_mounts_timer.stop()$' "$P0066" && grep -q '^+	_mounts_timer.start()$' "$P0066" \
    && ok "and while it is shown, so a card mounted then (inserted, or formatted here) appears" \
    || bad "a card mounted while the menu is shown stays missing until it is shown again"

  # Fake /sys and /dev. part <disk> <partition> <host path>: a partition in sysfs, its class/block link
  # relative like the kernel's. disk <disk> [SD|MMC]: a disk, with the MMC core's type for mmcblk.
  SYS="$P66/sys"; DEV="$P66/dev"; mkdir -p "$SYS/block" "$SYS/class/block" "$DEV/disk/by-partlabel"
  disk() {
    mkdir -p "$SYS/devices/$1/block/$1"
    ln -s "../devices/$1/block/$1" "$SYS/block/$1"
    ln -s "../../devices/$1/block/$1" "$SYS/class/block/$1"
    if [ -n "${2:-}" ]; then mkdir -p "$SYS/devices/$1/device"; echo "$2" > "$SYS/devices/$1/device/type"
      ln -s ../../device "$SYS/devices/$1/block/$1/device"; fi
  }
  part() {
    mkdir -p "$SYS/devices/$1/block/$1/$2"; echo "${2##*[a-z]}" > "$SYS/devices/$1/block/$1/$2/partition"
    ln -s "../../devices/$1/block/$1/$2" "$SYS/class/block/$2"
  }
  disk sda; for n in 1 2 17; do part sda sda$n; done      # UFS LUN 0: the vendor's, and an install's /home
  disk sde; part sde sde4                                 # UFS LUN 4: firmware
  disk mmcblk0 MMC; part mmcblk0 mmcblk0p70               # SM6115 eMMC: an install's /home
  disk mmcblk1 SD; for n in 1 2 8; do part mmcblk1 mmcblk1p$n; done   # SD card
  ln -s ../../sda17 "$DEV/disk/by-partlabel/retroforge-home"
  printf 'config_version=5\n[application]\nconfig/name="ogui-patches-test"\n' > "$P66/project.godot"
  cat > "$P66/shown_disks_test.gd" <<GD
extends SceneTree

const ShownDisks := preload("res://shown_disks.gd")
const SYS := "$SYS"
const DEV := "$DEV"
var failed := 0


func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)


func shown(mounts: Array) -> Dictionary:
	return ShownDisks.partitions("\n".join(mounts) + "\n", SYS, DEV)


func _init() -> void:
	var common := ["proc /proc proc rw 0 0", "tmpfs /tmp tmpfs rw 0 0", "overlay /etc overlay rw 0 0"]
	# Booted from the SD card: its root, ESP and /home are all on it.
	check("a card boot: /home's partition alone, not the card's system partitions",
		shown(common + ["/dev/mmcblk1p2 / erofs ro 0 0", "/dev/mmcblk1p1 /esp vfat rw 0 0",
			"/dev/mmcblk1p8 /home ext4 rw 0 0"]), {"mmcblk1": ["mmcblk1p8"]})
	# Installed on UFS, an SD card mounted for the player (and bound for the network share).
	var ufs := common + ["/dev/sda2 / erofs ro 0 0", "/dev/sda1 /esp vfat rw 0 0",
		"/dev/sde4 /usr/lib/firmware/qcom vfat ro 0 0", "/dev/sda17 /home ext4 rw 0 0"]
	check("a UFS install: /home's partition, then the SD card's",
		shown(ufs + ["/dev/mmcblk1p1 /run/media/player/GAMES exfat rw 0 0",
			"/dev/mmcblk1p1 /run/retroforge/sdcard exfat rw 0 0"]), {"sda": ["sda17"], "mmcblk1": ["mmcblk1p1"]})
	check("the order is /home's disk first whatever the mount order",
		shown(["/dev/mmcblk1p1 /run/media/player/GAMES exfat rw 0 0"] + ufs).keys(), ["sda", "mmcblk1"])
	check("with no SD card mounted: /home's alone", shown(ufs), {"sda": ["sda17"]})
	check("each of an SD card's mounted partitions, once",
		shown(ufs + ["/dev/mmcblk1p1 /run/media/player/A ext4 rw 0 0", "/dev/mmcblk1p2 /run/media/player/B ext4 rw 0 0"]),
		{"sda": ["sda17"], "mmcblk1": ["mmcblk1p1", "mmcblk1p2"]})
	# Installed on the eMMC of an SM6115 board: an mmcblk too, typed MMC.
	check("an eMMC install: the eMMC is not taken for an SD card",
		shown(common + ["/dev/mmcblk0p70 /home ext4 rw 0 0", "/dev/mmcblk1p1 /run/media/player/GAMES exfat rw 0 0"]),
		{"mmcblk0": ["mmcblk0p70"], "mmcblk1": ["mmcblk1p1"]})
	check("/home mounted through a /dev/disk link", shown(["/dev/disk/by-partlabel/retroforge-home /home ext4 rw 0 0"]),
		{"sda": ["sda17"]})
	check("nothing at /home: nothing", shown(common + ["/dev/mmcblk1p1 /run/media/player/GAMES exfat rw 0 0"]), {})
	check("a whole disk at /home is no partition: nothing", shown(["/dev/sde /home ext4 rw 0 0"]), {})
	check("an empty mount table: nothing", ShownDisks.partitions("", SYS, DEV), {})
	check("disk_of: the partition's disk", ShownDisks.disk_of("sda17", SYS), "sda")
	check("disk_of: none for a disk", ShownDisks.disk_of("sda", SYS), "")
	check("disk_of: none for an unknown name", ShownDisks.disk_of("nvme9n1p1", SYS), "")
	check("is_sd_card: a card", ShownDisks.is_sd_card("mmcblk1", SYS), true)
	check("is_sd_card: not an eMMC", ShownDisks.is_sd_card("mmcblk0", SYS), false)
	check("is_sd_card: not UFS", ShownDisks.is_sd_card("sda", SYS), false)
	# /proc/self/mountinfo on a card boot (Pocket ACE): /home's partition, then its offload binds.
	var info := "\n".join([
		"33 1 0:30 / / ro,relatime shared:1 - btrfs /dev/mmcblk1p4 ro",
		"110 33 179:8 / /home rw,relatime shared:222 - ext4 /dev/mmcblk1p8 rw",
		"116 33 179:8 /.retroforge/offload/root /root rw,relatime shared:222 - ext4 /dev/mmcblk1p8 rw",
		"299 33 179:8 /.retroforge/offload/opt /opt rw,relatime shared:222 - ext4 /dev/mmcblk1p8 rw",
		"300 33 0:40 / /tmp rw shared:5 - tmpfs tmpfs rw",
		"301 40 179:1 / /run/media/player/MY\\\\040GAMES rw,nosuid shared:7 - exfat /dev/mmcblk1p1 rw",
		"302 40 179:1 / /run/retroforge/sdcard rw,nosuid shared:7 - exfat /dev/mmcblk1p1 rw",
		"303 33 8:17 / /home rw shared:9 - ext4 /dev/disk/by-partlabel/retroforge-home rw"]) + "\n"
	check("main_mount: /home, not the binds of its directories", ShownDisks.main_mount(info, "mmcblk1p8", DEV), "/home")
	check("main_mount: an SD card's own mount, not the share's bind of it, spaces decoded",
		ShownDisks.main_mount(info, "mmcblk1p1", DEV), "/run/media/player/MY GAMES")
	check("main_mount: through a /dev/disk link", ShownDisks.main_mount(info, "sda17", DEV), "/home")
	check("main_mount: none for a partition not mounted", ShownDisks.main_mount(info, "mmcblk1p2", DEV), "")
	check("main_mount: none from an empty table", ShownDisks.main_mount("", "mmcblk1p8", DEV), "")
	check("space_text: free of total, from df --output=size,avail",
		ShownDisks.space_text("     1B-blocks        Avail\n24728096768 24652804096\n"), "24.65 GB free of 24.73 GB")
	check("space_text: nothing from df's error output", ShownDisks.space_text("df: /x: No such file or directory\n"), "")
	check("space_text: nothing from a header alone", ShownDisks.space_text("1B-blocks Avail\n"), "")
	check("readable_size: decimal units, as udisks2 shows them", ShownDisks.readable_size(25575796736), "25.58 GB")
	check("readable_size: small sizes in bytes", ShownDisks.readable_size(512), "512.00 B")
	check("readable_size: a terabyte card", ShownDisks.readable_size(1024209543168), "1.02 TB")
	quit(1 if failed else 0)
GD
  out="$(HOME="$T/home" XDG_CONFIG_HOME="$T/config" timeout 60 "$GODOT" --headless --path "$P66" --script res://shown_disks_test.gd 2>&1)"; rc=$?
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
