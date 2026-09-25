## 车辆物理：街机化滑移模型（世界速度 + 航向分解），逐语义移植自 Web 版 vehicle.ts
##
## 每帧顺序（顺序不能改，改了手感就变）：
##   1. 按当前航向把世界速度分解为纵向 v_long / 横向 v_lat
##   2. 纵向施加油门 / 制动 / 阻力（含越野与手刹）
##   3. 用旧航向重组世界速度（速度矢量保持惯性）
##   4. 根据转向与车速更新航向 yaw（自行车模型）
##   5. 用新航向重新分解并施加侧向抓地衰减（产生推头 / 甩尾）
##   6. 位移 → 建筑碰撞推出 → 打滑判定 → 贴地采样 → 视觉俯仰/侧倾弹簧
##
## 约定：yaw = atan2(dx, dz)，前向 = (sin yaw, 0, cos yaw)，右向 = (-cos yaw, 0, sin yaw)
class_name Vehicle
extends RefCounted

## 换挡速度上限（m/s）：用速度分档模拟变速箱，供 HUD 与音效
## 注：PackedFloat32Array 构造不算常量表达式，故用静态变量（全局唯一）
static var GEAR_TOPS := PackedFloat32Array([13.0, 23.0, 34.0, 47.0, 63.0, 200.0])

var spec: CarSpecs.Spec
var x := 0.0
var y := C.Y_ROAD
var z := 0.0
var yaw := 0.0
## 世界速度（m/s）
var vx := 0.0
var vz := 0.0
var yaw_rate := 0.0
## 上一帧的横向速度（判断打滑用）
var v_lat := 0.0
## 平滑后的转向输入 -1..1
var steer_state := 0.0
## 车轮累计转角
var wheel_spin := 0.0
## 车损 0..100（100 为完好）
var health := 100.0
var started := true
## 视觉：车身俯仰 / 侧倾（弹簧感）
var body_pitch := 0.0
var body_roll := 0.0
## 本帧驾驶状态（供音频 / HUD 读取）
var offroad := false
var on_road := true
var skidding := false
## 本帧撞击强度 0..1（调用方读取后触发音效）
var impact := 0.0
## 车轮对地是否打滑（烧胎）
var wheel_slip := 0.0

## 引擎强化倍率（作弊菜单的「引擎强化」；1.0 为原厂性能）
var boost_accel := 1.0
var boost_top := 1.0

var _collider := {"x": 0.0, "z": 0.0, "nx": 0.0, "nz": 0.0}
var _last_long_speed := 0.0


func _init(p_spec: CarSpecs.Spec, px := 0.0, pz := 0.0, pyaw := 0.0) -> void:
	spec = p_spec
	x = px
	z = pz
	yaw = pyaw

# ============================================================================
# 只读状态
# ============================================================================


## 纵向速度（有符号，前进为正）
func speed() -> float:
	return vx * sin(yaw) + vz * cos(yaw)


func speed_kmh() -> float:
	return absf(speed()) * 3.6


func gear() -> int:
	var v := absf(speed())
	for i in GEAR_TOPS.size():
		if v < GEAR_TOPS[i]:
			return i + 1
	return GEAR_TOPS.size()


## 转速归一化 0..1（供音频与仪表）
func rpm01() -> float:
	var v := absf(speed())
	var g := gear() - 1
	var lo := 0.0 if g == 0 else GEAR_TOPS[g - 1]
	var hi: float = GEAR_TOPS[g]
	var t := clampf((v - lo) / maxf(1e-3, hi - lo), 0.0, 1.0)
	return 0.14 + t * 0.86


## 车轮半径（与车身几何保持一致）
func wheel_radius_hint() -> float:
	match spec.kind:
		"bus": return 0.53
		"truck": return 0.56
		"van": return 0.38
		"suv": return 0.40
		"sports": return 0.34
		_: return 0.33

# ============================================================================
# 操作
# ============================================================================


func seat(px: float, pz: float, pyaw: float) -> void:
	x = px
	z = pz
	yaw = pyaw
	vx = 0.0
	vz = 0.0
	yaw_rate = 0.0
	v_lat = 0.0
	steer_state = 0.0


func place_on_ground(data: CityData) -> void:
	var g := sample(data, x, z)
	y = g["y"]
	on_road = g["on_road"]
	offroad = not on_road


## 车头 / 车尾位置（相机、碰撞与车灯用）
func nose_forward(distance: float) -> Vector3:
	return Vector3(x + sin(yaw) * distance, y, z + cos(yaw) * distance)

# ============================================================================
# 主更新
# ============================================================================


func update(dt: float, data: CityData, throttle: float, brake: float, steer: float, handbrake: bool) -> void:
	impact = 0.0
	if not started:
		throttle = 0.0
		brake = 0.0
		steer = 0.0
		handbrake = false

	var fx := sin(yaw)
	var fz := cos(yaw)
	var rx := -cos(yaw)
	var rz := sin(yaw)

	var v_long := vx * fx + vz * fz
	var v_lat := vx * rx + vz * rz

	# ── 转向输入平滑 ──
	var target_steer := clampf(steer, -1.0, 1.0)
	steer_state += (target_steer - steer_state) * minf(1.0, dt * 10.0)

	# ── 纵向受力 ──
	var accel := 0.0
	var max_speed := spec.max_speed * boost_top
	var speed_n := clampf(absf(v_long) / max_speed, 0.0, 1.0)
	if not started:
		pass  # 熄火：只有滚阻
	elif throttle > 0.01:
		# 高速乏力：接近极速时功率下降
		accel += throttle * spec.accel * boost_accel * (1.0 - 0.62 * speed_n * speed_n)
		wheel_slip = 1.0 - speed_n / 0.28 if speed_n < 0.28 else 0.0
	else:
		wheel_slip = 0.0
	if brake > 0.01:
		if v_long > 0.7:
			accel -= brake * spec.brake
		else:
			accel -= brake * spec.accel * 0.6  # 倒车
	if handbrake:
		accel -= signf(v_long) * spec.brake * 0.5
	# 空气阻力（终速 = maxSpeed）+ 滚动阻力
	accel -= (spec.accel / (max_speed * max_speed)) * v_long * absf(v_long)
	var roll := 2.6 if offroad else 0.55
	accel -= signf(v_long) * roll * minf(1.0, absf(v_long))

	var prev_long := v_long
	v_long += accel * dt
	# 松油门低速时收敛到静止，避免抖动
	if absf(v_long) < 0.4 and throttle < 0.01 and not handbrake:
		if absf(prev_long) < 1.2 or signf(prev_long) != signf(v_long):
			v_long = 0.0
	var limit := max_speed * 1.05 if v_long >= 0.0 else spec.reverse_speed
	if absf(v_long) > limit:
		v_long = signf(v_long) * limit

	# ── 用旧航向重组世界速度（惯性） ──
	vx = fx * v_long + rx * v_lat
	vz = fz * v_long + rz * v_lat

	# ── 航向（自行车模型） ──
	var steer_angle := (steer_state * spec.steer_max) / (1.0 + pow(absf(v_long) / 22.0, 1.25))
	var yaw_target := -(v_long / spec.wheelbase) * tan(steer_angle)
	yaw_rate += (yaw_target - yaw_rate) * minf(1.0, dt * 8.0)
	yaw += yaw_rate * dt

	# ── 新航向下重新分解并施加侧向抓地 ──
	var nfx := sin(yaw)
	var nfz := cos(yaw)
	var nrx := -cos(yaw)
	var nrz := sin(yaw)
	var n_long := vx * nfx + vz * nfz
	var n_lat := vx * nrx + vz * nrz
	var grip := spec.grip * (0.24 if handbrake else 1.0) * (0.7 if offroad else 1.0)
	n_lat *= exp(-grip * dt)
	vx = nfx * n_long + nrx * n_lat
	vz = nfz * n_long + nrz * n_lat
	v_lat = n_lat

	# ── 位移与碰撞 ──
	x += vx * dt
	z += vz * dt
	resolve_collision(data)

	# ── 打滑判定 ──
	var lat_abs := absf(n_lat)
	skidding = lat_abs > 3.4 and absf(n_long) > 5.0
	if skidding:
		var k := 1.0 - minf(0.35, lat_abs * 0.012)
		vx *= k
		vz *= k

	# ── 贴地 ──
	var g := sample(data, x, z)
	y = g["y"]
	on_road = g["on_road"]
	offroad = not on_road

	# ── 视觉：车身俯仰 / 侧倾弹簧 ──
	var long_acc := (n_long - _last_long_speed) / maxf(1e-3, dt)
	_last_long_speed = n_long
	var lat_acc := yaw_rate * n_long
	var want_pitch := clampf(-long_acc * 0.006, -0.07, 0.07)
	var want_roll := clampf(lat_acc * 0.01, -0.1, 0.1)
	var k2 := minf(1.0, dt * 6.0)
	body_pitch += (want_pitch - body_pitch) * k2
	body_roll += (want_roll - body_roll) * k2

	# ── 车轮转动 ──
	wheel_spin += (n_long / maxf(0.15, wheel_radius_hint())) * dt

# ============================================================================
# 地形 / 碰撞
# ============================================================================


## 采样某点的地面高度（优先路面，其次地表分层）
func sample(data: CityData, px: float, pz: float) -> Dictionary:
	var graph := data.graph
	var hit := graph.closest_edge(px, pz, 48.0)
	if not hit.is_empty():
		var edge: int = hit["edge"]
		var road := graph.e_road[edge]
		if float(hit["dist"]) <= graph.road_width(road) * 0.5 + 1.4:
			return {"y": graph.edge_y(edge, float(hit["s"])), "on_road": true}
	var s := data.surface_at(px, pz)
	var layer: int = s["layer"]
	if layer == 2:
		return {"y": C.Y_WATER, "on_road": false}
	if layer == 1:
		return {"y": C.Y_GRASS, "on_road": false}
	return {"y": C.Y_LAND, "on_road": false}


## 与建筑碰撞：前后两个圆的推出 + 撞击能量损失
func resolve_collision(data: CityData) -> void:
	var half := spec.length * 0.33
	var radius := spec.width * 0.5 + 0.1
	var fx := sin(yaw)
	var fz := cos(yaw)
	var worst := 0.0
	for i in 2:
		var s := -1.0 if i == 0 else 1.0
		var px := x + fx * half * s
		var pz := z + fz * half * s
		if not data.collide_circle(px, pz, radius, _collider):
			continue
		# 推出到接触点外
		x += float(_collider["x"]) - px
		z += float(_collider["z"]) - pz
		var nx := float(_collider["nx"])
		var nz := float(_collider["nz"])
		var vn := vx * nx + vz * nz
		if vn < 0.0:
			# 法向速度反弹（含少量弹性）
			vx -= nx * vn * 1.3
			vz -= nz * vn * 1.3
			worst = maxf(worst, -vn)
		# 刮擦摩擦
		vx *= 0.82
		vz *= 0.82
		yaw_rate *= 0.4
	if worst > 0.6:
		var k := minf(1.0, worst / 22.0)
		impact = k
		health = maxf(0.0, health - k * 26.0)