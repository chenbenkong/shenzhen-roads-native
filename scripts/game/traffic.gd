## AI 交通流：沿路网行驶的车辆，遵守单行与限速，带简易跟车避让
##
## 性能设计：
##  - 每个车型一份合并几何（CarGeometry.traffic_mesh），用 MultiMesh 一次性绘制 → 每个车型 1 个 draw call
##  - 固定车辆池（零 GC）；只在玩家附近生成，远处回收
##  - 车辆不影响物理世界（不与玩家碰撞），只做视觉密度与氛围；玩家撞到它们时由玩家侧判定
class_name Traffic
extends Node3D

const MAX_CARS := 64
const SPAWN_RADIUS := 330.0
const DESPAWN_RADIUS := 480.0
const SAFE_GAP := 9.0

class Car:
	var active := false
	var model := 0          # 车型索引
	var slot := 0           # 在该车型 MultiMesh 中的实例下标
	var edge := 0
	var s := 0.0
	var speed := 0.0
	var target_speed := 12.0
	var x := 0.0
	var z := 0.0
	var yaw := 0.0
	var braking := false


var _data: CityData
var _mms: Array = []            # 每车型一个 MultiMesh
var _slots: Array = []          # 每车型已被占用的实例下标
var _free_slots: Array = []     # 每车型空闲实例下标（从后往前分配）
var _cars: Array = []
var _rng := RandomNumberGenerator.new()
var _sample := {}
var _geo_script: GDScript = null
## 同时存在的车辆上限（设置面板的画质档位会调它）
var max_active := MAX_CARS


func setup(data: CityData) -> void:
	_data = data
	_rng.seed = 20260926

	var scripts := "res://scripts/game/car_geometry.gd"
	if ResourceLoader.exists(scripts):
		_geo_script = load(scripts)
		if not _geo_script.has_method("traffic_mesh"):
			_geo_script = null

	var models := CarSpecs.count()
	for mi in models:
		var spec := CarSpecs.by_index(mi)
		var mesh: Mesh = null
		# 小客车统一用原项目自建的交通车模型（car_plain.glb，3836 三角，细节优于程序化车身）；
		# 巴士 / 卡车仍用程序化几何，保证街区里有大小车的层次
		if not spec.is_big():
			mesh = AssetUtil.mesh_of("res://models/car_plain.glb")
		if mesh == null and _geo_script != null:
			mesh = _geo_script.call("traffic_mesh", spec)
		if mesh == null:
			mesh = _placeholder_mesh(spec)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		mm.instance_count = _per_model_cap(mi)
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "traffic_%s" % spec.id
		mmi.multimesh = mm
		# 显式给顶点色材质：既保证 glb 自带的顶点色参与着色，也让 MultiMesh 的 instance color 能整体换色
		# 车漆要有点光泽（roughness 低 + 金属度略高），否则车看起来像水泥块
		mmi.material_override = AssetUtil.vertex_color_material(0.30, 0.22)
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		_mms.append(mm)
		_slots.append([])
		var free: Array = []
		for i in mm.instance_count:
			free.append(i)
			_hide_instance(mi, i)
		_free_slots.append(free)

	for i in MAX_CARS:
		_cars.append(Car.new())


func _per_model_cap(model: int) -> int:
	var spec := CarSpecs.by_index(model)
	if spec.is_big():
		return 6   # 巴士 / 卡车数量少
	return 12


func _placeholder_mesh(spec: CarSpecs.Spec) -> Mesh:
	var b := BoxMesh.new()
	b.size = Vector3(spec.width, spec.height * 0.6, spec.length)
	return b

# ============================================================================
# 主循环
# ============================================================================


func update(dt: float, px: float, pz: float, vehicle: Vehicle) -> void:
	var spawn_budget := 2
	var alive := 0
	for i in MAX_CARS:
		var c: Car = _cars[i]
		if c.active:
			alive += 1
		if not c.active:
			if spawn_budget > 0 and alive < max_active:
				spawn_budget -= 1
				if _spawn(i, c, px, pz):
					alive += 1
			continue
		var dx := c.x - px
		var dz := c.z - pz
		if dx * dx + dz * dz > DESPAWN_RADIUS * DESPAWN_RADIUS:
			_retire(c)
			continue
		_drive(c, dt, vehicle)
		_write(c)


## 给一辆空车找位置：在玩家附近的路面上，且不能与玩家车重叠
func _spawn(index: int, c: Car, px: float, pz: float) -> bool:
	var graph := _data.graph
	var attempts := 5
	while attempts > 0:
		attempts -= 1
		var ang := _rng.randf() * TAU
		var rad := _rng.randf_range(70.0, SPAWN_RADIUS)
		var tx := px + cos(ang) * rad
		var tz := pz + sin(ang) * rad
		var hit := graph.closest_edge(tx, tz, 60.0)
		if hit.is_empty():
			continue
		var edge: int = hit["edge"]
		var road := graph.e_road[edge]
		var kind := graph.e_kind[edge]
		if kind < 2:
			continue  # 太小的路不放车
		# 车型：大车只出现在主干道
		var model := _rng.randi_range(0, CarSpecs.count() - 1)
		var spec := CarSpecs.by_index(model)
		if spec.is_big() and kind < 3:
			model = _rng.randi_range(0, 2)
			spec = CarSpecs.by_index(model)
		if _free_slots[model].is_empty():
			continue
		# 不能生成在玩家鼻子底下
		var ddx := tx - px
		var ddz := tz - pz
		if ddx * ddx + ddz * ddz < 900.0:
			continue

		c.active = true
		c.model = model
		c.slot = _free_slots[model].pop_back()
		c.edge = edge
		c.s = float(hit["s"])
		var limit := graph.e_speed[edge]
		c.target_speed = limit * _rng.randf_range(0.72, 1.0)
		c.speed = c.target_speed * 0.6
		_slots[model].append(c.slot)
		_write_color(c)
		_drive(c, 0.0, null)
		_write(c)
		return true
	return false


func _retire(c: Car) -> void:
	c.active = false
	_hide_instance(c.model, c.slot)
	_free_slots[c.model].append(c.slot)
	var arr: Array = _slots[c.model]
	arr.erase(c.slot)


## 沿边推进（含跟车减速）；vehicle 为玩家车（可能为 null）
func _drive(c: Car, dt: float, vehicle: Vehicle) -> void:
	var graph := _data.graph
	# 跟车：本车前方 SAFE_GAP 内是否有别的 AI 车
	var gap_ahead := 1e9
	for other: Car in _cars:
		if other == c or not other.active or other.edge != c.edge:
			continue
		var ds := other.s - c.s
		if ds > 0.0 and ds < gap_ahead:
			gap_ahead = ds
	var want := c.target_speed
	if gap_ahead < SAFE_GAP:
		want = 0.0
	elif gap_ahead < SAFE_GAP * 2.5:
		want = c.target_speed * 0.45
	# 玩家车离得很近时也点刹
	if vehicle != null:
		var ddx := vehicle.x - c.x
		var ddz := vehicle.z - c.z
		var d2 := ddx * ddx + ddz * ddz
		if d2 < 64.0:
			want = 0.0
	c.braking = want < c.speed - 0.5
	c.speed += (want - c.speed) * minf(1.0, dt * (2.2 if want < c.speed else 1.1))

	var len := graph.e_len[c.edge]
	c.s += c.speed * dt
	if c.s >= len or c.s < 0.0:
		var node := graph.e_b[c.edge]
		var next := _pick_edge(node)
		if next < 0:
			c.s = clampf(c.s, 0.0, len)
			c.speed = 0.0
		else:
			c.edge = next
			c.s = 0.0
			c.target_speed = graph.e_speed[next] * _rng.randf_range(0.72, 1.0)

	graph.sample_edge(c.edge, c.s, _sample)
	c.x = float(_sample["x"])
	c.z = float(_sample["z"])
	var dx: float = _sample["dx"]
	var dz: float = _sample["dz"]
	var road := graph.e_road[c.edge]
	var lanes := maxi(1, graph.e_lanes[c.edge])
	# 靠右行驶：车道横向偏移（多车道按车道数分布）
	var off := graph.road_width(road) * 0.25 * (1.0 - 1.0 / float(lanes))
	c.x += dz * off
	c.z -= dx * off
	c.yaw = atan2(dx, dz)


func _pick_edge(node: int) -> int:
	var graph := _data.graph
	var start := graph.edge_off[node]
	var count := graph.edge_off[node + 1] - start
	if count <= 0:
		return -1
	var offset := _rng.randi_range(0, count - 1)
	for k in count:
		var e := graph.edge_list[start + ((k + offset) % count)]
		if graph.can_traverse(e, node) and graph.e_kind[e] >= 2:
			return e
	return -1


func _write(c: Car) -> void:
	var y := _data.graph.edge_y(c.edge, c.s)
	var basis := Basis(Vector3.UP, c.yaw)
	var xform := Transform3D(basis, Vector3(c.x, y, c.z))
	_mms[c.model].set_instance_transform(c.slot, xform)


func _write_color(c: Car) -> void:
	var spec := CarSpecs.by_index(c.model)
	var col := spec.body_color
	if not spec.is_big() and spec.id != "taxi":
		col = CarSpecs.TRAFFIC_COLORS[_rng.randi_range(0, CarSpecs.TRAFFIC_COLORS.size() - 1)]
	_mms[c.model].set_instance_color(c.slot, col)


func _hide_instance(model: int, slot: int) -> void:
	var far := Transform3D(Basis().scaled(Vector3(0.0001, 0.0001, 0.0001)), Vector3(0.0, -500.0, 0.0))
	_mms[model].set_instance_transform(slot, far)


func active_count() -> int:
	var n := 0
	for c: Car in _cars:
		if c.active:
			n += 1
	return n


## 供主循环读取：最近的一辆 AI 车距离（用于统计/调试）
func nearest_distance(px: float, pz: float) -> float:
	var best := 1e9
	for c: Car in _cars:
		if not c.active:
			continue
		var dx := c.x - px
		var dz := c.z - pz
		var d := sqrt(dx * dx + dz * dz)
		if d < best:
			best = d
	return best