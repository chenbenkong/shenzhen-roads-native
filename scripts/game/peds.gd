## 行人：沿道路边缘游走的路人，带程序化走路动画
##
## 外观用原项目自建的 pedestrian.glb 部件（经 tools/prepare-assets.mjs 拆成三份）：
##   ped_body.glb  躯干 + 头（原点在脚底）
##   ped_arm.glb   单条手臂（原点在肩关节）
##   ped_leg.glb   单条腿（原点在髋关节）
##
## 性能设计（关键）：
##  - 躯干 / 手臂 / 腿各一个 MultiMesh；手臂与腿每个行人占 2 个实例（左右各一）
##    → 全部行人只占 3 个 draw call，且四肢能独立摆动（走路动画）
##  - 只在玩家附近生成与推进，远处回收复用（固定池，零 GC 抖动）
class_name Pedestrians
extends Node3D

const MAX_PEDS := 96
const SPAWN_RADIUS := 260.0
const DESPAWN_RADIUS := 420.0
## 关节高度（米）：由部件包围盒推得（臂顶 1.37 / 腿顶 0.885）
const HIP_Y := 0.885
const SHOULDER_Y := 1.37
## 左右肢体的横向偏移（部件自身偏离中轴约 0.11 / 0.26）
const HIP_HALF := 0.11
const SHOULDER_HALF := 0.26
const WALK_SPEED := 1.25
const RUN_SPEED := 2.6

class Ped:
	var active := false
	var edge := 0
	var s := 0.0
	var dir := 1.0
	var side := 1.0
	var speed := WALK_SPEED
	var phase := 0.0
	var tint := Color.WHITE
	var x := 0.0
	var z := 0.0
	var y := 0.0
	var yaw := 0.0


var _data: CityData
var _mm_body: MultiMesh
var _mm_arm: MultiMesh
var _mm_leg: MultiMesh
var _peds: Array = []
var _rng := RandomNumberGenerator.new()
var _sample := {}
var _basis := Basis()
## 同时存在的行人上限（设置面板的画质档位会调它）
var max_active := MAX_PEDS


func setup(data: CityData) -> void:
	_data = data
	_rng.seed = 20260925

	var body_mesh := AssetUtil.mesh_of("res://models/ped_body.glb")
	var arm_mesh := AssetUtil.mesh_of("res://models/ped_arm.glb")
	var leg_mesh := AssetUtil.mesh_of("res://models/ped_leg.glb")
	if body_mesh == null or arm_mesh == null or leg_mesh == null:
		push_error("行人资产缺失，改用空实现（跑到 tools/prepare-assets.mjs 与 --import 后重启）")
		return
	var mat := AssetUtil.vertex_color_material(0.8)

	var body := AssetUtil.make_multimesh("ped_body", body_mesh, MAX_PEDS, mat)
	add_child(body[0])
	_mm_body = body[1]
	# 手臂与腿：每人两个实例（左 / 右）
	var arm := AssetUtil.make_multimesh("ped_arm", arm_mesh, MAX_PEDS * 2, mat)
	add_child(arm[0])
	_mm_arm = arm[1]
	var leg := AssetUtil.make_multimesh("ped_leg", leg_mesh, MAX_PEDS * 2, mat)
	add_child(leg[0])
	_mm_leg = leg[1]

	for i in MAX_PEDS:
		_peds.append(Ped.new())
		_hide(i)

# ============================================================================
# 行人池：生成 / 回收 / 推进
# ============================================================================


func update(dt: float, px: float, pz: float) -> void:
	if _mm_body == null:
		return
	var spawn_budget := 3
	var alive := 0
	for i in MAX_PEDS:
		var p: Ped = _peds[i]
		if p.active:
			alive += 1
		if not p.active:
			if spawn_budget > 0 and alive < max_active:
				spawn_budget -= 1
				if _spawn(i, p, px, pz):
					alive += 1
			continue
		var dx := p.x - px
		var dz := p.z - pz
		if dx * dx + dz * dz > DESPAWN_RADIUS * DESPAWN_RADIUS:
			p.active = false
			_hide(i)
			continue
		_advance(p, dt)
		_write_transform(i, p)


## 在玩家附近随机挑一条路，把行人放到它的边缘
func _spawn(index: int, p: Ped, px: float, pz: float) -> bool:
	var graph := _data.graph
	var hit := {}
	var attempts := 6
	while attempts > 0:
		attempts -= 1
		var ang := _rng.randf() * TAU
		var rad := _rng.randf_range(40.0, SPAWN_RADIUS)
		var tx := px + cos(ang) * rad
		var tz := pz + sin(ang) * rad
		hit = graph.closest_edge(tx, tz, 60.0)
		if hit.is_empty():
			continue
		var edge: int = hit["edge"]
		if graph.e_kind[edge] < 1:
			continue  # 高速 / 快速路不放行人
		p.active = true
		p.edge = edge
		p.s = float(hit["s"])
		p.dir = 1.0 if _rng.randf() < 0.5 else -1.0
		p.side = 1.0 if _rng.randf() < 0.5 else -1.0
		p.speed = RUN_SPEED if _rng.randf() < 0.18 else WALK_SPEED
		p.phase = _rng.randf() * TAU
		# 衣物色偏：整体乘一个接近 1 的随机色（顶点色里已含皮肤 / 上衣 / 裤子分色）
		p.tint = Color(
			_rng.randf_range(0.74, 1.26),
			_rng.randf_range(0.74, 1.26),
			_rng.randf_range(0.74, 1.26)
		)
		_write_transform(index, p)
		return true
	return false


## 沿当前边推进；到端点后换下一条边（在路口随机选择）
func _advance(p: Ped, dt: float) -> void:
	var graph := _data.graph
	var edge := p.edge
	var len := graph.e_len[edge]
	p.s += p.speed * dt * p.dir
	if p.s > len or p.s < 0.0:
		var node := graph.e_b[edge] if p.dir > 0.0 else graph.e_a[edge]
		var next := _pick_edge(node)
		if next < 0:
			p.dir = -p.dir
			p.s = clampf(p.s, 0.0, len)
		else:
			var forward := graph.e_a[next] == node
			p.edge = next
			p.dir = 1.0 if forward else -1.0
			p.s = 0.0 if forward else graph.e_len[next]

	graph.sample_edge(p.edge, p.s, _sample)
	var dx: float = _sample["dx"]
	var dz: float = _sample["dz"]
	var road := graph.e_road[p.edge]
	var off := graph.road_width(road) * 0.5 + 2.4
	# 右法线 = (dz, -dx)
	p.x = float(_sample["x"]) + dz * off * p.side
	p.z = float(_sample["z"]) - dx * off * p.side
	p.yaw = atan2(dx * p.dir, dz * p.dir)
	p.phase += dt * p.speed * 4.4


## 在节点处挑一条下一条边：只走能走的、且不是高速
func _pick_edge(node: int) -> int:
	var graph := _data.graph
	var start := graph.edge_off[node]
	var count := graph.edge_off[node + 1] - start
	if count <= 0:
		return -1
	var offset := _rng.randi_range(0, count - 1)
	for k in count:
		var e: int = graph.edge_list[start + ((k + offset) % count)]
		if graph.can_traverse(e, node) and graph.e_kind[e] >= 1:
			return e
	return -1


func _write_transform(index: int, p: Ped) -> void:
	var surf := _data.surface_at(p.x, p.z)
	var base: float = maxf(float(surf["y"]), C.Y_SIDEWALK)
	p.y = base
	# 走路起伏
	var bob := sin(p.phase * 2.0) * 0.032
	var origin := Vector3(p.x, base + bob, p.z)
	_basis = Basis(Vector3.UP, p.yaw)

	_mm_body.set_instance_transform(index, Transform3D(_basis, origin))
	_mm_body.set_instance_color(index, p.tint)

	# 四肢：绕关节摆动（手臂与腿反相）
	var swing := sin(p.phase) * 0.55
	var lateral := Vector3(cos(p.yaw), 0.0, -sin(p.yaw))
	for k in 2:
		var sign_v := -1.0 if k == 0 else 1.0
		var slot := index * 2 + k
		# 腿
		var leg_origin := origin + lateral * (HIP_HALF * sign_v) + Vector3(0.0, HIP_Y, 0.0)
		var leg_rot := _basis * Basis(Vector3(1.0, 0.0, 0.0), swing * sign_v)
		_mm_leg.set_instance_transform(slot, Transform3D(leg_rot, leg_origin))
		_mm_leg.set_instance_color(slot, p.tint)
		# 手臂（反相摆动）
		var arm_origin := origin + lateral * (SHOULDER_HALF * sign_v) + Vector3(0.0, SHOULDER_Y, 0.0)
		var arm_rot := _basis * Basis(Vector3(1.0, 0.0, 0.0), -swing * sign_v * 0.8)
		_mm_arm.set_instance_transform(slot, Transform3D(arm_rot, arm_origin))
		_mm_arm.set_instance_color(slot, p.tint)


func _hide(index: int) -> void:
	AssetUtil.hide_instance(_mm_body, index)
	AssetUtil.hide_instance(_mm_arm, index * 2)
	AssetUtil.hide_instance(_mm_arm, index * 2 + 1)
	AssetUtil.hide_instance(_mm_leg, index * 2)
	AssetUtil.hide_instance(_mm_leg, index * 2 + 1)


func active_count() -> int:
	var n := 0
	for p: Ped in _peds:
		if p.active:
			n += 1
	return n