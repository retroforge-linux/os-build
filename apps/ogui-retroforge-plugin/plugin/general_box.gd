extends RefCounted
## Settings > General's first rows box: Updates, then Appearance. Every script that adds a row
## there (retroforge_os.gd, pause_on_menu.gd, steam_direct.gd, steam_keep.gd) looks it up here, so a
## rename in OGUI is one line to follow. OGUI 0.47.0 renamed it from VBoxContainer to UpdateSection;
## with the old path the plugin silently added nothing and left OGUI's own updater in place.

const PATH := "MarginContainer/VBoxContainer/UpdateSection"


## The box, or null when menu is null or OGUI's layout differs.
static func find(menu: Node) -> Node:
	return menu.get_node_or_null(PATH) if menu else null
