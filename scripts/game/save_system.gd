## 存档：位置 / 载具 / 作弊状态 / 统计 / 设置，写到 user:// 下的 JSON
##
## 设计：单存档位（够用且省事），自动存档 + 手动 F5/F9。
## 只存「能重建场景所需的最小状态」——地图、城市数据都是确定性的，不需要存。
class_name SaveSystem
extends RefCounted

const PATH := "user://save_01.json"
const VERSION := 1


static func has_save() -> bool:
	return FileAccess.file_exists(PATH)


static func write_state(state: Dictionary) -> bool:
	state["version"] = VERSION
	state["saved_at"] = Time.get_datetime_string_from_system()
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_error("存档写入失败：%s" % PATH)
		return false
	f.store_string(JSON.stringify(state, "  "))
	f.close()
	return true


static func read_state() -> Dictionary:
	if not has_save():
		return {}
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("存档解析失败，忽略")
		return {}
	if int(parsed.get("version", 0)) != VERSION:
		push_warning("存档版本不匹配（%s），忽略" % parsed.get("version"))
		return {}
	return parsed


static func erase() -> void:
	if has_save():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))