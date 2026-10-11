extends RefCounted
## Touch for OpenGamepadUI's text fields and toggles.
##
## Toggles: OGUI's Toggle flips only on ui_accept (the gamepad's A); a tap reaches Godot as a
## left click, which the row's panel swallowed (the switch itself ignores the mouse). A tap on the
## row now does what A does. Every toggle in OGUI's settings, and ours.
##
## Text fields: tapping one opens OpenGamepadUI's on-screen keyboard.
##
## Search: Enter on the keyboard (R2) submits and closes it, and OGUI then put focus back on the
## search field -- results unreachable without another press. After a submit, focus goes to the
## first visible game card instead (B, a cancel, still returns to the field).
##
## Pointer after a touch: the pointer stays where the finger lifted, so that control kept its hover
## highlight while the D-pad moved focus elsewhere -- two highlights. The first gamepad input after
## a touch sends Godot a pointer move off-screen (pointer_left()), which clears the hover.
##
## OGUI opens it only when the gamepad's South button is released on a focused field
## (SearchBar._gui_input, ComponentTextInput._on_gui_input). A tap on the touchscreen reaches
## Godot as a left click (gamescope's touch click mode), which focuses the field and nothing
## else, so the keyboard never came up from the touchscreen. A click/tap release on those fields
## now does what South does there: the search bar first switches to the library, like OGUI's.
##
## Also: a keyboard opened from a text field never puts the OSK state on the popup stack, and the
## main menu / quick bar only REPLACE that state, so opening one left the keyboard open underneath.
## Leaving the menu (e.g. its Home entry) then showed a keyboard nobody owned, whose popup layer ate
## every tap on the screen -- cards and the search bar stopped responding. Any other popup taking
## over now dismisses the keyboard.

var state_machine := load("res://assets/state/state_machines/menu_state_machine.tres") as StateMachine
var library_state := load("res://assets/state/states/library.tres") as State
var popup_state_machine := load("res://assets/state/state_machines/popup_state_machine.tres") as StateMachine
var osk_state := load("res://assets/state/states/osk.tres") as State
var keyboard := load("res://core/global/keyboard_instance.tres") as KeyboardInstance
var _tree: SceneTree


func setup(tree: SceneTree) -> RefCounted:
	_tree = tree
	for node in tree.root.find_children("*", "LineEdit", true, false):
		_watch(node)
	for node in tree.root.find_children("*", "Control", true, false):
		if node is ComponentTextInput or node is Toggle:
			_watch(node)
	tree.node_added.connect(_watch)
	popup_state_machine.state_changed.connect(_on_popup_changed)
	return self


## Pointer bookkeeping, fed from the plugin's _input and its InputPlumber listener.
var _pointer_hovering := false
var _parking := false


func note_input(event: InputEvent) -> void:
	if _parking:
		return
	if event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventScreenTouch:
		_pointer_hovering = true


## A gamepad took over: move Godot's idea of the pointer off-screen so hover styles clear.
func pointer_left() -> void:
	if not _pointer_hovering:
		return
	_pointer_hovering = false
	var away := InputEventMouseMotion.new()
	away.position = Vector2(-10000, -10000)
	away.global_position = away.position
	_parking = true
	Input.parse_input_event(away)
	Input.flush_buffered_events()
	_parking = false


## After a search submit: OGUI's KeyboardInstance.close() hands focus back to the search field
## with call_deferred; take it on to the first visible result after that.
func _focus_first_result() -> void:
	await _tree.process_frame
	await _tree.process_frame
	var best: Control = null
	for node in _tree.root.find_children("*", "Control", true, false):
		if not (node is GameCard and node.is_visible_in_tree() and node.focus_mode != Control.FOCUS_NONE):
			continue
		var c := node as Control
		if best == null or c.global_position.y < best.global_position.y - 1 \
				or (absf(c.global_position.y - best.global_position.y) <= 1 and c.global_position.x < best.global_position.x):
			best = c
	if best:
		best.grab_focus()


func _on_popup_changed(_from: State, to: State) -> void:
	if to == null or to == osk_state or keyboard.context == null:
		return
	# OGUI's KeyboardInstance.close() minus handing focus back to the text field: the popup that
	# just opened owns the focus now.
	var target = keyboard.context.target
	if target is LineEdit:
		(target as LineEdit).caret_force_displayed = false
	if target is Control:
		(target as Control).focus_mode = Control.FOCUS_ALL
	keyboard.set_context(null)
	keyboard.keyboard_closed.emit()


func detach() -> void:
	if _tree and _tree.node_added.is_connected(_watch):
		_tree.node_added.disconnect(_watch)
	if popup_state_machine.state_changed.is_connected(_on_popup_changed):
		popup_state_machine.state_changed.disconnect(_on_popup_changed)


func _watch(node: Node) -> void:
	if node is SearchBar and node.get("keyboard_context"):
		var on_submit := _focus_first_result
		if not node.keyboard_context.submitted.is_connected(on_submit):
			node.keyboard_context.submitted.connect(on_submit)
	if node is Toggle:
		if node.is_node_ready():
			_connect_toggle(node)
		else:
			node.ready.connect(func(): _connect_toggle(node), CONNECT_ONE_SHOT)
	elif node is SearchBar:
		_connect(node, node, true)
	elif node is ComponentTextInput:
		# line_edit and keyboard_context are @onready: wait for the node if it is not ready yet.
		if node.is_node_ready():
			_connect(node.line_edit, node, false)
		else:
			node.ready.connect(func(): _connect(node.line_edit, node, false), CONNECT_ONE_SHOT)


func _connect(field: LineEdit, owner: Node, is_search: bool) -> void:
	if field == null:
		return
	var handler := _on_field_input.bind(owner, is_search)
	if not field.gui_input.is_connected(handler):
		field.gui_input.connect(handler)


func _connect_toggle(toggle: Toggle) -> void:
	# The switch ignores the mouse (mouse_filter IGNORE) and the PanelContainer around the row
	# stops it, so a click lands on the panel, never on the Toggle itself.
	var on_row := _on_toggle_row_input.bind(toggle)
	for target in [toggle, toggle.get("panel")]:
		if target is Control and not (target as Control).gui_input.is_connected(on_row):
			(target as Control).gui_input.connect(on_row)


func _flip(toggle: Toggle, state: bool) -> void:
	toggle.button_pressed = state
	toggle.toggled.emit(state)
	toggle.button_down.emit()
	toggle.pressed.emit()
	toggle.button_up.emit()


func _on_toggle_row_input(event: InputEvent, toggle: Toggle) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_flip(toggle, not toggle.button_pressed)



func _on_field_input(event: InputEvent, owner: Node, is_search: bool) -> void:
	var tapped: bool = (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed) \
		or (event is InputEventScreenTouch and not event.pressed)
	if not tapped:
		return
	if is_search and state_machine.current_state() != library_state:
		state_machine.push_state(library_state)
	owner.keyboard.open(owner.keyboard_context)
