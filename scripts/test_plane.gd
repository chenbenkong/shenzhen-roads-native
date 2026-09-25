## 自检：原版自建 glb 资产（飞机 / 行人 / 交通车 / 自行车 / 棕榈）能否在 Godot 里正常实例化渲染
## 用法：godot --path . res://scenes/test_plane.tscn --resolution 1280x720
extends Node3D

const ASSETS := [
	["res://models/floatplane_flat.glb", Vector3(-8, 1.4, 0)],
	["res://models/traffic-car.glb", Vector3(0, 0.2, 0)],
	["res://models/pedestrian.glb", Vector3(6, 0.1, 0)],
	["res://models/bicycle.glb", Vector3(10, 0.1, 0)],
	["res://models/palm.glb", Vector3(15, 0.1, 0)],
]

var cam: Camera3D
var frame := 0


func _ready() -> void:
	var sky := SkyRig.new()
	sky.time_of_day = 0.40
	add_child(sky)

	# 地面
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(80, 40)
	var floor_inst := MeshInstance3D.new()
	floor_inst.mesh = floor_mesh
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.32, 0.34, 0.36)
	floor_inst.material_override = fm
	add_child(floor_inst)

	for entry in ASSETS:
		var path: String = entry[0]
		var pos: Vector3 = entry[1]
		if not ResourceLoader.exists(path):
			print("[资产] 缺失 %s" % path)
			continue
		var scene := load(path)
		if scene == null:
			print("[资产] 加载失败 %s" % path)
			continue
		var node: Node3D = scene.instantiate()
		node.position = pos
		add_child(node)
		var meshes := 0
		var tris := 0
		var names: Array = []
		_collect(node, names, func(n: MeshInstance3D) -> void:
			meshes += 1
			if n.mesh != null:
				for s in n.mesh.get_surface_count():
					tris += n.mesh.surface_get_array_index_len(s) / 3
		)
		print("[资产] %s → 网格 %d 三角 %d 顶层子节点 %d" % [path.get_file(), meshes, tris, node.get_child_count()])
		if path.ends_with("floatplane.glb"):
			print("       节点名：%s" % ", ".join(names.slice(0, 14)))

	cam = Camera3D.new()
	cam.fov = 55.0
	cam.far = 9000.0
	add_child(cam)
	cam.position = Vector3(4, 7, 22)
	cam.look_at(Vector3(3, 1.6, 0), Vector3.UP)


func _collect(node: Node, out_names: Array, fn: Callable) -> void:
	if node is MeshInstance3D:
		out_names.append(node.name)
		fn.call(node)
	for child in node.get_children():
		_collect(child, out_names, fn)


func _process(_delta: float) -> void:
	frame += 1
	if frame == 8:
		var img := get_viewport().get_texture().get_image()
		print("[资产] 截图 → %s" % ("OK" if img.save_png("res://tmp/assets_overview.png") == OK else "失败"))
	elif frame == 14:
		get_tree().quit(0)