## 步行模式：玩家下车后以第三人称行走
##
## 逻辑（RefCounted 部分）+ 外观（Node3D 部分）合在一个节点里，便于统一同步。
## 移动是「相机相对」的：W 往相机前方走，与朝向解耦（角色会平滑转向移动方向）。
## 走路动画复用行人的做法：腿 / 手臂绕各自关节反向摆动。
class_name OnFoot
extends Node3D

const WALK_SPEED := 2.6
const RUN_SPEED := 6.4
const ACCEL := 14.0
const RADIUS := 0.36
const EYE_Y := 1.62
## 关节高度与左右偏移：与部件几何保持一致（见 tools/prepare-assets.mjs）
const HIP_Y := 0.885
const SHOULDER_Y := 1.37
const HIP_HALF := 0.11
const SHOULDER_HALF := 0.26

const BODY_PATH := "res://models/ped_body.glb"
const ARM_PATH := "res://models/ped_arm.glb"
const LEG_PATH := "res://models/ped_leg.glb"

var x := 0.0
var y := C.Y_SIDEWALK
var z := 0.0
var yaw := 0.0
var speed := 0.0
var running := false

var _vx := 0.0
var _vz := 0.0
var _phase := 0.0
var _root: Node3D
var _leg_l: Node3D
var _leg_r: Node3D
var _arm_l: Node3D
var _arm_r: Node3D


func setup() -> void:
	_root = Node3D.new()
	_root.name = "onfoot"
	add_child(_root)

	var mat := AssetUtil.vertex_color_material(0.8)
	# 负缩放镜像出的左肢会翻转缠绕，直接关掉背面剔除（肢体很小，代价可忽略）
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_root.add_child(_mesh_node(AssetUtil.mesh_of(BODY_PATH), mat))
	_leg_l = _joint(AssetUtil.mesh_of(LEG_PATH), mat, Vector3(-HIP_HALF, HIP_Y, 0.0))
	_leg_r = _joint(AssetUtil.mesh_of(LEG_PATH), mat, Vector3(HIP_HALF, HIP_Y, 0.0))
	_arm_l = _joint(AssetUtil.mesh_of(ARM_PATH), mat, Vector3(-SHOULDER_HALF, SHOULDER_Y, 0.0))
	_arm_r = _joint(AssetUtil.mesh_of(ARM_PATH), mat, Vector3(SHOULDER_HALF, SHOULDER_Y, 0.0))
	# 资产里的手臂 / 腿都是「右侧」几何，左侧用 x 轴负缩放镜像
	_leg_l.scale.x = -1.0
	_arm_l.scale.x = -1.0


func _mesh_node(mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## 关节节点：原点即旋转轴（髋 / 肩），摆动只改 rotation.x
func _joint(mesh: Mesh, mat: Material, offset: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = offset
	n.add_child(_mesh_node(mesh, mat))
	return n


func place(px: float, pz: float, pyaw: float, data: CityData) -> void:
	x = px
	z = pz
	yaw = pyaw
	_vx = 0.0
	_vz = 0.0
	speed = 0.0
	y = _ground(data, px, pz)
	_root.position = Vector3(x, y, z)
	_root.rotation.y = yaw


## 每帧：相机相对输入（move_f: 前后 -1..1；move_r: 左右 -1..1）
func update(dt: float, data: CityData, cam_yaw: float, move_f: float, move_r: float, want_run: bool) -> void:
	running = want_run and (absf(move_f) + absf(move_r) > 0.01)
	var target_speed := (RUN_SPEED if running else WALK_SPEED)

	# 相机相对 → 世界方向
	var dir_x := 0.0
	var dir_z := 0.0
	if absf(move_f) + absf(move_r) > 0.001:
		var fwd_x := sin(cam_yaw)
		var fwd_z := cos(cam_yaw)
		var rgt_x := -cos(cam_yaw)
		var rgt_z := sin(cam_yaw)
		dir_x = fwd_x * move_f + rgt_x * move_r
		dir_z = fwd_z * move_f + rgt_z * move_r
		var l := sqrt(dir_x * dir_x + dir_z * dir_z)
		if l > 1e-4:
			dir_x /= l
			dir_z /= l

	var want_vx := dir_x * target_speed
	var want_vz := dir_z * target_speed
	var k := minf(1.0, dt * ACCEL / maxf(1.0, target_speed))
	_vx += (want_vx - _vx) * k
	_vz += (want_vz - _vz) * k
	if dir_x == 0.0 and dir_z == 0.0 and absf(_vx) + absf(_vz) < 0.05:
		_vx = 0.0
		_vz = 0.0

	x += _vx * dt
	z += _vz * dt
	speed = sqrt(_vx * _vx + _vz * _vz)

	# 碰到建筑就停下来（沿墙滑动：只推出，不反弹）
	if _resolve(data):
		pass

	# 朝向：平滑转向移动方向
	if speed > 0.25:
		var want_yaw := atan2(_vx, _vz)
		var diff := wrapf(want_yaw - yaw, -PI, PI)
		yaw += diff * minf(1.0, dt * 9.0)

	y = _ground(data, x, z)
	_sync_view(dt)


func _resolve(data: CityData) -> bool:
	var out := {}
	if not data.collide_circle(x, z, RADIUS, out):
		return false
	var nx := float(out["nx"])
	var nz := float(out["nz"])
	# 推出
	x += float(out["x"]) - x
	z += float(out["z"]) - z
	# 抹掉朝向墙内的速度分量
	var vn := _vx * nx + _vz * nz
	if vn < 0.0:
		_vx -= nx * vn
		_vz -= nz * vn
	return true


## 步行贴地：路面 → 人行道 → 地表
func _ground(data: CityData, px: float, pz: float) -> float:
	var graph := data.graph
	var hit := graph.closest_edge(px, pz, 30.0)
	if not hit.is_empty():
		var edge: int = hit["edge"]
		var road := graph.e_road[edge]
		if float(hit["dist"]) <= graph.road_width(road) * 0.5 + 3.2:
			var ry := graph.edge_y(edge, float(hit["s"]))
			return maxf(ry + 0.03, C.Y_SIDEWALK)
	var s := data.surface_at(px, pz)
	var base: float = float(s["y"])
	return maxf(base, C.Y_LAND)


func _sync_view(dt: float) -> void:
	_root.position = Vector3(x, y, z)
	_root.rotation.y = yaw
	if speed > 0.1:
		_phase += dt * (7.5 if running else 4.6) * clampf(speed / WALK_SPEED, 0.5, 3.0)
	var swing := sin(_phase) * (0.62 if running else 0.42)
	_leg_l.rotation.x = swing
	_leg_r.rotation.x = -swing
	_arm_l.rotation.x = -swing * 0.75
	_arm_r.rotation.x = swing * 0.75


## 供相机与上车判定使用
func position() -> Vector3:
	return Vector3(x, y, z)


func head_y() -> float:
	return EYE_Y