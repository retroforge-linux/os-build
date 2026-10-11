extends VBoxContainer
## Quick bar > Fan test: run the board's fan at a fixed duty to hear and feel what a duty and a
## pulse rate do, then hand it back to the curve. Everything goes through qforge-powerd
## (FanTestStart/FanTestStop, power_client.gd); powerd pauses the curve while a test runs and ends
## it by itself after 10 minutes or at 85 C. On a fan that can only be switched (the Air X/Y today)
## powerd pulses it in software at the chosen rate; on a PWM fan the rate is the hardware's and the
## slider is ignored.

const REFRESH_SECS := 1.0
const HardwareCard := preload("hardware_card.gd")

var power  # power_client.gd
var _toggle: Control  # OGUI Toggle
var _duty: Control  # OGUI ValueSlider
var _rate: Control  # OGUI ValueSlider
var _status: Label
var _apply: Timer
var _timer: Timer
var _syncing := false


func setup(plugin_base: String) -> void:
	power = load(plugin_base.path_join("power_client.gd")).new()


func _ready() -> void:
	name = "QForgeFanTest"
	add_theme_constant_override("separation", 6)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.text = "—"
	add_child(_status)

	# Configure OGUI's components only after they are in the tree, and listen last: ValueSlider
	# reports the clamp of its initial value as a change (see hardware_card.gd).
	_toggle = (load("res://core/ui/components/toggle.tscn") as PackedScene).instantiate()
	_toggle.text = "Manual fan"
	add_child(_toggle)
	_duty = (load("res://core/ui/components/slider.tscn") as PackedScene).instantiate()
	_duty.text = "Duty %"
	add_child(_duty)
	_duty.min_value = 0
	_duty.max_value = 100
	_duty.step = 5
	_duty.value = 50
	_rate = (load("res://core/ui/components/slider.tscn") as PackedScene).instantiate()
	_rate.text = "Pulse rate (Hz)"
	add_child(_rate)
	_rate.min_value = 5
	_rate.max_value = 200
	_rate.step = 5
	_rate.value = 100

	_apply = Timer.new()
	_apply.one_shot = true
	_apply.wait_time = 0.3
	_apply.timeout.connect(_send)
	add_child(_apply)
	_toggle.toggled.connect(func(_on: bool):
		if not _syncing:
			_send())
	_duty.value_changed.connect(func(_v: float):
		if not _syncing and _toggle.button_pressed:
			_apply.start())
	_rate.value_changed.connect(func(_v: float):
		if not _syncing and _toggle.button_pressed:
			_apply.start())
	HardwareCard.add_focus_group(self)

	_timer = Timer.new()
	_timer.wait_time = REFRESH_SECS
	_timer.autostart = true
	_timer.timeout.connect(refresh)
	add_child(_timer)
	visibility_changed.connect(refresh)
	refresh()


func _send() -> void:
	if power == null:
		return
	if _toggle.button_pressed:
		power.fan_test_start(int(_duty.value), int(_rate.value))
	else:
		power.fan_test_stop()
	refresh.call_deferred()


func refresh() -> void:
	if power == null or not is_visible_in_tree():
		return
	var fan: Dictionary = power.get_fan()
	if fan.is_empty() or fan.get("mode", "") == "unavailable":
		_status.text = "No fan powerd can drive."
		return
	var now: String = fan["test"] if fan["test"] != "" else "fan curve, %d%% duty" % int(round(fan["pwm"] * 100.0 / 255.0))
	_status.text = "Now: %s · %d °C" % [now, fan["temp"]]
	# a test that ended on its own (time limit, 85 C) turns the switch back off
	if fan["test"] == "" and _toggle.button_pressed:
		_syncing = true
		_toggle.button_pressed = false
		_syncing = false
