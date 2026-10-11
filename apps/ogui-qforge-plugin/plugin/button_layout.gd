extends RefCounted
## Settings > Controller > "Nintendo button layout": swaps A with B and X with Y on the Xbox
## target, so the bottom face button sends B (back) and the right one A (accept), as on a Switch.
## The swap applies everywhere the pad goes, games and the OGUI menus alike, since both read
## the InputPlumber target after the profile has mapped the buttons.
##
## OpenGamepadUI writes the profile it loads into InputPlumber itself, as a target copy of the
## global or per-game profile ("<profile>_<target>.json"), on every app launch, switch and stop.
## The swap is composed onto whatever it loaded: every mapping whose one target is a face button
## gets the swapped button (chords such as Guide+East for the quick access button are shortcuts
## and stay), and a face button the profile leaves alone is mapped to its partner. The result is saved next to it as "<copy>_nintendo.json" and loaded in its place;
## the "_nintendo" suffix is how a later check knows the device already has the swap. The
## profiles OGUI edits stay untouched, so turning the layout off just reloads OGUI's copy.
##
## OGUI gives no signal when it loads a profile, so the device is checked (one busctl call)
## shortly after each launch, switch and stop, after Settings > Gamepad closes, and at startup.
## Stored in OGUI's settings, section "qforge", key "nintendo_layout".
##
## A profile is never swapped while a button is held. InputPlumber drops a release it never saw
## pressed, so a button held across the swap (the A press on the toggle itself) had its release
## come out as its partner's: A stayed down for games and menus. Held buttons are tracked from
## the InputPlumber D-Bus target (what the menus receive); the swap waits for them, MAX_WAIT at
## most.

const SECTION := "qforge"
const KEY := "nintendo_layout"
const SUFFIX := "_nintendo.json"
const SWAP := {
	"Gamepad:Button:South": "Gamepad:Button:East", "Gamepad:Button:East": "Gamepad:Button:South",
	"Gamepad:Button:West": "Gamepad:Button:North", "Gamepad:Button:North": "Gamepad:Button:West",
}
const IP_BUS := "org.shadowblip.InputPlumber"
const IP_IFACE := "org.shadowblip.Input.CompositeDevice"

var settings := load("res://core/global/settings_manager.tres") as SettingsManager
var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
var input_plumber := load("res://core/systems/input/input_plumber.tres") as InputPlumberInstance
var gamepad_settings_state := load("res://assets/state/states/gamepad_settings.tres") as State
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var logger := Log.get_logger("QForgeButtons", Log.LEVEL.INFO)
var tree: SceneTree
var _toggle: Control  # OGUI Toggle
var _timer: Timer
var _held := {}  # InputPlumber D-Bus event names currently pressed
var _waited := 0.0
const POLL := 0.1
const MAX_WAIT := 3.0


## Start watching OGUI's profile loads and apply the stored choice.
func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = 0.5
	_timer.timeout.connect(_on_timer)
	tree.root.add_child(_timer)
	for device in input_plumber.get_composite_devices():
		_watch(device)
	input_plumber.composite_device_added.connect(_watch)
	launch_manager.app_launched.connect(_recheck.unbind(1))
	launch_manager.app_stopped.connect(_recheck.unbind(1))
	launch_manager.app_switched.connect(_recheck.unbind(2))
	launch_manager.all_apps_stopped.connect(_recheck)
	gamepad_settings_state.state_exited.connect(_recheck.unbind(1))
	_recheck()
	return self


## Add the toggle under Settings > Controller's Gamepad Settings button. False when the menu
## is not laid out as expected.
func attach() -> bool:
	var menu: Node = tree.root.find_child("GeneralControllerSettings", true, false)
	var box: Node = menu.get_node_or_null("MarginContainer/VBoxContainer") if menu else null
	if not box:
		return false
	_toggle = toggle_scene.instantiate()
	_toggle.name = "QForgeNintendoLayout"
	_toggle.text = "Nintendo button layout"
	_toggle.description = "Swap A with B and X with Y: the bottom button goes back, the right one confirms. Applies to games and these menus."
	box.add_child(_toggle)
	_toggle.button_pressed = enabled()
	_toggle.toggled.connect(func(on: bool):
		settings.set_value(SECTION, KEY, on)
		_recheck())
	return true


func detach() -> void:
	if is_instance_valid(_toggle):
		_toggle.queue_free()
	if is_instance_valid(_timer):
		_timer.queue_free()


func enabled() -> bool:
	return settings.get_value(SECTION, KEY, false) as bool


func _recheck() -> void:
	if is_instance_valid(_timer):
		_waited = 0.0
		_timer.start(0.5)


func _on_timer() -> void:
	if not _held.is_empty() and _waited < MAX_WAIT:
		_waited += POLL
		_timer.start(POLL)
		return
	apply()


func _watch(device) -> void:
	for target in device.dbus_devices:
		if not target.input_event.is_connected(_on_input_event):
			target.input_event.connect(_on_input_event)


func _on_input_event(event: String, value: float) -> void:
	if value > 0.5:
		_held[event] = true
	else:
		_held.erase(event)


## Bring every gamepad's loaded profile in line with the setting.
func apply() -> void:
	var on := enabled()
	for device in input_plumber.get_composite_devices():
		var loaded := _profile_path(device.dbus_path)
		if loaded.is_empty():
			continue
		var swapped := loaded.ends_with(SUFFIX)
		if on and not swapped:
			var out := loaded.trim_suffix(".json") + SUFFIX
			if _write_swapped(loaded, out):
				device.load_profile_path(out)
				logger.info("Nintendo layout on: " + out)
		elif swapped and not on:
			var base := loaded.trim_suffix(SUFFIX) + ".json"
			if FileAccess.file_exists(base):
				device.load_profile_path(base)
				logger.info("Nintendo layout off: " + base)


func _profile_path(dbus_path: String) -> String:
	var out := []
	var args := ["--system", "get-property", IP_BUS, dbus_path, IP_IFACE, "ProfilePath"]
	if OS.execute("busctl", args, out, true) != 0 or out.is_empty():
		return ""
	# 's "/home/player/.../global_default_xbox-elite.json"'
	var line := (out[0] as String).strip_edges()
	return line.trim_prefix("s ").trim_prefix("\"").trim_suffix("\"")


func _write_swapped(src: String, dst: String) -> bool:
	var profile := InputPlumberProfile.load(src)
	if not profile:
		logger.warn("could not read gamepad profile " + src)
		return false
	swap_profile(profile)
	if profile.save(dst) != OK:
		logger.warn("could not write " + dst)
		return false
	return true


## Swap A/B and X/Y after the profile's own mapping, in place. Through OGUI's profile classes,
## so the file is written exactly as OGUI writes its own.
static func swap_profile(profile: InputPlumberProfile) -> void:
	var mapped := {}
	for m in profile.mapping:
		mapped[m.source_event.to_capability()] = true
		# One target only: a chord (Guide+East for the quick access button) is a shortcut,
		# not a face-button press, and stays as it is.
		if m.target_events.size() != 1:
			continue
		var target: InputPlumberEvent = m.target_events[0]
		var cap := target.to_capability()
		if SWAP.has(cap):
			target.set_capability(SWAP[cap])
	for cap in SWAP:
		if not mapped.has(cap):
			var m := InputPlumberMapping.from_source_capability(cap)
			m.target_events = [InputPlumberEvent.from_capability(SWAP[cap])]
			profile.mapping.append(m)
