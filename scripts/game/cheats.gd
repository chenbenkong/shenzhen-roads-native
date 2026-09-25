## 作弊状态（破解版玩法）：由作弊菜单读写，主循环与载具物理按它生效
##
## 设计：状态集中在这里，UI 只负责改值，逻辑侧只读 —— 避免面板与玩法互相耦合。
class_name Cheats
extends RefCounted

## 车辆无敌（车损不下降）
var invincible := false
## 引擎强化：加速度与极速同时提升
var boost := false
## 强制通缉星级：-1 = 交给玩法自然累积；0..5 = 锁定为指定星级
var forced_wanted := -1

## 统计数据（存档会一起保存）
var odometer := 0.0
var top_speed_kmh := 0.0
var crash_count := 0
var police_escapes := 0

## 引擎强化的倍率
const BOOST_ACCEL := 2.1
const BOOST_TOP := 1.55


func boost_accel() -> float:
	return BOOST_ACCEL if boost else 1.0


func boost_top() -> float:
	return BOOST_TOP if boost else 1.0


func to_dict() -> Dictionary:
	return {
		"invincible": invincible,
		"boost": boost,
		"forced_wanted": forced_wanted,
		"odometer": odometer,
		"top_speed_kmh": top_speed_kmh,
		"crash_count": crash_count,
		"police_escapes": police_escapes,
	}


func from_dict(d: Dictionary) -> void:
	invincible = bool(d.get("invincible", false))
	boost = bool(d.get("boost", false))
	forced_wanted = int(d.get("forced_wanted", -1))
	odometer = float(d.get("odometer", 0.0))
	top_speed_kmh = float(d.get("top_speed_kmh", 0.0))
	crash_count = int(d.get("crash_count", 0))
	police_escapes = int(d.get("police_escapes", 0))


func reset_stats() -> void:
	odometer = 0.0
	top_speed_kmh = 0.0
	crash_count = 0
	police_escapes = 0