extends RefCounted
## Settings > Library > "RetroAchievements": the player's one RetroAchievements account and hardcore
## mode, for RetroArch (gb, gbc, gba, snes, md, segacd, n64; plan retroarch) and the standalone
## emulators that have RetroAchievements (DuckStation, ARMSX2, PPSSPP, Dolphin, Flycast; plan
## standalone-cheevos): the launcher writes it into each at its next start (the achievements module).
##
## Everything goes through /usr/bin/retroforge-cheevos. The password goes to the tool on stdin
## (scrape_runner.gd, the ScreenScraper sign-in's runner) and is cleared from the field after every
## attempt; only the token RetroAchievements answers with is kept, in RetroForge's own 0600
## ~/.config/retroforge/retroachievements.json, never in OGUI's settings. No emulator's file is
## written from here, so a change is allowed while a game runs (it reaches that emulator next time).

const ScrapeRunner := preload("scrape_runner.gd")
const CheevosText := preload("cheevos_text.gd")
const TOOL := "/usr/bin/retroforge-cheevos"
const HARDCORE_TEXT := "Achievements count for more, but save states, rewind and cheats are off."

var notification_manager := load("res://core/global/notification_manager.tres")
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var section_scene := load("res://core/ui/components/section_label.tscn") as PackedScene
var button_scene := load("res://core/ui/components/card_button_setting.tscn") as PackedScene
var input_scene := load("res://core/ui/components/text_input.tscn") as PackedScene

var logger := Log.get_logger("RetroForgeCheevos", Log.LEVEL.INFO)
var tree: SceneTree
var _login := ScrapeRunner.new()  # a field: a runner must outlive its worker thread
var _nodes: Array[Node] = []
var _user: Control  # text_input
var _password: Control
var _account: Control  # card_button_setting
var _hardcore: Control  # toggle
var _status := {}  # `retroforge-cheevos status`
var _syncing := false  # _refresh() setting the toggle: not the player's change


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	_login.tool = TOOL
	_login.finished.connect(_on_login_finished)
	return self


## Add the section under Settings > Library's Refresh Library. False when the layout differs.
func attach() -> bool:
	var menu: Node = tree.root.find_child("LibrarySettingsMenu", true, false)
	var box: Node = menu.get_node_or_null("MarginContainer/VBoxContainer") if menu else null
	if not box:
		return false
	var at: int = box.get_node("RefreshLibraryButton").get_index() + 1 if box.has_node("RefreshLibraryButton") else box.get_child_count()
	var label = section_scene.instantiate()
	label.text = "RetroAchievements"
	_user = input_scene.instantiate()
	_user.title = "RetroAchievements user name"
	_user.description = "Earn achievements in %s games." % CheevosText.SYSTEMS
	_password = input_scene.instantiate()
	_password.title = "RetroAchievements password"
	_password.description = ""
	_password.secret = true
	_account = button_scene.instantiate()
	_account.text = "RetroAchievements account"
	_account.button_text = "Sign in"
	_account.description = CheevosText.NOT_SIGNED_IN
	_account.pressed.connect(_on_account_pressed)
	_hardcore = toggle_scene.instantiate()
	_hardcore.text = "Hardcore mode"
	_hardcore.description = HARDCORE_TEXT
	# In the tree FIRST (scraper_settings.gd: a component's @onready children only exist once ready,
	# and OGUI's release export segfaults on a method call to one that is still null).
	for node in [label, _user, _password, _account, _hardcore]:
		box.add_child(node)
		box.move_child(node, at)
		at += 1
		_nodes.append(node)
	_hardcore.toggled.connect(_on_hardcore_toggled)
	_refresh()
	return true


func detach() -> void:
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()


## Read the account (no network) and set every row from it.
func _refresh() -> void:
	var out := []
	_status = {}
	var available := FileAccess.file_exists(TOOL)
	if available and OS.execute(TOOL, ["status"], out) == 0 and not out.is_empty():
		var data = JSON.parse_string(str(out[0]))
		_status = data if data is Dictionary else {}
	var signed_in: bool = _status.get("signed_in", false) == true
	for row in [_user, _password, _account, _hardcore]:
		row.set("disabled", not available)
	_user.visible = not signed_in
	_password.visible = not signed_in
	_account.button_text = "Sign out" if signed_in else "Sign in"
	_account.description = CheevosText.account_text(_status) if available else CheevosText.failure_text(-1, "")
	_syncing = true
	_hardcore.button_pressed = _status.get("hardcore", false) == true
	_syncing = false


func _on_account_pressed() -> void:
	if _login.running:
		return
	if _status.get("signed_in", false) == true:
		_run([TOOL, "logout"], "Signed out of RetroAchievements.")
		return
	var user: String = _user.text.strip_edges()
	var password: String = _password.text
	if user == "" or password == "":
		_notify(CheevosText.failure_text(2, ""))
		return
	_account.description = "Checking with RetroAchievements..."
	_login.start(["login", user], password)


func _on_login_finished(code: int, summary: Dictionary, error: String) -> void:
	_password.text = ""
	if code == 0:
		_notify("Signed in to RetroAchievements as %s." % str(summary.get("user", _user.text.strip_edges())))
	else:
		logger.warn("retroforge-cheevos login exited %d" % code)
		_notify(CheevosText.failure_text(code, error))
	_refresh()


func _on_hardcore_toggled(on: bool) -> void:
	if _syncing:
		return
	_run([TOOL, "hardcore", "on" if on else "off"],
		"Hardcore mode on: achievements count for more." if on else "Hardcore mode off.")


## A quick tool run (logout, hardcore: local files only): notify its outcome, then re-read.
func _run(command: Array, done_text: String) -> void:
	var out := []
	var code := OS.execute(command[0], command.slice(1), out, true)
	if code == 0:
		_notify(done_text)
	else:
		logger.warn("retroforge-cheevos %s exited %d: %s" % [" ".join(command.slice(1)), code, "".join(out)])
		_notify(CheevosText.failure_text(code, "".join(out)))
	_refresh()


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))
