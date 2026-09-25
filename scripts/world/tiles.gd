## 静态世界分块（640m 一块）：建筑 / 道路 / 地面 / 行道树
##
## 与 Web 版 tiles.ts 同一套约定：
##  - 每块近景 1 个 MeshInstance3D（内含 city / cut / glow 三个 surface）
##  - 远景用简化盒体（LOD1）代替，距离超过 lod_distance 才切
##  - 缠绕：水平朝上的面取「x,z 平面负环绕」；竖直墙面按外法线取向
##  - 桥面由 road_graph 的逐顶点高程表驱动（沥青 / 人行道 / 标线 / 街灯一起抬升）
class_name WorldTiles
extends Node3D

const _RING_SCRATCH: Array = []

class Chunk:
	var key: int
	var cx: int
	var cz: int
	var center_x: float
	var center_z: float
	var root: Node3D
	var near_mesh: MeshInstance3D
	var far_mesh: MeshInstance3D
	var near_built := false
	var far_built := false
	var queued_near := false
	var queued_far := false


var stats := {"meshes": 0, "triangles": 0, "near_chunks": 0}

var _data: CityData
var _mats: WorldMaterials
var _chunks := {}
var _near_queue: Array = []
var _far_queue: Array = []
var _rings: Array = []


func setup(data: CityData, mats: WorldMaterials) -> void:
	_data = data
	_mats = mats
	name = "world"

# ============================================================================
# 主循环：按加载半径建块，按帧预算排队构建
# ============================================================================


func update(px: float, pz: float, budget_ms: float, lod_distance: float) -> void:
	var radius := C.LOAD_RADIUS
	var keep := radius * 1.15
	var cx0 := floori((px - radius) / C.CHUNK_SIZE)
	var cx1 := floori((px + radius) / C.CHUNK_SIZE)
	var cz0 := floori((pz - radius) / C.CHUNK_SIZE)
	var cz1 := floori((pz + radius) / C.CHUNK_SIZE)
	for cx in range(cx0, cx1 + 1):
		for cz in range(cz0, cz1 + 1):
			var center_x := (cx + 0.5) * C.CHUNK_SIZE
			var center_z := (cz + 0.5) * C.CHUNK_SIZE
			var d := sqrt((center_x - px) * (center_x - px) + (center_z - pz) * (center_z - pz))
			if d > radius:
				continue
			var key := _data.chunk_key_2(cx, cz)
			if not _chunks.has(key):
				_chunks[key] = _create_chunk(key, cx, cz)
			var chunk: Chunk = _chunks[key]
			if not chunk.far_built and not chunk.queued_far:
				chunk.queued_far = true
				_far_queue.append(key)
			if not chunk.near_built and not chunk.queued_near and d < lod_distance + C.CHUNK_SIZE:
				chunk.queued_near = true
				_near_queue.append(key)

	# 卸载跑远的块
	var drop: Array = []
	for key in _chunks:
		var chunk: Chunk = _chunks[key]
		var dx := chunk.center_x - px
		var dz := chunk.center_z - pz
		if sqrt(dx * dx + dz * dz) > keep:
			_dispose_chunk(chunk)
			drop.append(key)
	for key in drop:
		_chunks.erase(key)

	var t0 := Time.get_ticks_usec()
	_sort_queue(_near_queue, px, pz)
	_sort_queue(_far_queue, px, pz)
	while not _near_queue.is_empty() and (Time.get_ticks_usec() - t0) / 1000.0 < budget_ms:
		var key: int = _near_queue.pop_front()
		var chunk: Chunk = _chunks.get(key)
		if chunk == null or chunk.near_built:
			continue
		_build_near(chunk)
	while not _far_queue.is_empty() and (Time.get_ticks_usec() - t0) / 1000.0 < budget_ms * 2.0:
		var key: int = _far_queue.pop_front()
		var chunk: Chunk = _chunks.get(key)
		if chunk == null or chunk.far_built:
			continue
		_build_far(chunk)

	# LOD 切换与统计
	var meshes := 0
	var tris := 0
	var near_count := 0
	for key in _chunks:
		var chunk: Chunk = _chunks[key]
		var dx := chunk.center_x - px
		var dz := chunk.center_z - pz
		var d := sqrt(dx * dx + dz * dz)
		var use_far := d > lod_distance or not chunk.near_built
		if chunk.far_mesh != null:
			chunk.far_mesh.visible = use_far and chunk.far_built
		if chunk.near_mesh != null:
			chunk.near_mesh.visible = (not use_far) and chunk.near_built
		# 显式判空：三元表达式会先求值条件，块尚未构建时 near_mesh 为 null
		var holder: MeshInstance3D = null
		if chunk.near_mesh != null and chunk.near_mesh.visible:
			holder = chunk.near_mesh
		elif chunk.far_mesh != null and chunk.far_mesh.visible:
			holder = chunk.far_mesh
		if holder != null:
			if holder == chunk.near_mesh:
				near_count += 1
			meshes += holder.mesh.get_surface_count()
			for s in holder.mesh.get_surface_count():
				tris += holder.mesh.surface_get_array_index_len(s) / 3
	stats["meshes"] = meshes
	stats["triangles"] = tris
	stats["near_chunks"] = near_count


func _sort_queue(queue: Array, px: float, pz: float) -> void:
	if queue.size() < 2:
		return
	var coords := {}
	var items: Array = []
	for key in queue:
		_data.chunk_key_coords(key, coords)
		var cx: float = coords["cx"]
		var cz: float = coords["cz"]
		var dx := (cx + 0.5) * C.CHUNK_SIZE - px
		var dz := (cz + 0.5) * C.CHUNK_SIZE - pz
		items.append([dx * dx + dz * dz, key])
	items.sort_custom(func(a, b): return a[0] < b[0])
	queue.clear()
	for it in items:
		queue.append(it[1])


func _create_chunk(key: int, cx: int, cz: int) -> Chunk:
	var c := Chunk.new()
	c.key = key
	c.cx = cx
	c.cz = cz
	c.center_x = (cx + 0.5) * C.CHUNK_SIZE
	c.center_z = (cz + 0.5) * C.CHUNK_SIZE
	c.root = Node3D.new()
	c.root.name = "chunk_%d_%d" % [cx, cz]
	add_child(c.root)
	return c


func _dispose_chunk(chunk: Chunk) -> void:
	if chunk.near_mesh != null:
		chunk.near_mesh.queue_free()
		chunk.near_mesh = null
	if chunk.far_mesh != null:
		chunk.far_mesh.queue_free()
		chunk.far_mesh = null
	chunk.root.queue_free()

# ============================================================================
# 近景：完整几何
# ============================================================================


func _build_near(chunk: Chunk) -> void:
	chunk.near_built = true
	chunk.queued_near = false
	var data := _data
	var city := GeoBuilder.new()
	var cut := GeoBuilder.new()
	var glow := GeoBuilder.new()

	# 基础陆地底铺：数据里只有绿地/水体/道路轮廓，没有「整片陆地」，
	# 缺了它建筑与道路会悬在背景色上。每块铺 640×640 一张草绿底（水面数据在其上方 0.05m 处覆盖）
	push_ground_base(city, chunk.cx, chunk.cz, C.L.GRASS)

	# 地面（路面铺装 / 草地 / 水面；水面三角进 city，与 Web 版一致用同一材质）
	for p in data.ground_in_chunk(chunk.key):
		var layer := data.ground_layer(p)
		var is_water := layer == 2
		var tex_layer := C.L.WATER if is_water else (C.L.GRASS if layer == 1 else C.L.PAVEMENT)
		var tile: float = C.LAYER_TILE[tex_layer]
		var y := C.Y_WATER if is_water else (C.Y_GRASS if layer == 1 else C.Y_LAND)
		var tc := data.ground_tri_count(p)
		for t in tc:
			var tri := data.poly_triangle(p, t)
			var a := city.push(tri[0], y, tri[1], tri[0] / tile, tri[1] / tile, tex_layer, 0.0, 0.0, 1.0)
			var b := city.push(tri[2], y, tri[3], tri[2] / tile, tri[3] / tile, tex_layer, 0.0, 0.0, 1.0)
			var c := city.push(tri[4], y, tri[5], tri[4] / tile, tri[5] / tile, tex_layer, 0.0, 0.0, 1.0)
			# 数据里的三角形环绕方向不保证朝上，按 (B-A)×(C-A) 的 y 分量就地纠正
			if face_up_y(tri[0], tri[1], tri[2], tri[3], tri[4], tri[5]) > 0.0:
				city.tri(a, b, c)
			else:
				city.tri(a, c, b)

	# 道路（含桥面 / 护栏 / 桥墩 / 标线 / 街灯）
	var roads := data.road_segments_in_chunk(chunk.key)
	for road in roads:
		_build_road(city, cut, glow, int(road), roads[road])
	# 建筑
	for bi in data.buildings_in_chunk(chunk.key):
		_build_building(city, cut, int(bi))
	# 行道树
	for road in roads:
		_build_trees(city, cut, int(road), roads[road])

	var mesh := ArrayMesh.new()
	city.add_to(mesh, _mats.city)
	cut.add_to(mesh, _mats.cut)
	glow.add_to(mesh, _mats.glow)
	if mesh.get_surface_count() == 0:
		return
	var mi := MeshInstance3D.new()
	mi.name = "near"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	chunk.root.add_child(mi)
	chunk.near_mesh = mi


## 远景 LOD1：只留建筑盒体
func _build_far(chunk: Chunk) -> void:
	chunk.far_built = true
	chunk.queued_far = false
	var data := _data
	var b := GeoBuilder.new()
	push_ground_base(b, chunk.cx, chunk.cz, C.L.GRASS)
	for bi in data.buildings_in_chunk(chunk.key):
		var i := int(bi)
		var x0 := data.b_min_x[i]
		var x1 := data.b_max_x[i]
		var z0 := data.b_min_z[i]
		var z1 := data.b_max_z[i]
		if x1 - x0 < 0.4 or z1 - z0 < 0.4:
			continue
		var top := C.Y_LAND + data.b_height[i]
		add_box(b, x0, z0, x1, z1, C.Y_LAND, top, data.b_facade_layer[i], 8.0, false, 0.0)
	if b.is_empty():
		return
	var mesh := ArrayMesh.new()
	b.add_to(mesh, _mats.city)
	var mi := MeshInstance3D.new()
	mi.name = "far"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	chunk.root.add_child(mi)
	chunk.far_mesh = mi

# ============================================================================
# 建筑
# ============================================================================


func _build_building(city: GeoBuilder, cut: GeoBuilder, index: int) -> void:
	var data := _data
	_rings.clear()
	var rc := data.read_rings(index, _rings)
	if rc == 0:
		return
	var outer: PackedFloat32Array = _rings[0]
	var n := outer.size() / 2
	if n < 3:
		return
	# 外环统一成逆时针（面积正），否则墙面法线会朝里
	var area := 0.0
	for i in n:
		var j := (i + 1) % n
		area += outer[i * 2] * outer[j * 2 + 1] - outer[j * 2] * outer[i * 2 + 1]
	if area < 0.0:
		var fixed := PackedFloat32Array()
		fixed.resize(outer.size())
		for i in n:
			var j := n - 1 - i
			fixed[i * 2] = outer[j * 2]
			fixed[i * 2 + 1] = outer[j * 2 + 1]
		outer = fixed
		_rings[0] = fixed

	var height := data.b_height[index]
	var base := C.Y_LAND
	var facade := data.b_facade_layer[index]
	var roof_layer := data.b_roof_layer[index]
	var tile: float = C.LAYER_TILE[facade]

	for r in rc:
		var ring: PackedFloat32Array = _rings[r]
		var rn := ring.size() / 2
		if rn < 3:
			continue
		var hole := r > 0
		var arc := 0.0
		for i in rn:
			var j := (i + 1) % rn
			var ax := ring[i * 2]
			var az := ring[i * 2 + 1]
			var bx := ring[j * 2]
			var bz := ring[j * 2 + 1]
			var dx := bx - ax
			var dz := bz - az
			var l := sqrt(dx * dx + dz * dz)
			if l < 0.05:
				continue
			var nx := dz / l
			var nz := -dx / l
			if hole:
				nx = -nx
				nz = -nz
			var u0 := arc / tile
			var u1 := (arc + l) / tile
			var v1 := height / tile
			var a := city.push(ax, base, az, u0, 0.0, facade, nx, nz, 0.0)
			var b := city.push(bx, base, bz, u1, 0.0, facade, nx, nz, 0.0)
			var c := city.push(bx, base + height, bz, u1, v1, facade, nx, nz, 0.0)
			var d := city.push(ax, base + height, az, u0, v1, facade, nx, nz, 0.0)
			if hole:
				city.quad(a, b, c, d)
			else:
				city.quad(d, c, b, a)
			arc += l

	# 屋顶：Godot 内置三角化（洞略过不挖，视觉影响可忽略）
	var flat := PackedVector2Array()
	for i in n:
		flat.append(Vector2(outer[i * 2], outer[i * 2 + 1]))
	var idx := Geometry2D.triangulate_polygon(flat)
	var roof_y := base + height
	var roof_tile: float = C.LAYER_TILE[roof_layer]
	if idx.size() >= 3:
		var start := city.size()
		for i in n:
			city.push(outer[i * 2], roof_y, outer[i * 2 + 1], outer[i * 2] / roof_tile, outer[i * 2 + 1] / roof_tile, roof_layer, 0.0, 0.0, 1.0)
		var k := 0
		while k + 2 < idx.size():
			var ia := idx[k]
			var ib := idx[k + 1]
			var ic := idx[k + 2]
			var fa := flat[ia]
			var fb := flat[ib]
			var fc := flat[ic]
			if face_up_y(fa.x, fa.y, fb.x, fb.y, fc.x, fc.y) > 0.0:
				city.tri(start + ia, start + ib, start + ic)
			else:
				city.tri(start + ia, start + ic, start + ib)
			k += 3

	# 女儿墙
	if height > 11.0:
		var ph := 0.8
		var arc2 := 0.0
		for i in n:
			var j := (i + 1) % n
			var ax := outer[i * 2]
			var az := outer[i * 2 + 1]
			var bx := outer[j * 2]
			var bz := outer[j * 2 + 1]
			var dx := bx - ax
			var dz := bz - az
			var l := sqrt(dx * dx + dz * dz)
			if l < 0.05:
				continue
			var nx := dz / l
			var nz := -dx / l
			var a := city.push(ax, roof_y, az, arc2 / tile, 0.0, facade, nx, nz, 0.0)
			var b := city.push(bx, roof_y, bz, (arc2 + l) / tile, 0.0, facade, nx, nz, 0.0)
			var c := city.push(bx, roof_y + ph, bz, (arc2 + l) / tile, ph / tile, facade, nx, nz, 0.0)
			var d := city.push(ax, roof_y + ph, az, arc2 / tile, ph / tile, facade, nx, nz, 0.0)
			city.quad(d, c, b, a)
			arc2 += l

	# 屋顶设备 / 天线
	var seed_v := data.b_seed[index]
	var r0 := GeoBuilder.rand01(seed_v, index, 11)
	var w := data.b_max_x[index] - data.b_min_x[index]
	var h := data.b_max_z[index] - data.b_min_z[index]
	if height > 22.0 and r0 < 0.55 and w > 9.0 and h > 9.0:
		var bw := 3.0 + r0 * 7.0
		var ox := (GeoBuilder.rand01(seed_v, index, 12) - 0.5) * w * 0.4
		var oz := (GeoBuilder.rand01(seed_v, index, 13) - 0.5) * h * 0.4
		var rot := GeoBuilder.rand01(seed_v, index, 14) * PI
		add_box(
			city,
			data.b_cx[index] + ox - bw / 2.0, data.b_cz[index] + oz - bw / 2.0,
			data.b_cx[index] + ox + bw / 2.0, data.b_cz[index] + oz + bw / 2.0,
			roof_y, roof_y + 2.4, roof_layer, roof_tile, false, rot
		)
	if height > 65.0 and GeoBuilder.rand01(seed_v, index, 15) < 0.45:
		add_cross(cut, data.b_cx[index], data.b_cz[index], roof_y, roof_y + 4.0 + float(seed_v % 7), 0.18, C.L.FACADE_CONCRETE)

# ============================================================================
# 道路（含桥面）
# ============================================================================


func _build_road(city: GeoBuilder, cut: GeoBuilder, glow: GeoBuilder, road: int, segs: PackedInt32Array) -> void:
	var data := _data
	var count := data.road_vert_count(road)
	if count < 2:
		return
	var pts := PackedFloat32Array()
	pts.resize(count * 2)
	for i in count:
		var p := data.road_point(road, i)
		pts[i * 2] = p.x
		pts[i * 2 + 1] = p.y
	var kind := data.r_kind[road]
	var width := data.r_width[road]
	var half := width * 0.5
	var asphalt_tile: float = C.LAYER_TILE[C.L.ASPHALT]
	var pave_tile: float = C.LAYER_TILE[C.L.PAVEMENT]
	var curbs := kind >= 2
	var markings := kind >= 3
	# 桥面高程表：只有含桥道路才有，且长度必须覆盖本道路全部顶点（否则视为无桥）
	var elev_v = data.graph.road_elev_of(road)
	var elev: PackedFloat32Array = elev_v if (elev_v is PackedFloat32Array and elev_v.size() >= count) else PackedFloat32Array()
	var has_elev := elev.size() >= count
	var dy_side := C.Y_SIDEWALK - C.Y_ROAD
	var dy_mark := C.Y_MARKING - C.Y_ROAD
	var last_pier := -1000000.0

	# 逐顶点法线（沿折线方向取右法线）与弧长
	var nx0 := PackedFloat32Array()
	var nz0 := PackedFloat32Array()
	var arcs := PackedFloat32Array()
	nx0.resize(count)
	nz0.resize(count)
	arcs.resize(count)
	for i in count:
		var i0 := maxi(0, i - 1)
		var i1 := mini(count - 1, i + 1)
		var dx := pts[i1 * 2] - pts[i0 * 2]
		var dz := pts[i1 * 2 + 1] - pts[i0 * 2 + 1]
		var l := sqrt(dx * dx + dz * dz)
		if l < 1e-6:
			l = 1.0
		nx0[i] = dz / l
		nz0[i] = -dx / l
	arcs[0] = 0.0
	for i in range(1, count):
		var dx := pts[i * 2] - pts[(i - 1) * 2]
		var dz := pts[i * 2 + 1] - pts[(i - 1) * 2 + 1]
		arcs[i] = arcs[i - 1] + sqrt(dx * dx + dz * dz)

	for si in segs.size():
		var i := segs[si]
		var j := i + 1
		if j >= count:
			continue
		var ax := pts[i * 2]
		var az := pts[i * 2 + 1]
		var bx := pts[j * 2]
		var bz := pts[j * 2 + 1]
		var anx := nx0[i]
		var anz := nz0[i]
		var bnx := nx0[j]
		var bnz := nz0[j]
		var a0 := arcs[i]
		var a1 := arcs[j]
		var ya := elev[i] if has_elev else C.Y_ROAD
		var yb := elev[j] if has_elev else C.Y_ROAD
		var lifted := ya > C.Y_ROAD + 0.25 or yb > C.Y_ROAD + 0.25
		var seg_len := sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az))

		# 水平条带：沿法线从 o1 到 o2，朝上
		var strip := func(o1: float, o2: float, y1: float, y2: float, tile: float, layer: int) -> void:
			var v0 := a0 / tile
			var v1 := a1 / tile
			var u_max := absf(o2 - o1) / tile
			var p0 := city.push(ax + anx * o1, y1, az + anz * o1, 0.0, v0, layer, 0.0, 0.0, 1.0)
			var p1 := city.push(bx + bnx * o1, y2, bz + bnz * o1, 0.0, v1, layer, 0.0, 0.0, 1.0)
			var p2 := city.push(bx + bnx * o2, y2, bz + bnz * o2, u_max, v1, layer, 0.0, 0.0, 1.0)
			var p3 := city.push(ax + anx * o2, y1, az + anz * o2, u_max, v0, layer, 0.0, 0.0, 1.0)
			city.quad(p0, p3, p2, p1)

		strip.call(-half, half, ya, yb, asphalt_tile, C.L.ASPHALT)
		if curbs:
			var sw := 2.8
			strip.call(half, half + sw, ya + dy_side, yb + dy_side, pave_tile, C.L.PAVEMENT)
			strip.call(-half - sw, -half, ya + dy_side, yb + dy_side, pave_tile, C.L.PAVEMENT)

		# 桥面：护栏（内外两片薄面，法线各自朝外）+ 桥墩
		if lifted:
			var rh := 1.02
			var rail := func(o: float, sgn: float) -> void:
				var nxr := anx * sgn
				var nzr := anz * sgn
				var u_r := seg_len / 2.0
				var v_r := rh / 2.0
				var r0 := city.push(ax + anx * o, ya, az + anz * o, 0.0, 0.0, C.L.FACADE_CONCRETE, nxr, nzr, 0.0)
				var r1 := city.push(bx + bnx * o, yb, bz + bnz * o, u_r, 0.0, C.L.FACADE_CONCRETE, bnx * sgn, bnz * sgn, 0.0)
				var r2 := city.push(bx + bnx * o, yb + rh, bz + bnz * o, u_r, v_r, C.L.FACADE_CONCRETE, bnx * sgn, bnz * sgn, 0.0)
				var r3 := city.push(ax + anx * o, ya + rh, az + anz * o, 0.0, v_r, C.L.FACADE_CONCRETE, nxr, nzr, 0.0)
				city.quad(r3, r2, r1, r0)
			rail.call(half + 0.14, 1.0)
			rail.call(half + 0.10, -1.0)
			rail.call(-half - 0.14, -1.0)
			rail.call(-half - 0.10, 1.0)

			var y_mid := (ya + yb) * 0.5
			if y_mid > C.Y_LAND + 2.4 and a0 - last_pier >= 26.0:
				last_pier = a0
				var mx := (ax + bx) * 0.5
				var mz := (az + bz) * 0.5
				var rot := atan2(bz - az, bx - ax)
				var cap_y := y_mid - 0.8
				add_box(city, mx - 1.4, mz - half - 0.6, mx + 1.4, mz + half + 0.6, cap_y, y_mid - 0.4, C.L.FACADE_CONCRETE, 3.0, false, rot)
				add_box(city, mx - 1.1, mz - 1.7, mx + 1.1, mz + 1.7, C.Y_LAND - 0.6, cap_y, C.L.FACADE_CONCRETE, 3.0, false, rot)

		# 标线
		if markings:
			var my_at := func(f: float) -> float: return ya + (yb - ya) * f + dy_mark
			var dash := func(offset: float, w: float, from_arc: float, to_arc: float, on_len: float, off_len: float) -> void:
				var span := on_len + off_len
				var t := maxf(from_arc, floorf(from_arc / span) * span)
				while t < to_arc:
					var t0 := maxf(t, from_arc)
					var t1 := minf(t + on_len, to_arc)
					if t1 - t0 > 0.35:
						var denom := maxf(1e-3, a1 - a0)
						var f0 := (t0 - a0) / denom
						var f1 := (t1 - a0) / denom
						var cx0 := ax + (bx - ax) * f0
						var cz0 := az + (bz - az) * f0
						var cx1 := ax + (bx - ax) * f1
						var cz1 := az + (bz - az) * f1
						var nxm := anx + (bnx - anx) * f0
						var nzm := anz + (bnz - anz) * f0
						var q0 := cut.push(cx0 + nxm * offset, my_at.call(f0), cz0 + nzm * offset, 0.0, 0.0, C.L.MARKING, 0.0, 0.0, 1.0)
						var q1 := cut.push(cx1 + nxm * offset, my_at.call(f1), cz1 + nzm * offset, 0.0, 0.0, C.L.MARKING, 0.0, 0.0, 1.0)
						var q2 := cut.push(cx1 + nxm * (offset + w), my_at.call(f1), cz1 + nzm * (offset + w), 0.0, 0.0, C.L.MARKING, 0.0, 0.0, 1.0)
						var q3 := cut.push(cx0 + nxm * (offset + w), my_at.call(f0), cz0 + nzm * (offset + w), 0.0, 0.0, C.L.MARKING, 0.0, 0.0, 1.0)
						cut.quad(q3, q2, q1, q0)
					t += span
			# 虚线覆盖本线段的全弧长区间（起止必须是 a0..a1；传 0..1 会让插值系数爆炸）
			dash.call(-0.09, 0.18, a0, a1, 3.2, 5.2)
			var lanes := data.r_lanes[road]
			if lanes >= 4:
				var step := half / ceilf(lanes / 2.0)
				dash.call(step - 0.07, 0.14, a0, a1, 2.4, 6.4)
				dash.call(-step, 0.14, a0, a1, 2.4, 6.4)

		# 街灯（与桥面一起抬升）
		if kind >= 2:
			var spacing := 48.0
			var k0 := ceili(a0 / spacing)
			var k1 := floori(a1 / spacing)
			for k in range(k0, k1 + 1):
				var arc_pos := k * spacing
				var f := clampf((arc_pos - a0) / maxf(1e-3, a1 - a0), 0.0, 1.0)
				var sx := ax + (bx - ax) * f
				var sz := az + (bz - az) * f
				var nx := anx + (bnx - anx) * f
				var nz := anz + (bnz - anz) * f
				var side := 1.0 if k % 2 == 0 else -1.0
				var off := half + (2.2 if curbs else 0.8)
				var px := sx + nx * side * off
				var pz := sz + nz * side * off
				var sy := ya + (yb - ya) * f + dy_side
				var pole_h := 7.6
				add_box(city, px - 0.17, pz - 0.17, px + 0.17, pz + 0.17, sy, sy + pole_h, C.L.FACADE_CONCRETE, 2.0, false, 0.0)
				add_box(city, px - 0.55, pz - 0.55, px + 0.55, pz + 0.55, sy + pole_h, sy + pole_h + 0.4, C.L.ROOF_A, 1.0, false, 0.0)
				var gy := sy + pole_h - 0.5
				var gs := 6.0
				var g0 := glow.push(px - gs / 2.0, gy, pz, 0.0, 0.0, C.L.GLOW, 0.0, 0.0, 1.0)
				var g1 := glow.push(px, gy, pz + gs / 2.0, 1.0, 0.0, C.L.GLOW, 0.0, 0.0, 1.0)
				var g2 := glow.push(px + gs / 2.0, gy, pz, 1.0, 1.0, C.L.GLOW, 0.0, 0.0, 1.0)
				var g3 := glow.push(px, gy, pz - gs / 2.0, 0.0, 1.0, C.L.GLOW, 0.0, 0.0, 1.0)
				glow.quad(g0, g1, g2, g3)

# ============================================================================
# 行道树
# ============================================================================


func _build_trees(city: GeoBuilder, cut: GeoBuilder, road: int, segs: PackedInt32Array) -> void:
	var data := _data
	var kind := data.r_kind[road]
	if kind < 1 or kind > 3:
		return
	var count := data.road_vert_count(road)
	if count < 2:
		return
	var pts := PackedFloat32Array()
	pts.resize(count * 2)
	for i in count:
		var p := data.road_point(road, i)
		pts[i * 2] = p.x
		pts[i * 2 + 1] = p.y
	var offset := data.r_width[road] * 0.5 + (3.6 if kind >= 2 else 1.6)
	var seed_v := road * 31 + kind
	var elev_v = data.graph.road_elev_of(road)
	var has_elev := elev_v is PackedFloat32Array and elev_v.size() >= count
	var elev: PackedFloat32Array = elev_v if has_elev else PackedFloat32Array()
	for si in segs.size():
		var i := segs[si]
		var j := i + 1
		if j >= count:
			continue
		# 桥上不种树（树贴地会穿过桥面）
		if has_elev and (elev[i] > C.Y_ROAD + 0.3 or elev[j] > C.Y_ROAD + 0.3):
			continue
		var ax := pts[i * 2]
		var az := pts[i * 2 + 1]
		var bx := pts[j * 2]
		var bz := pts[j * 2 + 1]
		var dx := bx - ax
		var dz := bz - az
		var l := sqrt(dx * dx + dz * dz)
		if l < 9.0:
			continue
		var n := maxi(1, floori(l / 22.0))
		for k in n:
			var t := (k + 0.5) / n
			var r := GeoBuilder.rand01(seed_v, i * 16 + k, 3)
			if r > 0.74:
				continue
			var side := 1.0 if r < 0.37 else -1.0
			var nx := dz / l
			var nz := -dx / l
			var jitter := GeoBuilder.rand01(seed_v, i * 16 + k, 4) * 2.6
			var px := ax + dx * t + nx * side * (offset + jitter)
			var pz := az + dz * t + nz * side * (offset + jitter)
			if data.blocked_at(px, pz, 1.6):
				continue
			add_tree(city, cut, px, pz, 0.8 + r * 0.8, GeoBuilder.rand01(seed_v, i * 16 + k, 5) * TAU)

# ============================================================================
# 通用几何小工具
# ============================================================================


## 判定「x,z 平面三角形」的面法线 y 分量：(B-A)×(C-A) 的 y = (bx-ax)(cz-az) - (bz-az)(cx-ax)
## > 0 表示法线朝上（正面朝上）；Godot 与 Three 一致：法线朝向相机的一侧才绘制
static func face_up_y(ax: float, az: float, bx: float, bz: float, cx: float, cz: float) -> float:
	return (bx - ax) * (cz - az) - (bz - az) * (cx - ax)


## 分块底铺：一整块 640×640 的陆地平面（朝上）
static func push_ground_base(b: GeoBuilder, cx: int, cz: int, layer: int) -> void:
	var x0 := cx * C.CHUNK_SIZE
	var z0 := cz * C.CHUNK_SIZE
	var x1 := x0 + C.CHUNK_SIZE
	var z1 := z0 + C.CHUNK_SIZE
	var tile: float = C.LAYER_TILE[layer]
	var y := C.Y_LAND
	var p0 := b.push(x0, y, z0, x0 / tile, z0 / tile, layer, 0.0, 0.0, 1.0)
	var p1 := b.push(x1, y, z0, x1 / tile, z0 / tile, layer, 0.0, 0.0, 1.0)
	var p2 := b.push(x1, y, z1, x1 / tile, z1 / tile, layer, 0.0, 0.0, 1.0)
	var p3 := b.push(x0, y, z1, x0 / tile, z1 / tile, layer, 0.0, 0.0, 1.0)
	# 朝上的面：面法线 (B-A)×(C-A) 必须指向 +y（Godot 与 Three 一致：法线朝向相机才可见）
	b.quad(p0, p1, p2, p3)


## 箱体：四面墙 + 顶面，可绕中心旋转
static func add_box(b: GeoBuilder, x0: float, z0: float, x1: float, z1: float, y0: float, y1: float, layer: int, tile: float, bottom: bool, rot: float) -> void:
	var cx := (x0 + x1) * 0.5
	var cz := (z0 + z1) * 0.5
	var hw := (x1 - x0) * 0.5
	var hd := (z1 - z0) * 0.5
	var cos_r := cos(rot)
	var sin_r := sin(rot)
	var corner_x: Array[float] = [cx - hw, cx + hw, cx + hw, cx - hw]
	var corner_z: Array[float] = [cz - hd, cz - hd, cz + hd, cz + hd]
	var v1 := (y1 - y0) / tile
	for i in 4:
		var j := (i + 1) % 4
		var ax := cx + (corner_x[i] - cx) * cos_r - (corner_z[i] - cz) * sin_r
		var az := cz + (corner_x[i] - cx) * sin_r + (corner_z[i] - cz) * cos_r
		var bx := cx + (corner_x[j] - cx) * cos_r - (corner_z[j] - cz) * sin_r
		var bz := cz + (corner_x[j] - cx) * sin_r + (corner_z[j] - cz) * cos_r
		var dx := bx - ax
		var dz := bz - az
		var l := sqrt(dx * dx + dz * dz)
		if l < 1e-6:
			l = 1.0
		var nx := dz / l
		var nz := -dx / l
		var a := b.push(ax, y0, az, 0.0, 0.0, layer, nx, nz, 0.0)
		var bq := b.push(bx, y0, bz, l / tile, 0.0, layer, nx, nz, 0.0)
		var c := b.push(bx, y1, bz, l / tile, v1, layer, nx, nz, 0.0)
		var d := b.push(ax, y1, az, 0.0, v1, layer, nx, nz, 0.0)
		b.quad(d, c, bq, a)
	var t0 := b.push(x0, y1, z0, x0 / tile, z0 / tile, layer, 0.0, 0.0, 1.0)
	var t1 := b.push(x1, y1, z0, x1 / tile, z0 / tile, layer, 0.0, 0.0, 1.0)
	var t2 := b.push(x1, y1, z1, x1 / tile, z1 / tile, layer, 0.0, 0.0, 1.0)
	var t3 := b.push(x0, y1, z1, x0 / tile, z1 / tile, layer, 0.0, 0.0, 1.0)
	b.quad(t0, t1, t2, t3)
	if bottom:
		var b0 := b.push(x0, y0, z0, x0 / tile, z0 / tile, layer, 0.0, 0.0, 0.0)
		var b1 := b.push(x1, y0, z0, x1 / tile, z0 / tile, layer, 0.0, 0.0, 0.0)
		var b2 := b.push(x1, y0, z1, x1 / tile, z1 / tile, layer, 0.0, 0.0, 0.0)
		var b3 := b.push(x0, y0, z1, x0 / tile, z1 / tile, layer, 0.0, 0.0, 0.0)
		# 朝下：与顶面相反
		b.quad(b0, b3, b2, b1)


## 细长十字面片（桅杆 / 天线）——放在双面材质里
static func add_cross(b: GeoBuilder, x: float, z: float, y0: float, y1: float, half: float, layer: int) -> void:
	for i in 2:
		var ax := half if i == 0 else 0.0
		var rz := 0.0 if i == 0 else half
		var p0 := b.push(x - ax, y0, z - rz, 0.0, 0.0, layer, 0.0, 0.0, 0.0)
		var p1 := b.push(x + ax, y0, z + rz, 1.0, 0.0, layer, 0.0, 0.0, 0.0)
		var p2 := b.push(x + ax, y1, z + rz, 1.0, 1.0, layer, 0.0, 0.0, 0.0)
		var p3 := b.push(x - ax, y1, z - rz, 0.0, 1.0, layer, 0.0, 0.0, 0.0)
		b.quad(p0, p1, p2, p3)


## 行道树：树干（不透明）+ 交叉树冠面片（alpha scissor）
static func add_tree(city: GeoBuilder, cut: GeoBuilder, x: float, z: float, scale: float, rot: float) -> void:
	var y := C.Y_GRASS
	var trunk_h := 2.6 * scale
	var r := 0.16 * scale
	add_box(city, x - r, z - r, x + r, z + r, y, y + trunk_h, C.L.FACADE_BRICK, 2.0, false, 0.0)
	var canopy_r := 1.95 * scale
	var canopy_h := 3.4 * scale
	var base_y := y + trunk_h * 0.55
	var tile: float = C.LAYER_TILE[C.L.CANOPY]
	for i in 3:
		var ang := rot + (i * PI) / 3.0
		var nx := cos(ang)
		var nz := sin(ang)
		var a0 := cut.push(x - nx * canopy_r, base_y, z - nz * canopy_r, 0.0, 0.0, C.L.CANOPY, nx, nz, 0.0)
		var a1 := cut.push(x + nx * canopy_r, base_y, z + nz * canopy_r, (canopy_r * 2.0) / tile, 0.0, C.L.CANOPY, nx, nz, 0.0)
		var a2 := cut.push(x + nx * canopy_r, base_y + canopy_h, z + nz * canopy_r, (canopy_r * 2.0) / tile, canopy_h / tile, C.L.CANOPY, nx, nz, 0.0)
		var a3 := cut.push(x - nx * canopy_r, base_y + canopy_h, z - nz * canopy_r, 0.0, canopy_h / tile, C.L.CANOPY, nx, nz, 0.0)
		cut.quad(a0, a1, a2, a3)
	var top := base_y + canopy_h
	var o0 := cut.push(x - canopy_r, top, z - canopy_r, 0.0, 0.0, C.L.CANOPY, 0.0, 0.0, 1.0)
	var o1 := cut.push(x + canopy_r, top, z - canopy_r, (canopy_r * 2.0) / tile, 0.0, C.L.CANOPY, 0.0, 0.0, 1.0)
	var o2 := cut.push(x + canopy_r, top, z + canopy_r, (canopy_r * 2.0) / tile, (canopy_r * 2.0) / tile, C.L.CANOPY, 0.0, 0.0, 1.0)
	var o3 := cut.push(x - canopy_r, top, z + canopy_r, 0.0, (canopy_r * 2.0) / tile, C.L.CANOPY, 0.0, 0.0, 1.0)
	cut.quad(o0, o1, o2, o3)