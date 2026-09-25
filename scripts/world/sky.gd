## 天空与昼夜：程序化天空 + 单方向光 + 环境光 + 远景雾
## 昼夜由 time_of_day（0..1，0.25 = 正午、0.75 = 午夜）驱动，平滑过渡；
## 亮窗自发光与光晕强度由 WorldMaterials.set_night() 同步。
class_name SkyRig
extends Node3D

const SUN_ENERGY_DAY := 1.55
const SUN_ENERGY_NIGHT := 0.14

var env: WorldEnvironment
var sun: DirectionalLight3D
var sky_material: ProceduralSkyMaterial

# 0 = 午夜，0.25 = 日出，0.5 = 正午，0.75 = 日落（一天压缩成一份曲线）
var time_of_day := 0.42
var auto_cycle := true
## 一整天需要的秒数（自动循环时）
var day_length := 240.0

var _night := 0.0

var _top_day := Color(0.235, 0.435, 0.78)
var _top_night := Color(0.045, 0.062, 0.115)
var _horizon_day := Color(0.70, 0.80, 0.93)
var _horizon_night := Color(0.085, 0.105, 0.165)
var _sun_day := Color(1.0, 0.965, 0.90)
var _sun_low := Color(1.0, 0.60, 0.34)


func _ready() -> void:
	env = WorldEnvironment.new()
	var e := Environment.new()
	sky_material = ProceduralSkyMaterial.new()
	sky_material.sky_curve = 0.12
	sky_material.ground_curve = 0.06
	sky_material.sun_angle_max = 12.0
	sky_material.sun_curve = 0.08
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_128

	e.background_mode = Environment.BG_SKY
	e.sky = sky
	# 环境光走「纯色 + 随昼夜调色」，并关掉天空反射探针：
	# 天空间接光探针在核显上实测吃掉约 13 ms/帧（3200×2000 全屏：31 → 52 FPS）——
	# 它要每帧重烘焙一次立方体（实时模式），再让每个像素采样一次立方体贴图。
	# 天空本身的反射改由 city.gdshader 的解析式「假天光」补偿，观感基本一致。
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_sky_contribution = 0.0
	e.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 1.1
	e.tonemap_white = 6.0
	# 远景雾：掩盖 LOD 切换与地平线，让城市有纵深（起雾点退远一些，近处保持通透）
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_DEPTH
	e.fog_depth_begin = 1150.0
	e.fog_depth_end = 6200.0
	e.fog_density = 1.0
	env.environment = e
	add_child(env)

	sun = DirectionalLight3D.new()
	sun.light_angular_distance = 1.2
	sun.shadow_enabled = false  # 核显：关实时阴影，靠天空环境光与雾塑形
	sun.directional_shadow_max_distance = 400.0
	add_child(sun)

	_apply()


func _process(delta: float) -> void:
	if auto_cycle:
		time_of_day = fmod(time_of_day + delta / day_length, 1.0)
		_apply()


## 手动设置时刻（0..1）
func set_time(v: float) -> void:
	time_of_day = fmod(v, 1.0)
	_apply()


## 在昼夜之间切换（M 键）
func toggle_day_night() -> void:
	set_time(0.5 if _night > 0.4 else 0.86)


func night_factor() -> float:
	return _night


func _apply() -> void:
	# 太阳高度角：time 0.25 为日出、0.5 为正午、0.75 为日落
	var a := (time_of_day - 0.25) * TAU
	var elev := sin(a)          # -1..1
	var azimuth := time_of_day * TAU + 0.7
	var dir := Vector3(cos(azimuth) * cos(a * 0.5), maxf(elev, -0.25), sin(azimuth) * cos(a * 0.5))
	sun.look_at_from_position(dir * 1000.0, Vector3.ZERO, Vector3.UP)
	sun.light_energy = lerpf(SUN_ENERGY_NIGHT, SUN_ENERGY_DAY, clampf(elev * 1.6 + 0.25, 0.0, 1.0))
	sun.light_color = _sun_day.lerp(_sun_low, clampf(1.0 - elev * 2.2, 0.0, 1.0))

	# 夜晚因子：太阳落到地平线以下才算夜，日落过程平缓过渡
	_night = clampf(0.5 - elev * 1.4, 0.0, 1.0)

	var sky := sky_material
	sky.sky_top_color = _top_day.lerp(_top_night, _night)
	sky.sky_horizon_color = _horizon_day.lerp(_horizon_night, _night)
	sky.ground_bottom_color = sky.sky_top_color.darkened(0.45)
	sky.ground_horizon_color = sky.sky_horizon_color.darkened(0.2)
	sky.sky_energy_multiplier = lerpf(1.0, 0.72, _night)

	var e := env.environment
	# 白天适当压低环境光（让太阳方向性更明显、明暗对比更强）；
	# 夜间不要压太狠 —— 城市有大量环境光污染，纯黑反而假。
	# 颜色由天空色混合而来：原来由天空探针提供的「上蓝下暖」渐变，这里用一次 lerp 近似
	e.ambient_light_energy = lerpf(0.74, 0.72, _night)
	e.ambient_light_color = sky.ground_horizon_color.lerp(sky.sky_top_color, 0.45)
	e.fog_light_color = sky.sky_horizon_color.lerp(Color(0.52, 0.57, 0.65), 0.32)
	e.fog_light_energy = lerpf(0.9, 0.55, _night)
	e.tonemap_exposure = lerpf(1.12, 1.06, _night)