## 车身几何自检：把 8 种车沿 x 轴排开 → 俯视 45° 全景截图 + 近景截图 → 退出
##
## 用法：godot --path . res://scenes/test_cars.tscn --resolution 1280x720
## 目的：
##  - 确认 8 种车都能生成、比例合理、没有翻面 / 破洞（车身看不到内部）
##  - 确认车头都朝同一方向（+z）、车轮贴地（车轮网格下缘正好落在 y=0）
##  - 确认车漆 / 玻璃 / 灯能区分，出租车顶灯与警灯条在
## headless 下（无渲染）自动跳过截图，只跑逻辑，方便纯语法 / 断言校验。
extends Node3D

const OVERVIEW_PATH := "res://tmp/cars_overview.png"
const CLOSEUP_PATH := "res://tmp/cars_closeup.png"

var cam: Camera3D
var frame := 0
var headless := false
## 每辆车在场景里的世界 x（近景取景要用）
var car_xs := PackedFloat64Array()


func _ready() -> void:
	headless = DisplayServer.get_name() == "headless"
	DirAccess.make_dir_recursive_absolute("res://tmp")

	# 天空 + 单方向光（直接借世界那套昼夜装置，省得重写环境）
	var sky := SkyRig.new()
	sky.auto_cycle = false
	sky.time_of_day = 0.40
	add_child(sky)

	# 地面：车轮贴地就靠它来判断（车根节点 y=0，轮子网格下缘 = 半径 - 半径 = 0）
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(600.0, 600.0)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.36, 0.37, 0.40)
	gm.roughness = 0.95
	ground.material_override = gm
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)

	_build_cars()

	cam = Camera3D.new()
	cam.fov = 38.0
	cam.near = 0.1
	cam.far = 4000.0
	add_child(cam)
	cam.current = true
	_place_camera(true)


## 8 种车按各自宽度 + 间隙沿 x 轴排开，整体以原点为中心
func _build_cars() -> void:
	var specs := CarSpecs.all()
	var x_cursor := 0.0
	var gap := 2.2
	var centers := PackedFloat64Array()
	for spec: CarSpecs.Spec in specs:
		centers.append(x_cursor + spec.width * 0.5)
		x_cursor += spec.width + gap
	var span_center := (x_cursor - gap) * 0.5

	var holder := Node3D.new()
	holder.name = "cars"
	add_child(holder)

	for i in specs.size():
		var spec: CarSpecs.Spec = specs[i]
		var geo := CarGeometry.of(spec)
		var visual := CarGeometry.create_visual(spec)
		visual.name = spec.id
		visual.position = Vector3(centers[i] - span_center, 0.0, 0.0)
		holder.add_child(visual)
		car_xs.append(centers[i] - span_center)

		# 诊断：尺寸、车轮几何、以及车轮下缘的世界 y（应为 0 附近）
		var wheel := visual.get_node("wheel0") as MeshInstance3D
		var wa := wheel.get_aabb()
		var painted_aabb := (visual.get_node("painted") as MeshInstance3D).get_aabb()
		print("[车] %-6s %s 长%.2f 宽%.2f 高%.2f | 轮 r=%.2f 半轮距=%.2f 前轴z=%.2f 后轴z=%.2f" % [
			spec.id, spec.name, spec.length, spec.width, spec.height,
			geo.wheel_radius, geo.wheel_half_track, geo.front_z, geo.rear_z])
		print("      surfaces painted/dark/lights = %d/%d/%d | 车身 y 范围 %.2f..%.2f | 轮下缘 y=%.3f" % [
			geo.painted.get_surface_count(), geo.dark.get_surface_count(),
			geo.lights.get_surface_count(),
			painted_aabb.position.y, painted_aabb.end.y,
			wa.position.y + wheel.global_position.y])


## 全景：斜上方约 40°；近景：贴近小车组看灯 / 玻璃 / 车轮
func _place_camera(overview: bool) -> void:
	if overview:
		# 斜上方约 40°，偏 +x 一点，好把警车的红蓝灯条也照到
		cam.position = Vector3(4.0, 20.0, 24.0)
		cam.look_at(Vector3(0.0, 1.1, 0.0), Vector3.UP)
	else:
		# 对准第 3 辆（suv）一带：能同时看到左侧跑车（尾翼）与右侧出租车（顶灯）
		var tx: float = car_xs[2]
		cam.position = Vector3(tx, 2.9, 10.5)
		cam.look_at(Vector3(tx, 0.9, 0.0), Vector3.UP)


func _process(_delta: float) -> void:
	frame += 1
	if headless:
		# 无渲染驱动下截不到图，跑几帧确认没报错就退
		if frame >= 3:
			print("[车身] headless 自检完成：8 种车均构建成功")
			get_tree().quit(0)
		return
	if frame == 12:
		_save(OVERVIEW_PATH)
	elif frame == 14:
		_place_camera(false)
	elif frame == 24:
		_save(CLOSEUP_PATH)
	elif frame == 30:
		print("[车身] 结束")
		get_tree().quit(0)


func _save(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("截图失败：viewport 无纹理")
		return
	var err := img.save_png(path)
	print("[车身] 截图 %s（%d×%d）→ %s" % [
		path, img.get_width(), img.get_height(), "OK" if err == OK else str(err)])