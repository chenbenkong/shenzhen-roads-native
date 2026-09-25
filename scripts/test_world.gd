## 世界渲染自检：构建出生点附近街区 → 截图到 res://tmp/ → 退出
## 用法：godot --path . res://scenes/test_world.tscn --resolution 1280x720
extends Node3D

var tiles: WorldTiles
var cam: Camera3D
var frame := 0
var spawn_x := 0.0
var spawn_z := 0.0


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	var data := CityData.load_from("res://data/city.bin", "res://data/city-meta.json")
	if data == null:
		printerr("数据加载失败")
		get_tree().quit(1)
		return
	print("[世界] 数据就绪 %d ms" % (Time.get_ticks_msec() - t0))

	var mats := WorldMaterials.create()
	var sky := SkyRig.new()
	sky.time_of_day = 0.40
	add_child(sky)

	tiles = WorldTiles.new()
	add_child(tiles)
	tiles.setup(data, mats)

	var spawn: Dictionary = data.meta["spawn"]
	spawn_x = spawn["x"]
	spawn_z = spawn["z"]

	var t1 := Time.get_ticks_msec()
	for i in 60:
		tiles.update(spawn_x, spawn_z, 400.0, 760.0)
		if i > 3 and tiles.stats["near_chunks"] >= 4:
			break
	var build_ms := Time.get_ticks_msec() - t1
	print("[世界] 构建完毕 %d ms → mesh %d / 三角 %d / 近景块 %d" % [
		build_ms, tiles.stats["meshes"], tiles.stats["triangles"], tiles.stats["near_chunks"]
	])

	cam = Camera3D.new()
	cam.fov = 62.0
	cam.near = 0.5
	cam.far = 9000.0
	add_child(cam)
	cam.position = Vector3(spawn_x + 120.0, 95.0, spawn_z + 130.0)
	cam.look_at(Vector3(spawn_x, 0.0, spawn_z), Vector3.UP)

	# 诊断：打印前几个 mesh 的包围盒与 surface 数（确认底铺写进去了）
	var shown := 0
	for child in tiles.get_children():
		for sub in child.get_children():
			if sub is MeshInstance3D:
				var mi := sub as MeshInstance3D
				var aabb := mi.mesh.get_aabb()
				print("[诊断] %s/%s aabb=%s 尺寸=%s surfaces=%d" % [
					child.name, mi.name, aabb.position, aabb.size, mi.mesh.get_surface_count()
				])
				shown += 1
				break
		if shown >= 3:
			break


func _process(_delta: float) -> void:
	frame += 1
	if frame == 8:
		_save("res://tmp/world_1_aerial.png")
	elif frame == 10:
		# 贴地看脚下（验证底铺）
		cam.position = Vector3(spawn_x, 1.7, spawn_z)
		cam.look_at(Vector3(spawn_x - 40.0, 8.0, spawn_z - 120.0), Vector3.UP)
	elif frame == 18:
		_save("res://tmp/world_2_street.png")
	elif frame == 20:
		# 沿路远眺（检查 LOD 与雾）
		cam.position = Vector3(spawn_x + 300.0, 120.0, spawn_z + 420.0)
		cam.look_at(Vector3(spawn_x, 0.0, spawn_z), Vector3.UP)
	elif frame == 28:
		_save("res://tmp/world_3_far.png")
	elif frame == 32:
		print("[世界] 结束")
		get_tree().quit(0)


func _save(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("[世界] 截图 %s → %s" % [path, "OK" if err == OK else str(err)])