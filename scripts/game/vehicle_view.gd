## 载具外观节点
##
## 层级：root（位置 + 航向）→ tilt（车身俯仰 / 侧倾）→ 车身部件
##       车轮独立挂在 root 下，各自三层：转向（y）→ 滚动（x）→ 网格（圆柱轴向校正）
##
## 车身几何优先用 CarGeometry（程序化车身，scripts/game/car_geometry.gd）；
## 该文件尚未就绪时自动回退到占位方块车 —— 这样物理与相机可以先独立验证。
class_name VehicleView
extends Node3D

const GEO_PATH := "res://scripts/game/car_geometry.gd"

var spec: CarSpecs.Spec
var root: Node3D
var tilt: Node3D
var wheels: Array = []       # wheelPivot（负责转向）
var wheel_spins: Array = []  # wheelSpin（负责滚动）
var lights_mat: Material
var using_real_geometry := false

static var _geo_script: GDScript = null
static var _geo_checked := false


func setup(p_spec: CarSpecs.Spec) -> void:
	spec = p_spec
	for child in get_children():
		remove_child(child)
		child.free()
	wheels.clear()
	wheel_spins.clear()

	root = Node3D.new()
	root.name = "root"
	add_child(root)
	tilt = Node3D.new()
	tilt.name = "tilt"
	root.add_child(tilt)

	if not _geo_checked:
		_geo_checked = true
		if ResourceLoader.exists(GEO_PATH):
			_geo_script = load(GEO_PATH)
	if _geo_script != null and _geo_script.has_method("of"):
		_build_real()
	else:
		_build_placeholder()


# ============================================================================
# 真实车身（CarGeometry）
# ============================================================================


func _build_real() -> void:
	using_real_geometry = true
	var geo = _geo_script.call("of", spec)
	var mats: Dictionary = _geo_script.call("materials")

	var painted := MeshInstance3D.new()
	painted.name = "painted"
	painted.mesh = geo.painted
	# 玩家车用本车专属车漆色（几何顶点色只区分主漆 / 裙边 / 车顶的明暗）
	painted.material_override = _geo_script.call("player_paint", spec.body_color)
	painted.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tilt.add_child(painted)

	var dark := MeshInstance3D.new()
	dark.name = "dark"
	dark.mesh = geo.dark
	dark.material_override = mats["dark"]
	dark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tilt.add_child(dark)

	lights_mat = mats["lights"]
	var lights := MeshInstance3D.new()
	lights.name = "lights"
	lights.mesh = geo.lights
	lights.material_override = lights_mat
	lights.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tilt.add_child(lights)

	var wheel_mesh: Mesh = geo.wheel
	var wt: float = geo.wheel_half_track
	var wr: float = geo.wheel_radius
	var fz: float = geo.front_z
	var rz: float = geo.rear_z
	for i in 4:
		_add_wheel(wheel_mesh, mats["dark"], -wt if i % 2 == 0 else wt, wr, fz if i < 2 else rz)


# ============================================================================
# 占位车身（CarGeometry 未就绪时的临时外观）
# ============================================================================


func _build_placeholder() -> void:
	using_real_geometry = false
	var body_len := spec.length * 0.96
	var body_h := spec.height * 0.52
	var wheel_r := spec.kind_radius()

	var paint := StandardMaterial3D.new()
	paint.albedo_color = spec.body_color
	paint.roughness = 0.45
	paint.metallic = 0.15

	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.13, 0.17, 0.21)
	glass.roughness = 0.22
	glass.metallic = 0.1

	# 主车身
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(spec.width, body_h, body_len)
	body.mesh = bm
	body.position = Vector3(0.0, wheel_r + body_h * 0.35, 0.0)
	body.material_override = paint
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tilt.add_child(body)

	# 车厢（大巴 / 卡车直接用同一块方箱拉高）
	var cab_h := spec.height * (0.34 if not spec.is_big() else 0.42)
	var cab := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(spec.width * 0.88, cab_h, spec.length * (0.44 if not spec.is_big() else 0.86))
	cab.mesh = cm
	cab.position = Vector3(0.0, wheel_r + body_h * 0.35 + body_h * 0.5 + cab_h * 0.4, -spec.length * 0.04)
	cab.material_override = glass if not spec.is_big() else paint
	cab.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tilt.add_child(cab)

	# 车灯（自发光小块）
	lights_mat = StandardMaterial3D.new()
	lights_mat.albedo_color = Color(1.0, 0.94, 0.8)
	lights_mat.emission_enabled = true
	lights_mat.emission = Color(1.0, 0.92, 0.72)
	lights_mat.emission_energy_multiplier = 1.2
	for i in 4:
		var lamp := MeshInstance3D.new()
		var lm := BoxMesh.new()
		lm.size = Vector3(spec.width * 0.22, 0.16, 0.1)
		lamp.mesh = lm
		var front := i < 2
		lamp.position = Vector3(
			-spec.width * 0.28 if i % 2 == 0 else spec.width * 0.28,
			wheel_r + body_h * 0.32,
			body_len * 0.5 if front else -body_len * 0.5
		)
		lamp.material_override = lights_mat
		lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		tilt.add_child(lamp)

	# 车轮
	var cyl := CylinderMesh.new()
	cyl.top_radius = wheel_r
	cyl.bottom_radius = wheel_r
	cyl.height = 0.26
	cyl.radial_segments = 14
	var tire := StandardMaterial3D.new()
	tire.albedo_color = Color(0.09, 0.09, 0.1)
	tire.roughness = 0.85
	var wt := spec.width * 0.5 - 0.1
	var fz := spec.wheelbase * 0.5
	for i in 4:
		var m: Mesh = cyl
		_add_wheel(m, tire, -wt if i % 2 == 0 else wt, wheel_r, fz if i < 2 else -fz)


func _add_wheel(mesh: Mesh, mat: Material, px: float, py: float, pz: float) -> void:
	var pivot := Node3D.new()
	pivot.name = "wheel%d" % wheels.size()
	pivot.position = Vector3(px, py, pz)
	root.add_child(pivot)
	var spin := Node3D.new()
	spin.name = "spin"
	pivot.add_child(spin)
	var wm := MeshInstance3D.new()
	wm.mesh = mesh
	wm.material_override = mat
	wm.rotation.z = PI * 0.5  # 圆柱默认沿 y，转到沿 x
	wm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	spin.add_child(wm)
	wheels.append(pivot)
	wheel_spins.append(spin)


# ============================================================================
# 每帧同步
# ============================================================================


func sync(v: Vehicle, dt: float) -> void:
	if root == null:
		return
	root.position = Vector3(v.x, v.y, v.z)
	root.rotation.y = v.yaw
	tilt.rotation.x = v.body_pitch
	tilt.rotation.z = v.body_roll
	# 前轮转角（视觉放大到约 30°）
	var steer := -v.steer_state * v.spec.steer_max * 0.9
	var spin := v.wheel_spin
	for i in wheels.size():
		var pivot: Node3D = wheels[i]
		var target := steer if i < 2 else 0.0
		pivot.rotation.y += (target - pivot.rotation.y) * minf(1.0, dt * 14.0)
		var sp: Node3D = wheel_spins[i]
		sp.rotation.x = spin


## 夜间车灯亮度（0 = 只留轮廓，1 = 全亮）
func set_lights(strength: float) -> void:
	if lights_mat is StandardMaterial3D:
		(lights_mat as StandardMaterial3D).emission_energy_multiplier = 0.25 + strength * 0.95