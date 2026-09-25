## 程序化车身几何（零外部模型资源）：把 Web 版 cars.ts 的车身造型 1:1 搬到 Godot。
##
## 坐标系与缠绕（沿用 tiles.gd 那套约定）：
##  - Y 向上、右手系；模型朝 +z（车头朝 +z），节点绕 y 轴转一下就是车辆朝向
##  - 面法线 (B-A)×(C-A) 必须朝向观察者，否则会被背面剔除而「整片消失」
##    （本项目踩过坑：朝上的面写反会看不见）。为免手写缠绕出错，本文件的
##    quad/tri 都要传「期望外法线」，由构建器自动纠正顶点顺序：
##    竖直面外法线朝外、朝上的面（车顶 / 引擎盖顶）从上方看必须可见。
##
## 顶点属性：POSITION + NORMAL + COLOR（车身要顶点色，所以不能用只有 UV 的 GeoBuilder）。
##  - 主漆 / 下裙 / 车顶靠顶点色的明暗比例区分：主漆写纯白 1.0、下裙 0.706、车顶 0.863
##  - 实际颜色 = 材质 albedo_color × 顶点色 → 同一份几何可配任意车漆（AI 车流复用）
##
## 每类车三份几何：painted（车漆件）/ dark（玻璃·轮胎·底盘·格栅）/ lights（前后灯，自发光）。
## 玩家车另用 4 个独立车轮网格（可转向 / 滚动），AI 车流用合并的四轮（wheels_merged）。
class_name CarGeometry
extends RefCounted

# ---- 部位颜色（照搬 Web 版十六进制值）----
const DARK := Color8(0x14, 0x16, 0x1a)        # 底盘 / 格栅 / 警灯座
const GLASS := Color8(0x1b, 0x25, 0x30)       # 玻璃
const RIM := Color8(0x9a, 0xa3, 0xad)         # 轮毂
const LAMP_F := Color8(0xff, 0xf6, 0xdd)      # 前灯（暖白）
const LAMP_R := Color8(0xff, 0x3a, 0x22)      # 尾灯（红）
const LAMP_B := Color8(0x3a, 0x7b, 0xff)      # 警灯（蓝）
const TAXI_LAMP := Color8(0xff, 0xd3, 0x5a)   # 出租车顶灯

## 车漆明暗：车身 1.0 / 下裙 0.706 / 车顶 0.863 —— 低模的体积感全靠这三档
const PAINT_BODY := Color(1.0, 1.0, 1.0)
const PAINT_SKIRT := Color8(0xb4, 0xb4, 0xb4)
const PAINT_ROOF := Color8(0xdc, 0xdc, 0xdc)

## Node3D.rotation_order 的 RotationOrder 序号（XYZ,XZY,YXZ,YZX,ZXY,ZYX）
## 4.7 没有把这个枚举暴露成 GDScript 常量，只能写序号；Node3D 默认恰好就是 YXZ。
## 车轮必须「先绕 y 转向、再绕 x 滚动」，默认 XYZ 下这两个轴会互相干扰。
const ROTATION_ORDER_YXZ := 2


# ============================================================================
# 带顶点色的三角形构建器（车身专用，替代没有 COLOR 的 GeoBuilder）
# ============================================================================


class MeshBuilder:
	extends RefCounted

	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	func is_empty() -> bool:
		return indices.is_empty()

	func _push(p: Vector3, n: Vector3, c: Color) -> int:
		var vi := positions.size()
		positions.append(p)
		normals.append(n)
		colors.append(c)
		return vi

	## 四边形面。outward 是期望的外法线方向；若按 a→b→c→d 算出的法线与它反向，
	## 就把 b/d 互换（等价于整体反序），这样调用方只需保证四点是「绕面一圈」即可。
	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3, col: Color) -> void:
		var n := (b - a).cross(c - a)
		if n.dot(outward) < 0.0:
			var t := b
			b = d
			d = t
			n = -n
		n = n.normalized()
		var i0 := _push(a, n, col)
		var i1 := _push(b, n, col)
		var i2 := _push(c, n, col)
		var i3 := _push(d, n, col)
		indices.append(i0)
		indices.append(i1)
		indices.append(i2)
		indices.append(i0)
		indices.append(i2)
		indices.append(i3)

	## 三角形面（圆柱端盖用）。同样按 outward 自动纠正缠绕。
	func tri(a: Vector3, b: Vector3, c: Vector3, outward: Vector3, col: Color) -> void:
		var n := (b - a).cross(c - a)
		if n.dot(outward) < 0.0:
			var t := b
			b = c
			c = t
			n = -n
		n = n.normalized()
		var i0 := _push(a, n, col)
		var i1 := _push(b, n, col)
		var i2 := _push(c, n, col)
		indices.append(i0)
		indices.append(i1)
		indices.append(i2)

	## 可变形立方体（语义照搬 Web 版 box()）：
	##  w/h/d 是尺寸，x/y/z 是中心；taper 是顶部（+y 那 4 个顶点）横向收窄比例；
	##  slant 是顶部沿 z 的整体偏移（用来做风挡倾角）。每个面写各自的真法线，别用轴对齐的。
	func box(w: float, h: float, d: float, x: float, y: float, z: float,
			col: Color, taper: float = 0.0, slant: float = 0.0) -> void:
		var hw := w * 0.5
		var hh := h * 0.5
		var hd := d * 0.5
		var k := 1.0 - taper
		var o := Vector3(x, y, z)
		# 命名：m=后(-z)侧 / f=前(+z)侧 / l=左(-x)侧 / r=右(+x)侧
		var b_ml := Vector3(-hw, -hh, -hd) + o
		var b_mr := Vector3(hw, -hh, -hd) + o
		var b_fr := Vector3(hw, -hh, hd) + o
		var b_fl := Vector3(-hw, -hh, hd) + o
		# 顶部：先绕中心横向收窄，再沿 z 平移（与 Web 版先变形后 translate 等价）
		var t_ml := Vector3(-hw * k, hh, -hd * k + slant) + o
		var t_mr := Vector3(hw * k, hh, -hd * k + slant) + o
		var t_fr := Vector3(hw * k, hh, hd * k + slant) + o
		var t_fl := Vector3(-hw * k, hh, hd * k + slant) + o
		quad(t_ml, t_mr, t_fr, t_fl, Vector3(0, 1, 0), col)      # 顶面：从上方看要可见
		quad(b_ml, b_mr, b_fr, b_fl, Vector3(0, -1, 0), col)     # 底面
		quad(b_fl, b_fr, t_fr, t_fl, Vector3(0, 0, 1), col)      # +z 前脸
		quad(b_mr, b_ml, t_ml, t_mr, Vector3(0, 0, -1), col)     # -z 尾部
		quad(b_ml, b_fl, t_fl, t_ml, Vector3(-1, 0, 0), col)     # -x 左侧
		quad(b_fr, b_mr, t_mr, t_fr, Vector3(1, 0, 0), col)      # +x 右侧

	## 圆柱（轴向 +x）：轮胎 / 轮毂。等价于 Web 版 CylinderGeometry 绕 z 转 90°。
	func cylinder(radius: float, width: float, segments: int, col: Color) -> void:
		var hw := width * 0.5
		var ring := PackedVector3Array()
		for i in segments:
			var a := TAU * float(i) / float(segments)
			ring.append(Vector3(0.0, cos(a) * radius, sin(a) * radius))
		# 侧壁：一圈四边形，外法线取径向
		for i in segments:
			var p0 := ring[i]
			var p1 := ring[(i + 1) % segments]
			var out := Vector3(0.0, p0.y, p0.z).normalized()
			quad(Vector3(-hw, p0.y, p0.z), Vector3(-hw, p1.y, p1.z),
				Vector3(hw, p1.y, p1.z), Vector3(hw, p0.y, p0.z), out, col)
		# 两端盖：三角扇（半径 0 的退化情况这里不会出现）
		for i in segments:
			var p0 := ring[i]
			var p1 := ring[(i + 1) % segments]
			tri(Vector3(hw, 0.0, 0.0), Vector3(hw, p0.y, p0.z), Vector3(hw, p1.y, p1.z),
				Vector3(1, 0, 0), col)
			tri(Vector3(-hw, 0.0, 0.0), Vector3(-hw, p0.y, p0.z), Vector3(-hw, p1.y, p1.z),
				Vector3(-1, 0, 0), col)

	## 把另一份几何整体平移后并进自己（四轮合并成一份 mesh 用）
	func merge_translated(other: MeshBuilder, offset: Vector3) -> void:
		var base := positions.size()
		for p in other.positions:
			positions.append(p + offset)
		normals.append_array(other.normals)
		colors.append_array(other.colors)
		for i in other.indices:
			indices.append(base + i)

	## 产出 ArrayMesh（可选挂材质；无索引时返回空 mesh，不报错）
	func to_mesh(mat: Material = null) -> ArrayMesh:
		var mesh := ArrayMesh.new()
		if indices.is_empty():
			return mesh
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays())
		if mat != null:
			mesh.surface_set_material(0, mat)
		return mesh

	func _arrays() -> Array:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = positions
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_INDEX] = indices
		return arrays


# ============================================================================
# 外观资源
# ============================================================================


## 一个载具的外观资源（几何 + 尺寸信息）
class CarGeo:
	extends RefCounted
	## 车漆件（顶点色区分主漆 / 下裙 / 车顶）
	var painted: ArrayMesh
	## 玻璃 / 轮胎 / 底盘 / 格栅
	var dark: ArrayMesh
	## 前后灯（自发光）
	var lights: ArrayMesh
	## 四个轮子合并（AI 车流用）
	var wheels_merged: ArrayMesh
	## 单个轮子（玩家车用，需能转向 / 滚动）
	var wheel: ArrayMesh
	var wheel_radius := 0.32
	var wheel_half_track := 0.78
	var front_z := 1.35
	var rear_z := -1.35


# ============================================================================
# 对外接口
# ============================================================================

static var _geo_cache := {}
static var _mat_cache := {}
static var _traffic_cache := {}


## 取得（并缓存）某车型的外观资源：同一 spec 只构建一次
static func of(spec: CarSpecs.Spec) -> CarGeo:
	if _geo_cache.has(spec.id):
		return _geo_cache[spec.id]

	var mats := materials()
	var paint_mat: Material = mats["paint"]
	var dark_mat: Material = mats["dark"]
	var lights_mat: Material = mats["lights"]
	var painted := MeshBuilder.new()
	var dark := MeshBuilder.new()
	var lights := MeshBuilder.new()
	_body_parts(spec, painted, dark, lights)
	var g := CarGeo.new()
	g.painted = painted.to_mesh(paint_mat)
	g.dark = dark.to_mesh(dark_mat)
	g.lights = lights.to_mesh(lights_mat)

	var radius := wheel_radius_of(spec)
	var wheel_width := 0.3 if spec.is_big() else 0.24
	var wb := _wheel_builder(radius, wheel_width)
	g.wheel = wb.to_mesh(dark_mat)
	g.wheel_radius = radius
	g.wheel_half_track = spec.width * 0.5 - wheel_width * 0.5 - 0.02
	g.front_z = spec.wheelbase * 0.5
	g.rear_z = -spec.wheelbase * 0.5

	# 四轮合并：顺序固定为 [左前, 右前, 左后, 右后]，与 create_visual 的车轮命名一致
	var merged := MeshBuilder.new()
	for p in [
		Vector3(-g.wheel_half_track, radius, g.front_z),
		Vector3(g.wheel_half_track, radius, g.front_z),
		Vector3(-g.wheel_half_track, radius, g.rear_z),
		Vector3(g.wheel_half_track, radius, g.rear_z),
	]:
		merged.merge_translated(wb, p)
	g.wheels_merged = merged.to_mesh(dark_mat)

	_geo_cache[spec.id] = g
	return g


## {paint, dark, lights} 三个共享材质（所有载具共用，减少状态切换）
static func materials() -> Dictionary:
	if _mat_cache.is_empty():
		var paint := StandardMaterial3D.new()
		paint.vertex_color_use_as_albedo = true
		paint.roughness = 0.45
		paint.metallic = 0.15

		var dark := StandardMaterial3D.new()
		dark.vertex_color_use_as_albedo = true
		dark.roughness = 0.6  # 玻璃略低于轮胎（Web 版靠 Phong 高光，这里靠粗糙度）
		dark.metallic = 0.2

		var lights := StandardMaterial3D.new()
		lights.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		lights.vertex_color_use_as_albedo = true

		_mat_cache = {"paint": paint, "dark": dark, "lights": lights}
	return _mat_cache


## AI 车流用：painted + dark + lights 合并成单个 mesh（多 surface）
static func traffic_mesh(spec: CarSpecs.Spec) -> ArrayMesh:
	if _traffic_cache.has(spec.id):
		return _traffic_cache[spec.id]
	var g := of(spec)
	var mats := materials()
	var paint_mat: Material = mats["paint"]
	var dark_mat: Material = mats["dark"]
	var lights_mat: Material = mats["lights"]
	var mesh := ArrayMesh.new()
	_append_surface(mesh, g.painted, paint_mat, 0)
	_append_surface(mesh, g.dark, dark_mat, 0)
	_append_surface(mesh, g.lights, lights_mat, 0)
	_traffic_cache[spec.id] = mesh
	return mesh


## 玩家车漆材质：albedo 用规格里的车身色，再乘顶点色
static func player_paint(color: Color) -> Material:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.albedo_color = color
	m.roughness = 0.45
	m.metallic = 0.15
	return m


## 玩家车外观：Node3D 车身容器（含 painted / dark / lights）+ 4 个轮子子节点
## 车身模型朝 +z；轮子位置由 wheel_half_track / wheel_radius / front_z / rear_z 决定
static func create_visual(spec: CarSpecs.Spec, mats: Dictionary = {}) -> Node3D:
	var m := mats if not mats.is_empty() else materials()
	var dark_mat: Material = m["dark"]
	var lights_mat: Material = m["lights"]
	var g := of(spec)
	var root := Node3D.new()
	root.name = "car_" + spec.id

	root.add_child(_mesh_instance("painted", g.painted, player_paint(spec.body_color)))
	root.add_child(_mesh_instance("dark", g.dark, dark_mat))
	root.add_child(_mesh_instance("lights", g.lights, lights_mat))

	for i in 4:
		var w := _mesh_instance("wheel%d" % i, g.wheel, dark_mat)
		# 先绕 y 转向、再绕 x 滚动 —— 默认 XYZ 顺序下这两个轴会互相干扰
		w.rotation_order = ROTATION_ORDER_YXZ
		w.position = Vector3(
			-g.wheel_half_track if i % 2 == 0 else g.wheel_half_track,
			g.wheel_radius,
			g.front_z if i < 2 else g.rear_z
		)
		root.add_child(w)
	return root


## 车轮半径（与 spec.height / kind 相关，照搬 Web 版公式）
static func wheel_radius_of(spec: CarSpecs.Spec) -> float:
	match spec.kind:
		"bus":
			return 0.53
		"truck":
			return 0.56
		"van":
			return 0.38
		"suv":
			return 0.4
		"sports":
			return 0.34
	return 0.33


# ============================================================================
# 车身拼装（逐条对应 Web 版 bodyParts）
# ============================================================================


## 按车型把三份几何写进调用方给的构建器（避免返回无类型字典，Variant 会触发警告）
static func _body_parts(spec: CarSpecs.Spec, painted: MeshBuilder, dark: MeshBuilder, lights: MeshBuilder) -> void:
	var L := spec.length
	var W := spec.width
	var H := spec.height
	var axle_y := wheel_radius_of(spec)
	var is_big := spec.is_big()
	var cabin_h := H * spec.cabin_ratio
	var chassis_h := 0.34 if is_big else 0.16

	if is_big:
		# 大车：一个方箱 + 窗带 + 前风挡
		var body_y0 := axle_y * 0.6
		var body_h := H - body_y0 - 0.1
		var midship := L * 0.34 if spec.kind == "bus" else L * 0.18
		painted.box(W, body_h, L, 0.0, body_y0 + body_h * 0.5, 0.0, PAINT_BODY, 0.04)
		# 窗带（左右贯通的一条亮带）
		var win_h := minf(0.95, H * 0.3)
		var win_y := body_y0 + body_h - win_h * 0.75
		var win_len := L * 0.86 if spec.kind == "bus" else L * 0.4
		var win_z := -L * 0.04 if spec.kind == "bus" else midship
		painted.box(W + 0.04, win_h, win_len, 0.0, win_y, win_z, PAINT_ROOF)
		dark.box(W + 0.06, win_h * 0.82, win_len * 0.98, 0.0, win_y, win_z, GLASS)
		dark.box(W * 0.92, win_h * 1.05, 0.1, 0.0, win_y + 0.05, L * 0.5 - 0.06, GLASS)
		# 前灯 / 尾灯
		lights.box(0.34, 0.22, 0.08, W * 0.5 - 0.34, axle_y + 0.5, L * 0.5 - 0.02, LAMP_F)
		lights.box(0.34, 0.22, 0.08, -W * 0.5 + 0.34, axle_y + 0.5, L * 0.5 - 0.02, LAMP_F)
		lights.box(0.3, 0.3, 0.08, W * 0.5 - 0.32, axle_y + 0.55, -L * 0.5 + 0.02, LAMP_R)
		lights.box(0.3, 0.3, 0.08, -W * 0.5 + 0.32, axle_y + 0.55, -L * 0.5 + 0.02, LAMP_R)
		dark.box(W * 0.98, 0.5, L * 0.96, 0.0, chassis_h * 0.5 + 0.08, 0.0, DARK)
	else:
		# 小车：主车身 + 下裙 + 车厢（带倾角）+ 侧窗 / 前后风挡 + 格栅 + 底盘
		var body_bottom := axle_y - 0.1
		var body_top := body_bottom + (H - cabin_h) * 0.86
		painted.box(W, body_top - body_bottom, L, 0.0, (body_top + body_bottom) * 0.5, 0.0,
			PAINT_BODY, 0.06 if spec.kind == "sports" else 0.03)
		# 下裙（略宽、暗一档）
		painted.box(W * 1.01, body_bottom - chassis_h, L * 0.9, 0.0,
			(body_bottom + chassis_h) * 0.5, 0.0, PAINT_SKIRT)
		# 车厢位置随车型前后移动（跑车座舱靠后、面包车靠前）
		var cabin_len := L * 0.44
		var cabin_z := -L * 0.05
		match spec.kind:
			"sports":
				cabin_len = L * 0.34
				cabin_z = -L * 0.06
			"van":
				cabin_len = L * 0.6
				cabin_z = -L * 0.04
		var roof_y := body_top + cabin_h
		painted.box(W * 0.95, cabin_h, cabin_len, 0.0, (body_top + roof_y) * 0.5, cabin_z,
			PAINT_ROOF, 0.1, 0.06)
		# 侧窗
		dark.box(W * 0.96, cabin_h * 0.66, cabin_len * 0.9, 0.0, body_top + cabin_h * 0.42,
			cabin_z, GLASS, 0.1, 0.06)
		# 前风挡 / 后风挡（薄片，倾斜）
		dark.box(W * 0.82, cabin_h * 0.72, 0.08, 0.0, body_top + cabin_h * 0.44,
			cabin_z + cabin_len * 0.5 - 0.02, GLASS, 0.0, 0.14)
		dark.box(W * 0.82, cabin_h * 0.66, 0.08, 0.0, body_top + cabin_h * 0.42,
			cabin_z - cabin_len * 0.5 + 0.02, GLASS, 0.0, -0.12)
		# 格栅 + 底盘
		dark.box(W * 0.7, 0.2, 0.08, 0.0, body_top - 0.24, L * 0.5 - 0.02, DARK)
		dark.box(W * 0.94, chassis_h * 1.6, L * 0.86, 0.0, chassis_h * 0.6, 0.0, DARK)
		# 四灯
		var lamp_y := body_top - 0.16
		lights.box(0.4, 0.16, 0.08, W * 0.5 - 0.34, lamp_y, L * 0.5 - 0.01, LAMP_F)
		lights.box(0.4, 0.16, 0.08, -W * 0.5 + 0.34, lamp_y, L * 0.5 - 0.01, LAMP_F)
		lights.box(0.36, 0.18, 0.08, W * 0.5 - 0.3, lamp_y + 0.02, -L * 0.5 + 0.01, LAMP_R)
		lights.box(0.36, 0.18, 0.08, -W * 0.5 + 0.3, lamp_y + 0.02, -L * 0.5 + 0.01, LAMP_R)

	# 车型装饰：这几个是车辆辨识度的关键，别省
	match spec.kind:
		"taxi":
			painted.box(0.7, 0.22, 0.34, 0.0, H + 0.05, -L * 0.05, PAINT_BODY)
			lights.box(0.6, 0.14, 0.03, 0.0, H + 0.06, -L * 0.05 + 0.18, TAXI_LAMP)
		"police":
			dark.box(W * 0.62, 0.14, 0.3, 0.0, H + 0.02, -L * 0.05, DARK)
			lights.box(W * 0.28, 0.1, 0.26, -W * 0.15, H + 0.06, -L * 0.05, LAMP_R)
			lights.box(W * 0.28, 0.1, 0.26, W * 0.15, H + 0.06, -L * 0.05, LAMP_B)
		"sports":
			painted.box(W * 0.86, 0.06, 0.3, 0.0, H * 0.86, -L * 0.5 + 0.12, PAINT_SKIRT)


## 车轮 = 轮胎（12 边）+ 轮毂（10 边，略宽一点好露出侧面）
static func _wheel_builder(radius: float, width: float) -> MeshBuilder:
	var b := MeshBuilder.new()
	b.cylinder(radius, width, 12, Color(0.075, 0.078, 0.085))
	b.cylinder(radius * 0.62, width * 1.06, 10, RIM)
	return b


# ============================================================================
# 小工具
# ============================================================================


static func _mesh_instance(nm: String, mesh: ArrayMesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = mesh
	mi.material_override = mat
	# 核显上不值得为车身投影，全部关掉
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func _append_surface(dst: ArrayMesh, src: ArrayMesh, mat: Material, surf: int) -> void:
	if src == null or src.get_surface_count() <= surf:
		return
	var idx := dst.get_surface_count()
	dst.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, src.surface_get_arrays(surf))
	if mat != null:
		dst.surface_set_material(idx, mat)