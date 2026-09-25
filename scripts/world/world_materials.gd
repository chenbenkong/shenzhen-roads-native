## 世界材质与图集：把程序化图集组装成 Texture2DArray，并统一暴露三套材质
##  - city：不透明静态几何（建筑 / 道路 / 地面 / 桥）
##  - cut ：alpha scissor（树冠等镂空面片）
##  - glow：加色光晕（路灯 / 招牌 / 车灯）
class_name WorldMaterials
extends RefCounted

var atlas: Texture2DArray
var city: ShaderMaterial
var cut: ShaderMaterial
var glow: ShaderMaterial

var _night := 0.0


static func create() -> WorldMaterials:
	var m := WorldMaterials.new()
	var t0 := Time.get_ticks_msec()
	var layers := Atlas.new().build()
	m.atlas = Texture2DArray.new()
	m.atlas.create_from_images(layers)
	print("[材质] 图集 %d 层生成完毕，耗时 %d ms" % [layers.size(), Time.get_ticks_msec() - t0])

	m.city = _make("res://shaders/city.gdshader", m.atlas)
	m.cut = _make("res://shaders/cut.gdshader", m.atlas)
	m.glow = _make("res://shaders/glow.gdshader", m.atlas)
	m.set_night(0.0)
	return m


static func _make(path: String, tex: Texture2DArray) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(path)
	mat.set_shader_parameter("atlas", tex)
	return mat


## 昼夜：0 = 白天，1 = 深夜（驱动亮窗自发光与光晕强度）
func set_night(v: float) -> void:
	_night = clampf(v, 0.0, 1.0)
	city.set_shader_parameter("night", _night)
	glow.set_shader_parameter("strength", 0.25 + _night * 1.5)


func night() -> float:
	return _night