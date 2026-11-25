extends RefCounted
## The time zones of /usr/share/zoneinfo, for the Time zone row (time_zone_settings.gd). No OGUI types,
## so tests/test-plugin.sh runs it on a stock Godot against Python's zoneinfo.
##
## The choices are tzdata's zonenow.tab: one row per set of places whose clocks agree from now on (~90),
## made for a picker like this one. zone.tab's 418 names are too many to walk with a D-pad.
##
## Offsets come from the zone files themselves (TZif, RFC 9636): the version 2 block's transitions, which
## the image's tzdata (zic -b fat) lists up to 2037. The footer's rule for later years is not read.

const ZONEINFO := "/usr/share/zoneinfo"
const TABLE := "zonenow.tab"
const UTC := "UTC"
const HEADER_SIZE := 44
const COUNTS_AT := 20  # in a header: isut, isstd, leap, time, type and char counts, 4 bytes each
const TYPE_SIZE := 6  # utoff (4 bytes), isdst, abbreviation index


## The zone a localtime symlink points to; no link is systemd's UTC.
static func zone_of_link(target: String) -> String:
	var at := target.find("zoneinfo/")
	return target.substr(at + "zoneinfo/".length()) if at >= 0 else UTC


## A zone's file; empty when there is none.
static func read(zoneinfo: String, zone: String) -> PackedByteArray:
	var path := zoneinfo.path_join(zone)
	return FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()


## Seconds east of UTC in force at `unix`; 0 for anything that is not a whole version 2+ zone file.
static func offset_at(data: PackedByteArray, unix: int) -> int:
	var second := _block_end(data, 0, 4)
	if second < 0 or _block_end(data, second, 8) < 0:
		return 0
	var file := StreamPeerBuffer.new()
	file.big_endian = true
	file.data_array = data
	var times := second + HEADER_SIZE
	var time_count := _count(data, second, 3)
	# The last transition at or before `unix`.
	var low := 0
	var high := time_count
	while low < high:
		var mid := (low + high) / 2
		file.seek(times + mid * 8)
		if file.get_64() <= unix:
			low = mid + 1
		else:
			high = mid
	var types := times + time_count * 9
	var type := data[times + time_count * 8 + low - 1] if low > 0 else 0
	if type >= _count(data, second, 4):
		return 0
	file.seek(types + type * TYPE_SIZE)
	return file.get_32()


## "UTC+05:45"
static func offset_text(offset: int) -> String:
	var minutes := absi(offset) / 60
	return "UTC%s%02d:%02d" % ["-" if offset < 0 else "+", minutes / 60, minutes % 60]


## What Time.get_datetime_dict_from_system() would give in that zone.
static func local_time(data: PackedByteArray, unix: int) -> Dictionary:
	return Time.get_datetime_dict_from_unix_time(unix + offset_at(data, unix))


## zonenow.tab's rows as {"zone", "name"}: the zone's city, then what tzdata says it covers.
static func parse_table(text: String) -> Array:
	var rows := []
	for line in text.split("\n", false):
		var fields := line.split("\t")
		if line.begins_with("#") or fields.size() < 3:
			continue
		var city := fields[2].get_file().replace("_", " ")
		var covers := fields[3].strip_edges() if fields.size() > 3 else ""
		var name := city if covers == "" else covers if covers.begins_with(city) else "%s - %s" % [city, covers]
		rows.append({"zone": fields[2], "name": name})
	return rows


## What the dropdown lists, from west to east: {"zone", "name", "offset", "label"}. UTC and the zone in
## force are always in it: the zone may have been set elsewhere (timedatectl) to one the table lacks.
static func choices(zoneinfo: String, current: String, unix: int) -> Array:
	var path := zoneinfo.path_join(TABLE)
	var rows := parse_table(FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else "")
	for zone in [UTC, current]:
		if not rows.any(func(row: Dictionary) -> bool: return row["zone"] == zone):
			rows.append({"zone": zone, "name": zone})
	var list := []
	for i in rows.size():
		var offset := offset_at(read(zoneinfo, rows[i]["zone"]), unix)
		list.append({
			"zone": rows[i]["zone"], "name": rows[i]["name"], "offset": offset, "order": i,
			"label": "%s  %s" % [offset_text(offset), rows[i]["name"]],
		})
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return [a["offset"], a["order"]] < [b["offset"], b["order"]])
	return list


## Where the block at `at` ends (its header and its data, with `time_size`-byte times), or -1 when that
## is not a TZif block held whole.
static func _block_end(data: PackedByteArray, at: int, time_size: int) -> int:
	if data.size() < at + HEADER_SIZE or data.slice(at, at + 4).get_string_from_ascii() != "TZif" or data[at + 4] < 0x32:
		return -1
	var times := _count(data, at, 3)
	var size := times * (time_size + 1) + _count(data, at, 4) * TYPE_SIZE + _count(data, at, 5) \
		+ _count(data, at, 2) * (time_size + 4) + _count(data, at, 1) + _count(data, at, 0)
	var end := at + HEADER_SIZE + size
	return end if end <= data.size() else -1


static func _count(data: PackedByteArray, at: int, index: int) -> int:
	var i := at + COUNTS_AT + index * 4
	return data[i] << 24 | data[i + 1] << 16 | data[i + 2] << 8 | data[i + 3]
