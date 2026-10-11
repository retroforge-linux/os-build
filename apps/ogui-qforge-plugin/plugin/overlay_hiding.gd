extends RefCounted
## Takes the shell's window out of gamescope's frame while a game has the foreground.
##
## In game OpenGamepadUI hides its contents but keeps its window: a fully transparent,
## output-sized layer that gamescope still scans out on a display pipe. The MANGMI Air X's
## SM6115 has two (one VIG that can scale, for the game, and one DMA), so that empty layer took
## the only free pipe, and any third layer -- the performance overlay, a toast -- pushed the frame
## onto the GPU composite. Opacity 0 is gamescope's "fully hidden" signal (Steam's overlay uses
## it): the window is not painted and the pipe stays free.
##
## The window is shown again before anything is drawn in it: when the in-game state is left (a
## menu, the quick bar, the keyboard, or the game ended), while an in-game toast is up, and while
## the volume indicator is (gamescope sends the volume keys to the shell even in game).
## xprop runs as a separate process so the main loop never waits on it. It takes 60-80 ms on an
## A53, so the window is shown already on the Guide PRESS (expect_ui): OGUI opens its menu on the
## release, by which time the window is back in the frame. If no menu follows, it hides again.

const OPACITY := "_NET_WM_WINDOW_OPACITY"

var gamescope := load("res://core/systems/gamescope/gamescope.tres") as GamescopeInstance
const Spawn := preload("spawn.gd")
var notification_manager := load("res://core/global/notification_manager.tres") as NotificationManager
var audio_manager := load("res://core/global/audio_manager.tres") as AudioManager
var logger := Log.get_logger("QForgeOverlay", Log.LEVEL.INFO)
var _window := 0
var _toast: Node  # OGUI's InGameNotification
var _volume: Node  # OGUI's VolumeIndicator
var _volume_showing := false
var _in_game := false
var _hidden := false
var _toast_showing := false
var _expecting_ui := false


func setup(tree: SceneTree) -> RefCounted:
	var xwayland := gamescope.get_xwayland(gamescope.XWAYLAND_TYPE_OGUI)
	if xwayland:
		var ids := xwayland.get_windows_for_pid(OS.get_process_id())
		if not ids.is_empty():
			_window = ids[0]
	if _window == 0:
		logger.warn("shell window not found; it stays in gamescope's frame during games")
		return self
	_toast = tree.root.find_child("InGameNotification", true, false)
	notification_manager.notification_queued.connect(_on_toast_queued)
	if _toast and _toast.get("effect"):
		_toast.effect.slide_out_finished.connect(_on_toast_gone)
	_volume = tree.root.find_child("VolumeIndicator", true, false)
	audio_manager.volume_changed.connect(_on_volume_shown)
	if _volume and _volume.get("timer"):
		_volume.timer.timeout.connect(_on_volume_gone)
	return self


func _on_volume_shown(_value: float) -> void:
	_volume_showing = true
	_update()


func _on_volume_gone() -> void:
	_volume_showing = false
	_update()


func _on_toast_queued(_notify) -> void:
	_toast_showing = true
	_update()


# OGUI starts the next queued toast from this same signal (connected first), so the panel is
# already visible again if one was waiting.
func _on_toast_gone() -> void:
	var panel = _toast.get("panel") if is_instance_valid(_toast) else null
	_toast_showing = panel != null and panel.visible
	_update()


## Guide was pressed in game: a menu is likely on the release. Show the window now; hide it again
## after a second if the game still has the foreground.
func expect_ui() -> void:
	if not _in_game or _expecting_ui:
		return
	_expecting_ui = true
	_update()
	Engine.get_main_loop().create_timer(1.0).timeout.connect(func():
		_expecting_ui = false
		_update())


func set_in_game(in_game: bool) -> void:
	_in_game = in_game
	_update()


func detach() -> void:
	_in_game = false
	_update()


func _update() -> void:
	if _window == 0:
		return
	var hide := _in_game and not _toast_showing and not _volume_showing and not _expecting_ui
	if hide == _hidden:
		return
	_hidden = hide
	var id := "0x%x" % _window
	var args := ["-id", id, "-f", OPACITY, "32c", "-set", OPACITY, "0"] if hide else ["-id", id, "-remove", OPACITY]
	if Spawn.run("xprop", args) < 0:
		logger.warn("xprop failed; shell window opacity not changed")
