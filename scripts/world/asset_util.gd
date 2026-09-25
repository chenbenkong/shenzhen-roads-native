## 原项目自建资产的取用工具
##
## models/ 下的 *_plain.glb / ped_*.glb 都是「单一 primitive + float 属性 + 顶点色」结构，
## 由 tools/prepare-assets.mjs 从原版多部件 glb 拆出来（Godot 的导入器读不了 meshopt 压缩）。
## 这里负责把 PackedScene 里的 ArrayMesh 取出来并缓存，供 MultiMesh 与普通节点复用。
class_name AssetUtil
extends RefCounted

static var _cache := {}


## 取资产里的第一个网格（不存在则返回 null 并报错）
static func mesh_of(path: String) -> Mesh:
	if _cache.has(path):
		return _cache[path]
	if not ResourceLoader.exists(path):
		push_error("资产缺失：%s（先跑 tools/prepare-assets.mjs 并 --import）" % path)
		return null
	var scene := load(path)
	if scene == null:
		push_error("资产加载失败：%s" % path)
		return null
	var node: Node = scene.instantiate()
	var mesh := _find(node)
	node.free()
	_cache[path] = mesh
	return mesh


static func _find(n: Node) -> Mesh:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			return mi.mesh
	for c in n.get_children():
		var m := _find(c)
		if m != null:
			return m
	return null


## 顶点色材质（instance color 会与顶点色相乘，因此可整体调色）
static func vertex_color_material(roughness := 0.75, metallic := 0.05) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = roughness
	mat.metallic = metallic
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	return mat


## 建一个 MultiMeshInstance3D（返回 [节点, MultiMesh]，方便调用方写实例）
static func make_multimesh(name: String, mesh: Mesh, count: int, mat: Material) -> Array:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = count
	var mmi := MultiMeshInstance3D.new()
	mmi.name = name
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return [mmi, mm]


## 把一个实例「藏起来」（缩到极小并挪到场景外）
static func hide_instance(mm: MultiMesh, index: int) -> void:
	mm.set_instance_transform(
		index,
		Transform3D(Basis().scaled(Vector3(0.0001, 0.0001, 0.0001)), Vector3(0.0, -800.0, 0.0))
	)