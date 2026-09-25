## 飞机外观：原项目自建的「湾翼 · 双浮筒观光飞机」
##
## 模型来自 models/floatplane_flat.glb（由原 floatplane.glb 经 tools/glb-flatten.mjs 拍平而来：
## 原资产是 meshopt + 量化压缩，Godot 的 glTF 导入器不支持，拍平后保留全部 39312 个三角面）。
##
## 姿态约定：本工程载具统一「模型朝 +z」；glTF 里这架飞机朝 -z，故模型自身转 180°。
## 俯仰 / 滚转的符号：绕 +x 正向旋转会让机头下沉，绕 +z 正向旋转会让右翼抬起，
## 因此施加时取负号（pitch > 0 = 抬头，roll > 0 = 右滚）。
class_name AircraftView
extends Node3D

const MODEL_PATH := "res://models/floatplane_flat.glb"

var root: Node3D
var model: Node3D
var loaded := false

var _propeller: Node3D = null


func setup() -> void:
	for child in get_children():
		remove_child(child)
		child.free()

	root = Node3D.new()
	root.name = "aircraft"
	add_child(root)

	if not ResourceLoader.exists(MODEL_PATH):
		push_error("飞机模型缺失：%s" % MODEL_PATH)
		return
	var scene := load(MODEL_PATH)
	if scene == null:
		push_error("飞机模型加载失败（检查是否已 --import）")
		return
	model = scene.instantiate()
	model.name = "model"
	model.rotation.y = PI  # 模型朝 -z → 转到本工程的 +z
	root.add_child(model)
	loaded = true

	# 拍平后的模型把螺旋桨也合并进了主体，这里挂一个半透明桨盘模拟旋转
	_propeller = _make_prop_disc()
	root.add_child(_propeller)


func _make_prop_disc() -> Node3D:
	var holder := Node3D.new()
	holder.name = "propeller"
	holder.position = Vector3(0.0, 0.55, 4.05)
	var disc := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.46
	cyl.bottom_radius = 1.46
	cyl.height = 0.06
	cyl.radial_segments = 24
	disc.mesh = cyl
	disc.rotation.x = PI * 0.5  # 圆柱轴向 y → 转到 z（桨盘朝前）
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.12, 0.14, 0.22)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	disc.material_override = mat
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(disc)
	return holder


## 每帧同步：位置 + 姿态（yaw / pitch / roll）+ 桨盘转速
func sync(a: Aircraft) -> void:
	if root == null:
		return
	root.position = Vector3(a.x, a.y, a.z)
	root.basis = Basis(Vector3.UP, a.yaw) * Basis(Vector3.RIGHT, -a.pitch) * Basis(Vector3.BACK, -a.roll)
	if _propeller != null:
		# 桨盘透明度随转速变化（快转时几乎看不见）
		_propeller.rotation.z = a.propeller_angle()
		var speed := clampf(a.throttle * 0.8 + a.speed / 92.0 * 0.2, 0.0, 1.0)
		var disc := _propeller.get_child(0) as MeshInstance3D
		if disc != null and disc.material_override is StandardMaterial3D:
			var mat := disc.material_override as StandardMaterial3D
			mat.albedo_color.a = lerpf(0.42, 0.10, speed)