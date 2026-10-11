extends RefCounted
## Tapping a text field opens OpenGamepadUI's on-screen keyboard.
##
## OGUI opens it only when the gamepad's South button is released on a focused field
## (SearchBar._gui_input, ComponentTextInput._on_gui_input). A tap on the touchscreen reaches
## Godot as a left click (gamescope's touch click mode), which focuses the field and nothing
## else, so the keyboard never came up from the touchscreen. A click/tap release on those fields
## now does what South does there: the search bar first switches to the library, like OGUI's.

var state_machine := load("res://assets/state/state_machines/menu_state_machine.tres") as StateMachine
var library_state := load("res://assets/state/states/library.tres") as State
var _tree: SceneTree


func setup(tree: SceneTree) -> RefCounted:
	_tree = tree
	for node in tree.root.find_children("*", "LineEdit", true, false):
		_watch(node)
	for node in tree.root.find_children("*", "Control", true, false):
		if node is ComponentTextInput:
			_watch(node)
	tree.node_added.connect(_watch)
	return self


func detach() -> void:
	if _tree and _tree.node_added.is_connected(_watch):
		_tree.node_added.disconnect(_watch)


func _watch(node: Node) -> void:
	if node is SearchBar:
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


func _on_field_input(event: InputEvent, owner: Node, is_search: bool) -> void:
	var tapped: bool = (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed) \
		or (event is InputEventScreenTouch and not event.pressed)
	if not tapped:
		return
	if is_search and state_machine.current_state() != library_state:
		state_machine.push_state(library_state)
	owner.keyboard.open(owner.keyboard_context)
