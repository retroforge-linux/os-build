extends RefCounted
## Up/down on OpenGamepadUI's on-screen keyboard go to the key that is actually above/below.
##
## OGUI links rows by index ratio (key 3 of 10 -> key 3 of 9) and ignores key widths, so with
## the wide keys (Shift, Backspace, Space) and the staggered rows the D-pad jumped sideways.
## After OGUI builds the keyboard, each key's horizontal span is computed from the rows' stretch
## ratios, and up/down go to the key in the next row whose span covers the key's centre (the
## nearest one if none does). Left/right and the wrap-around between first and last row are
## OGUI's own.

var keyboard := load("res://core/global/keyboard_instance.tres") as KeyboardInstance
var _tree: SceneTree


func setup(tree: SceneTree) -> RefCounted:
	_tree = tree
	keyboard.keyboard_populated.connect(_relink_all)
	_relink_all()
	return self


func _relink_all() -> void:
	for node in _tree.root.find_children("*", "Control", true, false):
		if not node is OnScreenKeyboard:
			continue
		var rows_container = node.get("rows_container")
		if rows_container:
			relink(rows_container)


## Spans of a row's keys as [start, end, centre] fractions of the row width.
static func spans(row: Array) -> Array:
	var total := 0.0
	for key in row:
		total += maxf((key as Control).size_flags_stretch_ratio, 0.01)
	var out := []
	var at := 0.0
	for key in row:
		var w := maxf((key as Control).size_flags_stretch_ratio, 0.01) / total
		out.append([at, at + w, at + w / 2.0])
		at += w
	return out


## Index of the key in a row (given its spans) under the horizontal position x.
static func key_under(row_spans: Array, x: float) -> int:
	var best := 0
	var best_dist := INF
	for i in row_spans.size():
		var s: Array = row_spans[i]
		if x >= s[0] and x < s[1]:
			return i
		var d := absf(s[2] - x)
		if d < best_dist:
			best_dist = d
			best = i
	return best


func relink(rows_container: Node) -> void:
	var rows := []
	for child in rows_container.get_children():
		if child.is_queued_for_deletion():
			continue
		var keys := []
		for key in child.get_children():
			if key is Button:
				keys.append(key)
		if not keys.is_empty():
			rows.append(keys)
	if rows.size() < 2:
		return
	var row_spans := rows.map(func(r): return spans(r))
	for y in rows.size():
		var above := posmod(y - 1, rows.size())
		var below := posmod(y + 1, rows.size())
		for x in rows[y].size():
			var key := rows[y][x] as Button
			var centre: float = row_spans[y][x][2]
			key.focus_neighbor_top = (rows[above][key_under(row_spans[above], centre)] as Button).get_path()
			key.focus_neighbor_bottom = (rows[below][key_under(row_spans[below], centre)] as Button).get_path()
