## 载具规格表（数值与 Web 版 cars.ts 完全一致，手感不漂移）
## 车身几何见 car_geometry.gd，物理见 vehicle.gd。
class_name CarSpecs
extends RefCounted


class Spec:
	extends RefCounted
	var id := ""
	var name := ""
	## sedan / sports / suv / taxi / van / bus / truck / police
	var kind := "sedan"
	## 车长（米，含前后保险杠）
	var length := 4.6
	var width := 1.82
	var height := 1.44
	## 轴距
	var wheelbase := 2.72
	## 极限车速 m/s
	var max_speed := 45.0
	## 倒车极限 m/s
	var reverse_speed := 11.0
	## 驱动加速度 m/s²
	var accel := 9.0
	## 制动减速度 m/s²
	var brake := 17.0
	## 侧向抓地衰减率（越大越贴地，越小越容易甩尾）
	var grip := 7.6
	## 低速最大前轮转角（弧度）
	var steer_max := 0.56
	## 车厢占车高的比例
	var cabin_ratio := 0.46
	var body_color := Color8(154, 164, 178)

	func is_big() -> bool:
		return kind == "bus" or kind == "truck"

	## 车轮半径（与车身几何、物理里的 wheel_radius_hint 保持一致）
	func kind_radius() -> float:
		match kind:
			"bus": return 0.53
			"truck": return 0.56
			"van": return 0.38
			"suv": return 0.40
			"sports": return 0.34
			_: return 0.33


## AI 车流车身配色（出租车 / 巴士 / 卡车保持原色）
static var TRAFFIC_COLORS := PackedColorArray([
	Color8(0xE8, 0xEC, 0xF2), Color8(0xB9, 0xC2, 0xCD), Color8(0x8F, 0x98, 0xA3),
	Color8(0x2D, 0x3A, 0x45), Color8(0x14, 0x17, 0x1C), Color8(0x9C, 0x2A, 0x22),
	Color8(0x2F, 0x4F, 0x7A), Color8(0x2D, 0x6B, 0x52), Color8(0xB0, 0x8A, 0x2E),
	Color8(0x6D, 0x4A, 0x86),
])

static var _specs: Array = []


static func all() -> Array:
	if _specs.is_empty():
		_build()
	return _specs


static func by_id(id: String) -> Spec:
	for s: Spec in all():
		if s.id == id:
			return s
	return all()[0]


static func by_index(i: int) -> Spec:
	var list := all()
	return list[((i % list.size()) + list.size()) % list.size()]


static func count() -> int:
	return all().size()


static func _mk(
	id: String, name: String, kind: String,
	length: float, width: float, height: float, wheelbase: float,
	max_speed: float, reverse_speed: float, accel: float, brake: float,
	grip: float, steer_max: float, cabin_ratio: float, color: Color
) -> Spec:
	var s := Spec.new()
	s.id = id
	s.name = name
	s.kind = kind
	s.length = length
	s.width = width
	s.height = height
	s.wheelbase = wheelbase
	s.max_speed = max_speed
	s.reverse_speed = reverse_speed
	s.accel = accel
	s.brake = brake
	s.grip = grip
	s.steer_max = steer_max
	s.cabin_ratio = cabin_ratio
	s.body_color = color
	return s


static func _build() -> void:
	if not _specs.is_empty():
		return
	_specs = [
		_mk("sedan", "家用轿车", "sedan", 4.62, 1.82, 1.44, 2.72, 45.0, 11.0, 9.2, 17.0, 7.6, 0.56, 0.46, Color8(0xB9, 0xC2, 0xCD)),
		_mk("sports", "运动跑车", "sports", 4.42, 1.94, 1.19, 2.55, 63.0, 12.0, 14.5, 23.0, 9.6, 0.50, 0.40, Color8(0xD8, 0x45, 0x2F)),
		_mk("suv", "城市越野", "suv", 4.82, 1.96, 1.78, 2.86, 42.0, 11.0, 8.4, 16.0, 7.2, 0.56, 0.55, Color8(0x39, 0x50, 0x5F)),
		_mk("taxi", "出租车", "taxi", 4.72, 1.86, 1.50, 2.78, 44.0, 11.0, 8.8, 17.0, 7.6, 0.56, 0.46, Color8(0x2F, 0xA0, 0x6A)),
		_mk("van", "厢式货车", "van", 5.30, 2.02, 2.24, 3.20, 35.0, 11.0, 6.4, 14.0, 6.4, 0.56, 0.62, Color8(0xD9, 0xD3, 0xC6)),
		_mk("bus", "城市巴士", "bus", 11.40, 2.50, 3.16, 5.60, 29.0, 8.0, 4.2, 11.0, 5.6, 0.44, 0.78, Color8(0x2F, 0x6F, 0xB0)),
		_mk("truck", "重载卡车", "truck", 8.60, 2.46, 3.42, 4.40, 31.0, 8.0, 4.6, 12.0, 5.8, 0.46, 0.60, Color8(0x8A, 0x5B, 0x2E)),
		_mk("police", "警车", "police", 4.90, 1.96, 1.50, 2.82, 55.0, 11.0, 12.4, 21.0, 9.0, 0.56, 0.46, Color8(0xE8, 0xEC, 0xF2)),
	]