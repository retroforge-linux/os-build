extends RefCounted

## Who made an emulator, as the Apps page shows it under its name. No OGUI types, so
## tests/test-plugin.sh runs it in a stock headless Godot.


## "By <author> · <homepage> · Licence <name>" under the emulator's name. Plain text: there is
## no browser to open a link in. The homepage is the link every project asks for; the licence's
## own URL stays in the catalog (it made the line wrap twice on a 1620 px panel).
static func credit_text(emu: Dictionary) -> String:
	var parts := PackedStringArray()
	var author := str(emu["author"]) if emu.get("author") != null else ""
	var homepage := str(emu["homepage"]) if emu.get("homepage") != null else ""
	if author != "":
		parts.append("By " + author)
	if homepage != "":
		parts.append(homepage.trim_prefix("https://").trim_prefix("www.").trim_suffix("/"))
	var licence: Dictionary = emu.get("licence") if emu.get("licence") is Dictionary else {}
	if str(licence.get("name", "")) != "":
		parts.append("Licence " + str(licence["name"]))
	return " · ".join(parts)


## A release tag as the player reads it: pkgforge-dev's "<version>@<date>_<id>" is just <version>;
## a nightly (catalog tag "nightly", installed as retroforge-emu's "nightly-<id>") says so, and
## DuckStation's rolling "latest" ("latest-<12 hex of the digest>") says Latest with 8 digits; RPCS3's
## "build-<40 hex commit>" keeps the commit's first 8 digits.
static func version_text(tag: String) -> String:
	if tag == "nightly" or tag.begins_with("nightly-"):
		return ("Nightly " + tag.trim_prefix("nightly").trim_prefix("-")).strip_edges()
	if tag == "latest" or tag.begins_with("latest-"):
		return ("Latest " + tag.trim_prefix("latest").trim_prefix("-").left(8)).strip_edges()
	if tag.begins_with("build-") and tag.length() == 46:
		return "Build " + tag.substr(6, 8)
	return tag.get_slice("@", 0)
