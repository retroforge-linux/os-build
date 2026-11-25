extends RefCounted
## Settings > General > "Time zone", under OGUI's Language: the system's zone (the /etc/localtime link),
## set with timedatectl. polkit's 50-retroforge-timezone.rules lets the session set it without a password.
## The link lives in /var's /etc overlay, so it survives a restart and an update.
##
## The list (time_zones.gd) is read at the page's first visit, not at start, and the selection at every
## one: the zone can also be set over ssh.
##
## Anything started after the change has the new zone; OGUI itself does not. Godot asks glibc for the
## time with localtime_r, which reads /etc/localtime once per process, and nothing in Godot calls tzset
## (4.7.1 on the image's glibc, 2026-11-25). So once the zone is another than at start, the context bar's
## clock, the only local time OGUI shows, is computed here until OGUI restarts: on OGUI's own timer, in
## place of its handler.

const TimeZones := preload("time_zones.gd")
const GeneralBox := preload("general_box.gd")
const TIMEDATECTL := "timedatectl"
const LOCALTIME := "/etc/localtime"

## Test seams (tests/test-plugin.sh).
var timedatectl := TIMEDATECTL
var zoneinfo := TimeZones.ZONEINFO
var localtime := LOCALTIME

var notification_manager := load("res://core/global/notification_manager.tres") as NotificationManager
var dropdown_scene := load("res://core/ui/components/dropdown.tscn") as PackedScene
var general_settings_state := load("res://assets/state/states/settings_general.tres") as State
var logger := Log.get_logger("RetroForgeTimeZone", Log.LEVEL.INFO)
var tree: SceneTree
var _row: Control  # OGUI Dropdown
var _zones: Array = []  # the zone of each item
var _bar: Node  # OGUI's context bar, while its clock is ours
var _timer: Timer  # the bar's
var _clock_zone := ""  # the zone OGUI's clock shows
var _clock: PackedByteArray  # its file, while the clock is ours


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	return self


## Add the row under Settings > General's Language. False when the layout differs or there is no tzdata.
func attach() -> bool:
	var menu: Node = tree.root.find_child("GeneralSettings", true, false)
	var box: Node = GeneralBox.find(menu)
	var after: Node = box.get_node_or_null("LanguageDropdown") if box else null
	if not after or not FileAccess.file_exists(zoneinfo.path_join(TimeZones.TABLE)):
		return false
	_row = dropdown_scene.instantiate()
	_row.name = "RetroForgeTimeZone"
	_row.title = "Time zone"
	_row.description = "System time zone. Running games and apps follow once they are restarted."
	box.add_child(_row)
	box.move_child(_row, after.get_index() + 1)
	_row.item_selected.connect(_on_selected)
	general_settings_state.state_entered.connect(_on_general_entered)
	_clock_zone = current()
	return true


func detach() -> void:
	if general_settings_state.state_entered.is_connected(_on_general_entered):
		general_settings_state.state_entered.disconnect(_on_general_entered)
	_release_clock()
	if is_instance_valid(_row):
		_row.queue_free()


## The zone in force.
func current() -> String:
	var dir := DirAccess.open(localtime.get_base_dir())
	return TimeZones.zone_of_link(dir.read_link(localtime.get_file()) if dir else "")


func _on_general_entered(_from: State) -> void:
	if not _row.disabled:
		_show()


## Selects the zone in force, listing the zones first when it is not among them, and has OGUI's clock
## follow it.
func _show() -> void:
	var zone := current()
	if not _zones.has(zone):
		_fill(zone)
	_row.select(_zones.find(zone))
	if zone != _clock_zone:
		_take_clock(zone)


func _fill(zone: String) -> void:
	_zones.clear()
	_row.clear()  # dropdown.tscn ships one placeholder item
	for choice in TimeZones.choices(zoneinfo, zone, int(Time.get_unix_time_from_system())):
		_row.add_item(choice["label"])
		_row.option_button.set_item_metadata(_zones.size(), choice["zone"])
		_zones.append(choice["zone"])


func _on_selected(index: int) -> void:
	if index < 0 or index >= _zones.size() or _zones[index] == current():
		_show()
		return
	var zone: String = _zones[index]
	_row.disabled = true
	var cmd := Command.create(timedatectl, ["--no-ask-password", "set-timezone", zone])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	if not is_instance_valid(_row) or _row.is_queued_for_deletion():  # detached while it ran
		return
	_row.disabled = false
	_show()
	if code != 0:
		logger.warn("timedatectl set-timezone %s exited %d: %s" % [zone, code, cmd.stderr])
		notification_manager.show(Notification.new("Could not set the time zone"))
		return
	logger.info("time zone set to " + zone)


## From here on OGUI's clock shows `zone`.
func _take_clock(zone: String) -> void:
	_clock_zone = zone
	_clock = TimeZones.read(zoneinfo, zone)
	if not is_instance_valid(_bar):
		var bar := _find_bar()
		if not bar:
			logger.warn("OGUI's clock not found; it shows the old time zone until a restart")
			return
		for child in bar.get_children():
			if child is Timer and child.timeout.is_connected(bar._on_update_time):
				_bar = bar
				_timer = child
		if not is_instance_valid(_bar):
			logger.warn("OGUI's clock has no timer; it shows the old time zone until a restart")
			return
		_timer.timeout.disconnect(_bar._on_update_time)
		_timer.timeout.connect(_update_clock)
	_update_clock()


## OGUI's context bar. Not just the first node of that name: Settings > Logging has a row per logger,
## named after it, and the context bar's row comes before it in the tree.
func _find_bar() -> Node:
	for node in tree.root.find_children("ContextBar", "PanelContainer", true, false):
		if node.has_method("_on_update_time") and node.has_method("_format_time"):
			return node
	return null


func _release_clock() -> void:
	if is_instance_valid(_timer) and is_instance_valid(_bar):
		_timer.timeout.disconnect(_update_clock)
		_timer.timeout.connect(_bar._on_update_time)
	_bar = null
	_timer = null


func _update_clock() -> void:
	_bar.time_label.text = _bar._format_time(TimeZones.local_time(_clock, int(Time.get_unix_time_from_system())))
