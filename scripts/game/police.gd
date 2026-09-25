## 警察通缉系统：星级热度 + 追捕警车
##
## 设计取向（GTA 式但更轻）：
##  - 热度（heat）由玩家行为累积：撞车 / 撞建筑 / 超速 / 逆行都会加热；作弊菜单可直接锁定星级
##  - 星级 = 热度分档 0..5，决定同时出动的警车数量
##  - 警车沿真实路网追赶：每个路口选择「朝玩家方向」的边，靠近后贴在玩家附近跟随
##  - 脱离视野（附近无警车）持续一段时间则降星 → 逃脱成功
##
## 渲染：警车与警灯各一个 MultiMesh（车漆用原版 car_plain，警灯用加色小方块交替闪红蓝）
class_name Police
extends Node3D

const MAX_UNITS := 8
## 生成距离：太远会「追不上也看不见」，太近又显得凭空出现
const SPAWN_MIN := 95.0
const SPAWN_MAX := 250.0
const DESPAWN := 420.0
const CATCH_RADIUS := 18.0
const ESCAPE_RADIUS := 150.0
const ESCAPE_TIME := 12.0
const SIREN_SPEED := 6.5

class Unit:
	var active := false
	var slot := 0
	var edge := 0
	var s := 0.0
	## 沿边推进方向：+1 走向 B 端，-1 走向 A 端（少这个方向就会「只会单向走」而追不上人）
	var dir := 1.0
	var speed := 0.0
	var x := 0.0
	var z := 0.0
	var yaw := 0.0
	var caught := 0.0


var wanted := 0
var heat := 0.0
var escaping := false
var escape_timer := 0.0
var siren_on := false

var _data: CityData
var _units: Array = []
var _mm_car: MultiMesh
var _mm_light: MultiMesh
var _free_car: Array = []
var _free_light: Array = []
var _rng := RandomNumberGenerator.new()
var _sample := {}
var _siren_phase := 0.0
var _spawn_cd := 0.0
var _max_units := 6


func setup(data: CityData) -> void:
	_data = data
	_rng.seed = 424242
	var car_mesh := AssetUtil.mesh_of("res://models/car_plain.glb")
	var mat := AssetUtil.vertex_color_material(0.30, 0.22)
	var car := AssetUtil.make_multimesh("police_cars", car_mesh, MAX_UNITS, mat)
	add_child(car[0])
	_mm_car = car[1]

	# 警灯：车顶加色小方块（不受光照，纯发光）
	var light_mesh := BoxMesh.new()
	light_mesh.size = Vector3(1.1, 0.16, 0.34)
	var light_mat := StandardMaterial3D.new()
	light_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	light_mat.albedo_color = Color(1, 1, 1)
	light_mat.vertex_color_use_as_albedo = true
	var lights := AssetUtil.make_multimesh("police_lights", light_mesh, MAX_UNITS, light_mat)
	add_child(lights[0])
	_mm_light = lights[1]

	for i in MAX_UNITS:
		var u := Unit.new()
		u.slot = i
		_units.append(u)
		AssetUtil.hide_instance(_mm_car, i)
		AssetUtil.hide_instance(_mm_light, i)
		_free_car.append(i)
		_free_light.append(i)


## 每帧：热度 → 星级 → 警车数量 / 追捕 / 逃脱
## forced >= 0 时锁定为该星级（作弊菜单）
func update(dt: float, px: float, pz: float, vehicle: Vehicle, forced: int) -> void:
	# ── 星级 ──
	if forced >= 0:
		wanted = clampi(forced, 0, 5)
		heat = float(wanted) * 10.0
	else:
		# 无警车靠近时热度自然衰减
		heat = maxf(0.0, heat - dt * (0.55 if _nearest(px, pz) > ESCAPE_RADIUS else 0.12))
		wanted = clampi(int(heat / 10.0), 0, 5)

	# ── 逃脱判定 ──
	if wanted > 0:
		if _nearest(px, pz) > ESCAPE_RADIUS:
			escape_timer += dt
			if escape_timer >= ESCAPE_TIME:
				escape_timer = 0.0
				heat = maxf(0.0, float(wanted - 1) * 10.0 - 1.0)
				_escapes += 1
		else:
			escape_timer = 0.0
		escaping = escape_timer > ESCAPE_TIME * 0.45
	else:
		escape_timer = 0.0
		escaping = false

	# ── 派车 ──
	_max_units = int(minf(float(MAX_UNITS), float(wanted) * 1.6))
	_spawn_cd = maxf(0.0, _spawn_cd - dt)
	var alive := _active_count()
	if alive < _max_units and _spawn_cd <= 0.0:
		if _spawn(px, pz):
			_spawn_cd = 0.7
	# 退役跑太远的车
	for u: Unit in _units:
		if not u.active:
			continue
		var dx := u.x - px
		var dz := u.z - pz
		if dx * dx + dz * dz > DESPAWN * DESPAWN:
			_retire(u)

	# ── 推进 ──
	siren_on = wanted > 0
	_siren_phase += dt * SIREN_SPEED
	for u: Unit in _units:
		if u.active:
			_drive(u, dt, px, pz, vehicle)
			_write(u)

	# 靠近玩家时算「被抓」计时（用于 HUD 提示与轻微惩罚）
	for u: Unit in _units:
		if not u.active:
			continue
		var dx := u.x - px
		var dz := u.z - pz
		if dx * dx + dz * dz < CATCH_RADIUS * CATCH_RADIUS:
			u.caught += dt
		else:
			u.caught = 0.0


var _escapes := 0


func escape_count() -> int:
	return _escapes


## 玩家行为加热度（撞车 / 撞建筑 / 超速）
func add_heat(amount: float) -> void:
	heat = minf(50.0, heat + amount)


func chase_count() -> int:
	return _active_count()


func _active_count() -> int:
	var n := 0
	for u: Unit in _units:
		if u.active:
			n += 1
	return n


func nearest_distance(px: float, pz: float) -> float:
	return _nearest(px, pz)


func _nearest(px: float, pz: float) -> float:
	var best := 1e9
	for u: Unit in _units:
		if not u.active:
			continue
		var dx := u.x - px
		var dz := u.z - pz
		var d := sqrt(dx * dx + dz * dz)
		if d < best:
			best = d
	return best


## 在玩家附近的路口附近放一辆警车（尽量放在玩家前方或侧后方）
func _spawn(px: float, pz: float) -> bool:
	if _free_car.is_empty():
		return false
	var graph := _data.graph
	for attempt in 6:
		var ang := _rng.randf() * TAU
		var rad := _rng.randf_range(SPAWN_MIN, SPAWN_MAX)
		var tx := px + cos(ang) * rad
		var tz := pz + sin(ang) * rad
		var hit := graph.closest_edge(tx, tz, 70.0)
		if hit.is_empty():
			continue
		var edge: int = hit["edge"]
		if graph.e_kind[edge] < 2:
			continue  # 小路不进警车
		var slot: int = _free_car.pop_back()
		_free_light.pop_back()
		var u := _unit_for_slot(slot)
		u.active = true
		u.edge = edge
		u.s = float(hit["s"])
		u.speed = 0.0
		u.caught = 0.0
		# 初始方向：朝玩家所在的那一端走
		var ea := graph.e_a[edge]
		var eb := graph.e_b[edge]
		var da := (graph.node_x[ea] - px) * (graph.node_x[ea] - px) + (graph.node_z[ea] - pz) * (graph.node_z[ea] - pz)
		var db := (graph.node_x[eb] - px) * (graph.node_x[eb] - px) + (graph.node_z[eb] - pz) * (graph.node_z[eb] - pz)
		u.dir = 1.0 if db < da else -1.0
		_drive(u, 0.0, px, pz, null)
		_write(u)
		return true
	return false


func _unit_for_slot(slot: int) -> Unit:
	for u: Unit in _units:
		if u.slot == slot:
			return u
	return _units[0]


func _retire(u: Unit) -> void:
	u.active = false
	AssetUtil.hide_instance(_mm_car, u.slot)
	AssetUtil.hide_instance(_mm_light, u.slot)
	_free_car.append(u.slot)
	_free_light.append(u.slot)


## 沿路网朝玩家方向推进：每个路口挑一条朝向玩家的边
func _drive(u: Unit, dt: float, px: float, pz: float, vehicle: Vehicle) -> void:
	var graph := _data.graph
	var dist := sqrt((px - u.x) * (px - u.x) + (pz - u.z) * (pz - u.z))
	# 目标速度：离得远就快，进入跟随距离后与玩家同速
	var want := 26.0
	if dist < 40.0:
		want = 14.0
	elif dist < 90.0:
		want = 20.0
	if vehicle != null and dist < 60.0:
		want = maxf(6.0, absf(vehicle.speed()) * 1.05)
	u.speed += (want - u.speed) * minf(1.0, dt * 1.6)

	u.s += u.speed * dt * u.dir
	var len := graph.e_len[u.edge]
	if u.s >= len or u.s <= 0.0:
		var node := graph.e_b[u.edge] if u.dir > 0.0 else graph.e_a[u.edge]
		var pick := _pick_toward(node, px, pz)
		if pick.is_empty():
			u.dir = -u.dir  # 死路，掉头
			u.s = clampf(u.s, 0.0, len)
		else:
			u.edge = int(pick["edge"])
			u.dir = float(pick["dir"])
			u.s = 0.0

	graph.sample_edge(u.edge, u.s, _sample)
	u.x = float(_sample["x"])
	u.z = float(_sample["z"])
	u.yaw = atan2(float(_sample["dx"]), float(_sample["dz"]))


## 挑一条最朝向玩家的可通行边；返回 {edge, dir}（dir: +1 走向 B 端 / -1 走向 A 端）
func _pick_toward(node: int, px: float, pz: float) -> Dictionary:
	var graph := _data.graph
	var start := graph.edge_off[node]
	var count := graph.edge_off[node + 1] - start
	if count <= 0:
		return {}
	var nx := graph.node_x[node]
	var nz := graph.node_z[node]
	var want_yaw := atan2(px - nx, pz - nz)
	var best_edge := -1
	var best_dir := 1.0
	var best_score := -2.0
	for k in count:
		var e: int = graph.edge_list[start + k]
		if not graph.can_traverse(e, node) or graph.e_kind[e] < 1:
			continue
		var forward := graph.e_a[e] == node
		var yaw := graph.edge_yaw_from(e, node)
		if not forward:
			yaw += PI
		var score := cos(wrapf(yaw - want_yaw, -PI, PI))
		if score > best_score:
			best_score = score
			best_edge = e
			best_dir = 1.0 if forward else -1.0
	if best_edge < 0:
		# 退而求其次：任何可通行边
		for k in count:
			var e: int = graph.edge_list[start + k]
			if graph.can_traverse(e, node):
				return {"edge": e, "dir": 1.0 if graph.e_a[e] == node else -1.0}
		return {}
	return {"edge": best_edge, "dir": best_dir}


func _write(u: Unit) -> void:
	var y := _data.graph.edge_y(u.edge, u.s)
	var basis := Basis(Vector3.UP, u.yaw)
	_mm_car.set_instance_transform(u.slot, Transform3D(basis, Vector3(u.x, y, u.z)))
	# 警车配色：白车身 + 深蓝引擎盖（用 instance color 整体染成近白）
	_mm_car.set_instance_color(u.slot, Color(0.92, 0.94, 0.97))
	# 警灯：红蓝交替（相位按车错开，避免全城同步闪）
	var phase := _siren_phase + float(u.slot) * 0.7
	var red := sin(phase) > 0.0
	var col := Color(1.0, 0.16, 0.12) if red else Color(0.25, 0.5, 1.0)
	var light_basis := basis * Basis(Vector3.UP, 0.0)
	_mm_light.set_instance_transform(u.slot, Transform3D(light_basis, Vector3(u.x, y + 1.52, u.z)))
	_mm_light.set_instance_color(u.slot, col)