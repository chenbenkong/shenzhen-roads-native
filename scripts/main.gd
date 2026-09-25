## 入口：加载城市数据 → 程序化图集与材质 → 分块世界 → 驾驶主循环
##
## 按键：W/↑ 油门、S/↓ 刹车倒车、A/D/←/→ 转向、空格 手刹、
##       C 切视角、R 换车、M 昼夜、F3 调试信息、Esc 释放/捕获鼠标
extends Node3D

const CHUNK_BUDGET_MS := 3.0

var data: CityData
var mats: WorldMaterials
var sky: SkyRig
var tiles: WorldTiles
var vehicle: Vehicle
var view: VehicleView
var chase: ChaseCamera
var audio: AudioEngine
var peds: Pedestrians
var traffic: Traffic
var on_foot: OnFoot
var aircraft: Aircraft
var aircraft_view: AircraftView
## false = 在车上驾驶；true = 下车步行
var walking := false
## 飞机模式（与 walking 互斥）
var flying := false
var fly_throttle := 0.0
var input := GameInput.new()
var notice := ""
var notice_timer := 0.0
var camera: Camera3D
var hud: Hud
var city_map: CityMap
var settings: SettingsPanel
var debug_label: Label
var show_debug := false
var show_map := false

var _car_index := 0
var _lod_distance := C.LOD_DISTANCE
var _fps_accum := 0.0
var _fps_frames := 0
var _fps := 0.0

## 自动驾驶回归测试：命令行追加 `-- autodrive` 时接管操控并自动截图退出
var _autodrive := false
var _auto_time := 0.0
var _auto_frame := 0
var _auto_throttle := 0.0
var _auto_steer := 0.0


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	print("[GPU] %s | API %s | 渲染方法 %s" % [
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_video_adapter_api_version(),
		ProjectSettings.get_setting("rendering/renderer/rendering_method"),
	])
	data = CityData.load_from("res://data/city.bin", "res://data/city-meta.json")
	if data == null:
		push_error("城市数据加载失败")
		get_tree().quit(1)
		return
	mats = WorldMaterials.create()

	sky = SkyRig.new()
	add_child(sky)

	tiles = WorldTiles.new()
	add_child(tiles)
	tiles.setup(data, mats)

	var spawn: Dictionary = data.meta["spawn"]
	var sx: float = spawn["x"]
	var sz: float = spawn["z"]
	var syaw: float = spawn["yaw"]

	# 出生点附近先建起来（异步：留在主循环里按预算继续建）
	for i in 12:
		tiles.update(sx, sz, 6.0, _lod_distance)

	vehicle = Vehicle.new(CarSpecs.by_index(_car_index), sx, sz, syaw)
	vehicle.place_on_ground(data)

	camera = Camera3D.new()
	sky.add_child(camera)
	chase = ChaseCamera.new(camera)
	chase.set_mode(ChaseCamera.Mode.CHASE)
	camera.current = true

	view = VehicleView.new()
	add_child(view)
	view.setup(vehicle.spec)

	audio = AudioEngine.new()
	add_child(audio)

	peds = Pedestrians.new()
	add_child(peds)
	peds.setup(data)

	traffic = Traffic.new()
	add_child(traffic)
	traffic.setup(data)

	on_foot = OnFoot.new()
	add_child(on_foot)
	on_foot.setup()
	on_foot.visible = false

	aircraft = Aircraft.new()
	aircraft_view = AircraftView.new()
	add_child(aircraft_view)
	aircraft_view.setup()
	aircraft_view.visible = false

	_build_ui()

	# 城市地图烘焙：GPU 一次成图（SubViewport 渲染后取回），小地图与大地图共用
	city_map = await CityMap.bake(get_tree(), data)
	if hud != null:
		hud.map = city_map

	input.set_mouse_captured(true)
	var args := OS.get_cmdline_user_args()
	_autodrive = args.has("autodrive")
	# nofx：关掉行人 / 车流，用于帧率基线对比
	if args.has("nofx"):
		peds.queue_free()
		traffic.queue_free()
		peds = null
		traffic = null
	if _autodrive:
		input.set_mouse_captured(false)
		show_debug = true
		debug_label.visible = true
	print("[启动] 就绪：%d ms（出生点 %.0f, %.0f，车辆 %s）%s" % [
		Time.get_ticks_msec() - t0, sx, sz, vehicle.spec.name,
		"  [自动驾驶测试]" if _autodrive else ""
	])


## F 键：上车 / 下车
func _toggle_walk() -> void:
	if walking:
		var dx := on_foot.x - vehicle.x
		var dz := on_foot.z - vehicle.z
		if sqrt(dx * dx + dz * dz) > 6.5:
			_notify("离车太远，走近到 6 米内再上车")
			return
		walking = false
		on_foot.visible = false
		view.visible = true
		vehicle.seat(vehicle.x, vehicle.z, vehicle.yaw)
		vehicle.place_on_ground(data)
		chase.set_walking(false)
		audio.ignition()
		_notify("已上车 · " + vehicle.spec.name)
	else:
		# 在车身左侧下车（找不到空位就退回右侧）
		var ok := false
		for i in 2:
			var side := -1.0 if i == 0 else 1.0
			var sx := vehicle.x - cos(vehicle.yaw) * 1.9 * side
			var sz := vehicle.z + sin(vehicle.yaw) * 1.9 * side
			if not data.blocked_at(sx, sz, 0.55):
				on_foot.place(sx, sz, vehicle.yaw, data)
				ok = true
				break
		if not ok:
			on_foot.place(vehicle.x, vehicle.z, vehicle.yaw, data)
		walking = true
		on_foot.visible = true
		view.visible = false
		chase.abs_yaw = vehicle.yaw
		chase.set_walking(true)
		_notify("已下车 · WASD 走路，Shift 跑，F 上车")


## B 键：上 / 下飞机（湾翼浮筒机）
func _toggle_fly() -> void:
	if flying:
		# 下机：站到机身侧后方（浮筒外侧），飞机就地停住
		var side_x := -cos(aircraft.yaw) * 3.0
		var side_z := sin(aircraft.yaw) * 3.0
		on_foot.place(aircraft.x + side_x, aircraft.z + side_z, aircraft.yaw, data)
		flying = false
		aircraft_view.visible = false
		on_foot.visible = true
		walking = true
		view.visible = false
		chase.abs_yaw = aircraft.yaw
		chase.set_walking(true)
		_notify("已下机 · F 上车 / B 再登机")
		return

	# 上机：飞机落在当前位置前方（水面或平地），高度贴地
	var fx := sin(vehicle.yaw if not walking else on_foot.yaw)
	var fz := cos(vehicle.yaw if not walking else on_foot.yaw)
	var ax := (on_foot.x if walking else vehicle.x) + fx * 16.0
	var az := (on_foot.z if walking else vehicle.z) + fz * 16.0
	var ayaw := on_foot.yaw if walking else vehicle.yaw
	aircraft.seat(ax, aircraft.ground_y(data) + 1.45, az, ayaw)
	aircraft_view.sync(aircraft)
	fly_throttle = 0.0
	flying = true
	walking = false
	aircraft_view.visible = true
	on_foot.visible = false
	view.visible = false
	chase.set_walking(false)
	chase.set_mode(ChaseCamera.Mode.FAR)
	audio.ignition()
	_notify("湾翼浮筒机 · Shift 加油门  W/S 俯仰  A/D 滚转  B 下机")


func _notify(text: String) -> void:
	notice = text
	notice_timer = 3.2


## 打开 / 关闭设置面板（Esc）
func _toggle_settings() -> void:
	if settings.visible:
		_close_settings()
	else:
		settings.visible = true
		show_map = false
		input.set_mouse_captured(false)
		audio.ui_click()


func _close_settings() -> void:
	if not settings.visible:
		return
	settings.visible = false
	input.set_mouse_captured(not show_map)
	audio.ui_click()


## 画质档位：视距 + 3D 渲染分辨率缩放 + 交通 / 行人密度
func _on_quality_changed(index: int) -> void:
	_lod_distance = settings.lod_distance()
	get_viewport().scaling_3d_scale = settings.render_scale()
	if traffic != null:
		traffic.max_active = settings.traffic_cap()
	if peds != null:
		peds.max_active = settings.ped_cap()
	_notify("画质 %s · 视距 %.0f m · 渲染分辨率 %d%%" % [
		SettingsPanel.QUALITY_NAMES[index],
		settings.lod_distance(),
		int(settings.render_scale() * 100.0)
	])


func _save_shot(path: String) -> void:
	# 导出后 res:// 是只读的 pck，截图统一写 user://（开发与打包两种形态都能落地）
	var out := "user://" + path.get_file()
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(out)
	print("[截图] %s → %s" % [ProjectSettings.globalize_path(out), "OK" if err == OK else str(err)])


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Hud.new()
	layer.add_child(hud)

	settings = SettingsPanel.new()
	# CenterContainer 负责居中：面板自身不参与定位，避免与容器布局互相打架
	var holder := CenterContainer.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(holder)
	holder.add_child(settings)
	settings.quality_changed.connect(_on_quality_changed)
	settings.volume_changed.connect(func(v: float) -> void: audio.set_volume(v))
	settings.sensitivity_changed.connect(func(v: float) -> void: chase.sensitivity = v)
	settings.debug_toggled.connect(func(on: bool) -> void:
		show_debug = on
		debug_label.visible = on
	)
	settings.closed.connect(_close_settings)
	debug_label = Label.new()
	debug_label.position = Vector2(24, 110)
	debug_label.offset_left = 24
	debug_label.offset_top = 110
	debug_label.add_theme_font_size_override("font_size", 14)
	debug_label.add_theme_color_override("font_color", Color(0.72, 0.86, 0.78))
	debug_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	debug_label.add_theme_constant_override("outline_size", 4)
	debug_label.visible = false
	layer.add_child(debug_label)


func _input(event: InputEvent) -> void:
	input.feed(event)
	if event is InputEventKey and event.pressed and not event.echo:
		_on_key(event.physical_keycode)


func _on_key(code: int) -> void:
	match code:
		KEY_C:
			chase.cycle_mode()
			audio.ui_click()
		KEY_R:
			_swap_vehicle((_car_index + 1) % CarSpecs.count())
		KEY_F:
			_toggle_walk()
		KEY_B:
			_toggle_fly()
		KEY_M:
			show_map = not show_map
			input.set_mouse_captured(not show_map)
		KEY_N:
			sky.toggle_day_night()
		KEY_ESCAPE:
			if show_map:
				show_map = false
				input.set_mouse_captured(true)
			elif settings.visible:
				_close_settings()
			else:
				_toggle_settings()
		KEY_F3:
			show_debug = not show_debug
			debug_label.visible = show_debug


func _swap_vehicle(index: int) -> void:
	_car_index = index
	var spec := CarSpecs.by_index(index)
	vehicle = Vehicle.new(spec, vehicle.x, vehicle.z, vehicle.yaw)
	vehicle.place_on_ground(data)
	view.setup(spec)
	audio.ignition()
	print("[载具] 切换为 %s" % spec.name)


## 自动驾驶回归测试：按帧驱动一段完整流程（驾驶 → 下车 → 走路 → 上车 → 退出）
func _auto_step(dt: float) -> void:
	_auto_frame += 1
	_auto_time += dt
	_auto_throttle = 0.0 if walking else 1.0
	_auto_steer = 0.0
	if not walking and _auto_time > 2.0:
		_auto_steer = 0.26 * sin(_auto_time * 0.55)
	match _auto_frame:
		150: _save_shot("res://tmp/drive_1_start.png")
		320: _save_shot("res://tmp/drive_2_cruise.png")
		350: chase.cycle_mode()
		420: _save_shot("res://tmp/drive_3_hood.png")
		430:
			chase.cycle_mode()
			chase.cycle_mode()
			sky.set_time(0.88)
		500: _save_shot("res://tmp/drive_4_night.png")
		510:
			sky.set_time(0.42)
			_toggle_walk()
		520: print("[自动驾驶] 已下车：步行位置 %.1f, %.1f" % [on_foot.x, on_foot.z])
		560: _save_shot("res://tmp/walk_1.png")
		570: _toggle_walk()
		580: _save_shot("res://tmp/walk_2_back_in_car.png")
		600:
			_toggle_fly()
			fly_throttle = 1.0
		610: print("[自动驾驶] 上机：起飞点 %.1f, %.1f 高度 %.1f" % [aircraft.x, aircraft.z, aircraft.y])
		700: _save_shot("res://tmp/fly_1.png")
		760: _save_shot("res://tmp/fly_2.png")
		770:
			show_map = true
		780: _save_shot("res://tmp/map_1.png")
		790:
			show_map = false
			_toggle_fly()  # 下机备注：验证从飞机切回步行
		800: _save_shot("res://tmp/fly_3_on_foot.png")
		820: _toggle_settings()
		850: _save_shot("res://tmp/settings_1.png")
		860: _close_settings()
		870:
			print("[自动驾驶] 结束：飞机 %.0f km/h 高度 %.0f m 状态(%s) FPS %.1f 绘制 %d 三角 %d" % [
				aircraft.speed_kmh(), aircraft.y - aircraft.ground_y(data),
				("水面" if aircraft.on_water else ("地面" if aircraft.on_ground else "飞行")), _fps,
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
			])
			get_tree().quit(0)


func _process(delta: float) -> void:
	var dt := minf(delta, 0.05)
	input.poll()
	if _autodrive:
		_auto_step(dt)

	# ── 操控 ──
	var throttle := 1.0 if (input.down(KEY_W) or input.down(KEY_UP)) else 0.0
	var braking := 1.0 if (input.down(KEY_S) or input.down(KEY_DOWN)) else 0.0
	var steer := input.axis(KEY_A, KEY_D)
	if steer == 0.0:
		steer = input.axis(KEY_LEFT, KEY_RIGHT)
	steer = -steer  # yaw 约定：正输入 = 右转 = yaw 减小
	var handbrake := input.down(KEY_SPACE)

	if walking:
		# 步行：WASD 相对相机移动，Shift 跑；车辆原地手刹停下
		var move_f := (1.0 if (input.down(KEY_W) or input.down(KEY_UP)) else 0.0) \
			- (1.0 if (input.down(KEY_S) or input.down(KEY_DOWN)) else 0.0)
		var move_r := (1.0 if (input.down(KEY_D) or input.down(KEY_RIGHT)) else 0.0) \
			- (1.0 if (input.down(KEY_A) or input.down(KEY_LEFT)) else 0.0)
		if _autodrive:
			move_f = 1.0
			move_r = 0.0
		on_foot.update(dt, data, chase.abs_yaw, move_f, move_r, input.down(KEY_SHIFT) or _autodrive)
		vehicle.update(dt, data, 0.0, 0.0, 0.0, true)
		view.sync(vehicle, dt)
		chase.update(dt, on_foot.x, on_foot.y, on_foot.z, on_foot.yaw,
			on_foot.speed / OnFoot.RUN_SPEED, OnFoot.EYE_Y, input, data)
		audio.update(dt, 0.0, 0.0, 0.0, false, false, false, false)
		_update_hud(dt)
		_update_world(dt)
		return

	if flying:
		_update_fly(dt)
		return

	if _autodrive:
		throttle = _auto_throttle
		steer = _auto_steer

	vehicle.update(dt, data, throttle, braking, steer, handbrake)

	# ── 视觉与相机 ──
	view.sync(vehicle, dt)
	if vehicle.impact > 0.02:
		audio.crash(vehicle.impact)
		chase.add_shake(vehicle.impact * 0.8)
	var speed_n := clampf(absf(vehicle.speed()) / maxf(1.0, vehicle.spec.max_speed), 0.0, 1.0)
	chase.update(dt, vehicle.x, vehicle.y, vehicle.z, vehicle.yaw,
		speed_n, vehicle.spec.height, input, data)

	# ── 昼夜与音效 ──
	audio.update(
		dt, vehicle.speed_kmh(), vehicle.rpm01(), throttle,
		vehicle.offroad, handbrake, vehicle.skidding, true
	)
	audio.horn(input.down(KEY_H))

	_update_world(dt)
	_update_hud(delta)


## 飞行：操纵 → 物理 → 外观 → 相机 → HUD
func _update_fly(dt: float) -> void:
	var pitch_in := (1.0 if (input.down(KEY_W) or input.down(KEY_UP)) else 0.0) \
		- (1.0 if (input.down(KEY_S) or input.down(KEY_DOWN)) else 0.0)
	var roll_in := (1.0 if (input.down(KEY_D) or input.down(KEY_RIGHT)) else 0.0) \
		- (1.0 if (input.down(KEY_A) or input.down(KEY_LEFT)) else 0.0)
	var yaw_in := input.axis(KEY_Q, KEY_E)
	if input.down(KEY_SHIFT):
		fly_throttle = minf(1.0, fly_throttle + dt * 0.65)
	if input.down(KEY_CTRL):
		fly_throttle = maxf(0.0, fly_throttle - dt * 0.85)
	if _autodrive:
		fly_throttle = 1.0
		pitch_in = 1.0 if aircraft.speed > Aircraft.TAKEOFF_SPEED else 0.0
		roll_in = 0.0

	aircraft.update(dt, data, pitch_in, roll_in, yaw_in, fly_throttle, input.down(KEY_SPACE))
	aircraft_view.sync(aircraft)
	# 车与人留在原地（车拉手刹）
	vehicle.update(dt, data, 0.0, 0.0, 0.0, true)
	view.sync(vehicle, dt)

	var sp_n := clampf(aircraft.speed / Aircraft.MAX_THROTTLE_SPEED, 0.0, 1.0)
	chase.update(dt, aircraft.x, aircraft.y + 0.5, aircraft.z, aircraft.yaw,
		sp_n, Aircraft.HEIGHT * 0.5, input, data)
	if aircraft.impact > 0.02:
		audio.crash(aircraft.impact)
		chase.add_shake(aircraft.impact)
	audio.horn(input.down(KEY_H))
	audio.update(dt, aircraft.speed_kmh(), 0.30 + fly_throttle * 0.7, fly_throttle,
		false, false, false, true)

	_update_world(dt)
	_update_hud(dt)


## 世界分块 + 动态实体 + 昼夜材质（驾驶与步行共用）
func _update_world(dt: float) -> void:
	var ax := on_foot.x if walking else (aircraft.x if flying else vehicle.x)
	var az := on_foot.z if walking else (aircraft.z if flying else vehicle.z)
	tiles.update(ax, az, CHUNK_BUDGET_MS, _lod_distance)
	if peds != null:
		peds.update(dt, ax, az)
	if traffic != null:
		traffic.update(dt, ax, az, vehicle)
	mats.set_night(sky.night_factor())
	view.set_lights(sky.night_factor())


func _update_hud(delta: float) -> void:
	_fps_accum += delta
	_fps_frames += 1
	if _fps_accum >= 0.5:
		_fps = _fps_frames / _fps_accum
		_fps_accum = 0.0
		_fps_frames = 0
	if notice_timer > 0.0:
		notice_timer = maxf(0.0, notice_timer - delta)

	# HUD 数据下沉到 Hud 自绘
	hud.notice = notice
	hud.notice_alpha = clampf(notice_timer / 1.2, 0.0, 1.0)
	hud.show_map = show_map
	hud.yaw = 0.0
	if flying:
		hud.mode_text = "飞行 · 湾翼浮筒机"
		hud.title = "湾翼 · 双浮筒观光机"
		hud.speed_kmh = aircraft.speed_kmh()
		hud.speed_limit = Aircraft.MAX_THROTTLE_SPEED * 3.6
		hud.gear_text = "%d%%" % int(fly_throttle * 100.0)
		var alt := aircraft.y - aircraft.ground_y(data)
		var st := "失速" if aircraft.stalled else ("水面" if aircraft.on_water else ("地面" if aircraft.on_ground else "飞行"))
		hud.sub_text = "高度 %.0f m · %s · Shift 加油门" % [alt, st]
		hud.health_ratio = aircraft.health() / 100.0
		hud.px = aircraft.x
		hud.pz = aircraft.z
		hud.yaw = aircraft.yaw
		hud.extra_hint = "W/S 俯仰　A/D 滚转　Q/E 方向舵　Shift/Ctrl 油门　空格 刹车　B 下机　M 地图"
	elif walking:
		hud.mode_text = "步行"
		hud.title = "步行中"
		hud.speed_kmh = on_foot.speed * 3.6
		hud.speed_limit = OnFoot.RUN_SPEED * 3.6
		hud.gear_text = "跑" if on_foot.running else "走"
		hud.sub_text = "Shift 奔跑 · F 上车 · B 上飞机"
		hud.health_ratio = 1.0
		hud.px = on_foot.x
		hud.pz = on_foot.z
		hud.yaw = on_foot.yaw
		hud.extra_hint = "WASD 移动　Shift 跑　F 上下车　B 上飞机　M 地图"
	else:
		hud.mode_text = "驾驶"
		hud.title = vehicle.spec.name
		hud.speed_kmh = vehicle.speed_kmh()
		hud.speed_limit = vehicle.spec.max_speed * 1.1 * 3.6
		hud.gear_text = "R" if vehicle.speed() < -0.5 else str(vehicle.gear())
		hud.sub_text = "车损 %d%% · %s" % [int(vehicle.health), chase.mode_name()]
		hud.health_ratio = vehicle.health / 100.0
		hud.px = vehicle.x
		hud.pz = vehicle.z
		hud.yaw = vehicle.yaw
		hud.extra_hint = "WASD 驾驶　空格 手刹　C 视角　R 换车　F 下车　B 上飞机　M 地图"
	hud.queue_redraw()
	if show_debug:
		var px := on_foot.x if walking else (aircraft.x if flying else vehicle.x)
		var pz := on_foot.z if walking else (aircraft.z if flying else vehicle.z)
		var mode_text := "飞行" if flying else ("步行" if walking else "驾驶")
		debug_label.text = "FPS %.0f（%.1f ms）  绘制 %d  三角 %d\n近景块 %d  mesh %d  行人 %d  车流 %d\n坐标 %.0f, %.0f  昼夜 %.2f  模式 %s\nWASD 移动  F 上下车  C 视角  R 换车  M 昼夜  Esc 鼠标" % [
			_fps, 1000.0 / maxf(1.0, _fps),
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			tiles.stats["near_chunks"], tiles.stats["meshes"],
			(peds.active_count() if peds != null else -1), (traffic.active_count() if traffic != null else -1),
			px, pz, sky.night_factor(), mode_text
		]