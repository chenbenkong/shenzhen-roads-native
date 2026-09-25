## 飞行器物理：街机化固定翼模型（不是气动仿真，目标是「好开、像样」）
##
## 设计取舍：
##  - 只用三个姿态量：yaw（航向）/ pitch（俯仰）/ roll（滚转），不做四元数积分
##  - 速度是「沿机头方向」的标量，另加一个垂直速度分量承担重力与升力
##  - 升力随速度平方增长，低于失速速度会掉高度；滚转自动带出协调转弯
##  - 浮筒机可以在水面与平地起降（最低高度按机身最低点 -1.45m 抬起）
##
## 机型数据来自原项目 floatplane-manifest.json（自建资产，尺寸与碰撞代理一致）：
##   翼展 14.03 / 机长 9.54 / 机高 3.85；机头前 4.37、机尾后 5.18、浮筒半宽 1.64、最低点 -1.45
class_name Aircraft
extends RefCounted

const WING_SPAN := 14.03
const LENGTH := 9.54
const HEIGHT := 3.85
const NOSE_FORWARD := 4.37
const TAIL_BACKWARD := 5.18
const FLOAT_HALF_WIDTH := 1.64
const LOWEST := -1.45

const MAX_THROTTLE_SPEED := 92.0    # m/s（约 330 km/h）
const TAKEOFF_SPEED := 26.0         # 抬轮速度
const CRUISE_ACCEL := 14.0
const GRAVITY := 9.81

var x := 0.0
var y := 0.0
var z := 0.0
var yaw := 0.0
var pitch := 0.0
var roll := 0.0
var speed := 0.0
var vy := 0.0
var throttle := 0.0
var on_water := false
var on_ground := false
var stalled := false
var g_force := 1.0
var impact := 0.0

var _prop_spin := 0.0
var _health := 100.0


func seat(px: float, py: float, pz: float, pyaw: float) -> void:
	x = px
	y = py
	z = pz
	yaw = pyaw
	pitch = 0.0
	roll = 0.0
	speed = 0.0
	vy = 0.0
	throttle = 0.0


func speed_kmh() -> float:
	return absf(speed) * 3.6


func propeller_angle() -> float:
	return _prop_spin


func health() -> float:
	return _health


## 每帧：pitch_in / roll_in / yaw_in 为 -1..1 操纵输入；throttle_in 0..1；brake 为刹车
func update(dt: float, data: CityData, pitch_in: float, roll_in: float, yaw_in: float, throttle_in: float, brake: bool) -> void:
	impact = 0.0
	throttle = clampf(throttle_in, 0.0, 1.0)

	# ── 速度：油门推力 - 阻力 ──
	var thrust := throttle * CRUISE_ACCEL
	var drag := (0.0016 * speed * speed) + (2.2 if brake and on_ground else 0.0)
	if on_ground or on_water:
		drag += 0.9  # 浮筒 / 起落架摩擦
	speed += (thrust - drag) * dt
	speed = clampf(speed, -12.0, MAX_THROTTLE_SPEED)
	if speed < 0.0 and throttle > 0.05:
		speed += 6.0 * dt  # 地面倒车推力有限

	# ── 姿态控制（速度越低舵面越无力）──
	var authority := clampf(speed / 34.0, 0.10, 1.0)
	pitch += pitch_in * 1.05 * authority * dt
	roll += roll_in * 2.10 * authority * dt
	# 滚转带来的协调转弯（坡度越大转弯越快）
	yaw += (-roll * 0.85 - yaw_in * 0.35) * clampf(speed / 45.0, 0.0, 1.4) * dt
	pitch = clampf(pitch, -1.15, 1.15)
	roll = clampf(roll, -1.45, 1.45)
	# 自动回中：松开滚转时缓慢回平
	if absf(roll_in) < 0.05:
		roll *= 1.0 - minf(1.0, dt * 0.9)

	# ── 升力与重力 ──
	var lift_accel := speed * speed * 0.0125
	stalled = speed < TAKEOFF_SPEED and not (on_ground or on_water)
	var net := lift_accel - GRAVITY
	if stalled:
		net -= 4.0  # 失速掉高度
	vy += net * dt
	vy += sin(pitch) * speed * 0.62 * dt  # 机头指向带来的爬升/俯冲
	vy = clampf(vy, -55.0, 42.0)
	# 空气阻尼让垂直速度收敛（不做真实阻尼积分）
	vy *= 1.0 - minf(0.5, dt * 0.35)
	if on_ground or on_water:
		vy = maxf(vy, 0.0)

	# ── 位移 ──
	var cp := cos(pitch)
	var fx := sin(yaw) * cp
	var fz := cos(yaw) * cp
	x += fx * speed * dt
	z += fz * speed * dt
	y += vy * dt

	# ── 地面 / 水面约束 ──
	var surf := _surface(data, x, z)
	on_water = surf["water"]
	on_ground = false
	var min_y: float = float(surf["y"]) - LOWEST
	if y <= min_y:
		var hard := vy < -6.0
		if hard:
			impact = clampf(-vy / 30.0, 0.0, 1.0)
			_health = maxf(0.0, _health - impact * 40.0)
		y = min_y
		vy = 0.0
		on_ground = true
		if absf(pitch) > 0.22:
			pitch *= 0.6
		roll *= 0.86

	# 撞建筑：只用机身中心圆，撞上就大幅减速（不做复杂反弹）
	var out := {}
	if data.collide_circle(x, z, 2.2, out):
		x = float(out["x"])
		z = float(out["z"])
		var hit := clampf(speed / 40.0, 0.0, 1.0)
		if hit > 0.05:
			impact = maxf(impact, hit)
			_health = maxf(0.0, _health - hit * 55.0)
		speed *= 0.25
		vy = minf(vy, 0.0)

	# 螺旋桨：随油门与速度旋转
	_prop_spin += dt * (3.0 + throttle * 34.0 + clampf(speed * 0.14, 0.0, 8.0))

	# 极低速贴地时视为停放
	if on_ground and speed < 0.6 and throttle < 0.05:
		speed = 0.0


func sample_surface(data: CityData) -> Dictionary:
	return _surface(data, x, z)


func _surface(data: CityData, px: float, pz: float) -> Dictionary:
	var s := data.surface_at(px, pz)
	var layer: int = s["layer"]
	if layer == 2:
		return {"y": C.Y_WATER, "water": true}
	var base: float = float(s["y"])
	return {"y": maxf(base, C.Y_LAND), "water": false}


func ground_y(data: CityData) -> float:
	return float(_surface(data, x, z)["y"])


func nose_position() -> Vector3:
	var cp := cos(pitch)
	return Vector3(x + sin(yaw) * cp * NOSE_FORWARD, y + sin(pitch) * NOSE_FORWARD, z + cos(yaw) * cp * NOSE_FORWARD)