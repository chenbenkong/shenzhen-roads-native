## 第三人称视角：追尾（默认）/ 远景 / 引擎盖；鼠标自由环视 + 滚轮拉近拉远
##
## 通用化设计：接受「任意跟随目标」（载具或步行角色），只需给出位置 / 朝向 / 速度比 / 头部高度。
##
## 特点：
##  - 相机位置指数平滑跟随，转向时轻微滞后；速度越高 FOV 越广（速度感）
##  - 静止 1.2 秒后视角自动回正到身后偏上
##  - 相机被建筑挡住时自动拉近并抬高（最多迭代 4 次）
class_name ChaseCamera
extends RefCounted

enum Mode { CHASE, FAR, HOOD }

const MODE_NAMES := ["追尾", "远景", "引擎盖"]

var camera: Camera3D
var mode: int = Mode.CHASE

var orbit_yaw := 0.0
var orbit_pitch := 0.22
var distance := 8.6

var _pos := Vector3.ZERO
var _idle := 0.0
var _shake := 0.0
var _initialized := false
var _walk := false
## 绝对朝向模式（步行）：相机朝向由鼠标独立控制，不随角色转身 → 否则会与「角色转向移动方向」互相追逐打转
var absolute_mode := false
var abs_yaw := 0.0
## 视角灵敏度（设置面板可调，1.0 为默认）
var sensitivity := 1.0


func _init(cam: Camera3D) -> void:
	camera = cam
	camera.near = 0.5
	camera.far = C.VIEW_FAR


## 步行模式：距离更近、俯角更平（车与人的观感差异）
## 注：切到步行时调用方应先设好 abs_yaw（一般取下车时的车身朝向），
## 这样相机不会瞬间跳到别的方向。
func set_walking(on: bool) -> void:
	_walk = on
	absolute_mode = on
	if on:
		distance = 5.0
		orbit_pitch = 0.16
		mode = Mode.CHASE
	else:
		distance = 8.6
		orbit_pitch = 0.22


func set_mode(m: int) -> void:
	mode = m
	if mode == Mode.HOOD:
		distance = 0.0
	elif mode == Mode.FAR:
		distance = 15.0
	else:
		distance = 5.0 if _walk else 8.6


func cycle_mode() -> int:
	set_mode((mode + 1) % 3)
	return mode


func mode_name() -> String:
	return MODE_NAMES[mode]


func add_shake(strength: float) -> void:
	_shake = maxf(_shake, clampf(strength, 0.0, 1.0))


## dt 秒；目标位置 (px, py, pz)、朝向 yaw、速度比 speed_n（0..1）、头部高度 head_y
func update(
	dt: float, px: float, py: float, pz: float, yaw: float,
	speed_n0: float, head_y: float, input: GameInput, data: CityData
) -> void:
	var speed_n := clampf(speed_n0, 0.0, 1.0)

	# ── 鼠标环视 ──
	var mdx := input.mouse_dx * sensitivity
	var mdy := input.mouse_dy * sensitivity
	if absf(mdx) + absf(mdy) > 0.01:
		if absolute_mode:
			abs_yaw -= mdx * 0.0035
		else:
			orbit_yaw -= mdx * 0.0035
		orbit_pitch = clampf(orbit_pitch + mdy * 0.0030, -0.35, 1.05)
		_idle = 0.0
	else:
		_idle += dt
		if _idle > 1.2:
			var k := minf(1.0, dt * 1.6)
			orbit_yaw += -orbit_yaw * k
			orbit_pitch += ((0.16 if _walk else 0.22) - orbit_pitch) * k

	var wheel := input.take_wheel()
	if absf(wheel) > 0.01:
		distance = clampf(distance * exp(wheel * 0.12), 3.2 if _walk else 4.2, 22.0)

	var fx := sin(yaw)
	var fz := cos(yaw)
	var look_ahead := (1.4 if _walk else 5.0 + speed_n * 9.0)

	# ── 引擎盖视角（仅载具）──
	if mode == Mode.HOOD and not _walk:
		var head := Vector3(px + fx * 1.1, py + head_y * 0.92, pz + fz * 1.1)
		_update_rigid(head, Vector3(fx, 0.0, fz), dt, 14.0)
		camera.fov = 68.0 + speed_n * 12.0
		_apply_shake()
		return

	# ── 环视位置 ──
	var total_yaw := abs_yaw + PI if absolute_mode else yaw + PI + orbit_yaw
	var horiz := cos(orbit_pitch) * distance
	var vert := sin(orbit_pitch) * distance
	var tx := px + sin(total_yaw) * horiz
	var tz := pz + cos(total_yaw) * horiz
	var ty := py + (1.2 if _walk else 1.8) + vert

	# 绝对模式下注视点跟着相机朝向，否则相机会盯着角色背后看
	var look_fx := sin(abs_yaw) if absolute_mode else fx
	var look_fz := cos(abs_yaw) if absolute_mode else fz
	var look := Vector3(px + look_fx * look_ahead, py + (1.45 if _walk else 1.1), pz + look_fz * look_ahead)
	var extra_y := 0.0
	var dist_scale := 1.0
	for i in 4:
		var qx := look.x + (tx - look.x) * dist_scale
		var qz := look.z + (tz - look.z) * dist_scale
		if not data.blocked_at(qx, qz, 0.6):
			break
		dist_scale *= 0.72
		extra_y += 1.2

	var target := Vector3(
		look.x + (tx - look.x) * dist_scale,
		ty + extra_y,
		look.z + (tz - look.z) * dist_scale
	)

	if not _initialized:
		_pos = target
		_initialized = true
	else:
		var k := 1.0 - exp(-dt * 8.5)
		_pos += (target - _pos) * k
	# 别钻到地面以下
	var ground := data.surface_at(_pos.x, _pos.z)
	var min_y: float = float(ground["y"]) + 0.9
	if _pos.y < min_y:
		_pos.y = min_y

	camera.global_position = _pos
	camera.look_at(look + Vector3(0.0, 0.55, 0.0), Vector3.UP)
	camera.fov = 60.0 + speed_n * 10.0
	_apply_shake()


## 刚性跟随（引擎盖视角）：位置平滑，朝向固定为前进方向
func _update_rigid(p: Vector3, forward: Vector3, dt: float, rate: float) -> void:
	if not _initialized:
		_pos = p
		_initialized = true
	var k := 1.0 - exp(-dt * rate)
	_pos += (p - _pos) * k
	camera.global_position = _pos
	camera.look_at(_pos + forward * 12.0 + Vector3(0.0, -0.06, 0.0), Vector3.UP)


func _apply_shake() -> void:
	if _shake <= 0.001:
		return
	var f := _shake * 0.35
	camera.h_offset = (randf() * 2.0 - 1.0) * f
	camera.v_offset = (randf() * 2.0 - 1.0) * f
	_shake = maxf(0.0, _shake - 0.06)