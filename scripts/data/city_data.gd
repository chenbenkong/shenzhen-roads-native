## 城市数据（CityData）—— Web 版 `src/data/cityData.ts` 的逐语义 GDScript 移植
##
## 职责：解码 city.bin 的建筑 / 道路 / 地面三大块（记录式小节按记录逐字段解码），
## 建好分块索引（CHUNK_SIZE 640m）与碰撞 / 地表查询网格，并持有 RoadGraph 路网图。
##
## 关键约定（踩坑修正过，别改）：
##   · bmeta(20B) / rmeta(16B) / gpoly(8B) / emeta(16B) 的 count 是「记录数」，
##     必须按记录逐字段解码（小端）
##   · bmeta / rmeta 里的 vertStart / vertCount 以「扁平元素」（x,z 交替）计：
##     start/2 才是顶点下标，count/2 才是顶点数 —— 最容易写错的地方
##   · chunkKey / chunkKey2 / gridKey 的整数打包方式与 TS 版完全一致，渲染/构建多处依赖
##
## GDScript 适配约定（语义等价，仅表达方式不同）：
##   · 未命中的查询返回「空 PackedInt32Array / 空 Dictionary」（TS 返回 undefined / null）
##   · Packed*Array 是值语义、无法通过参数回写，故 poly_triangle 改为「返回新数组」；
##     read_rings / collide_circle / surface_at / chunk_key_coords 用 Array / Dictionary
##     承载（它们是引用语义，可直接回写）
class_name CityData
extends RefCounted

const GROUND_CELL := 48.0  # 地表查询网格边长（米）

var bin: CityBin
var meta: Dictionary = {}
var graph: RoadGraph

# ── 建筑 ──
var building_count: int = 0
var b_height := PackedFloat32Array()
var b_style := PackedByteArray()
var b_podium := PackedByteArray()
var b_facade_layer := PackedByteArray()
var b_roof_layer := PackedByteArray()
var b_seed := PackedInt32Array()
var b_cx := PackedFloat32Array()
var b_cz := PackedFloat32Array()
var b_min_x := PackedFloat32Array()
var b_max_x := PackedFloat32Array()
var b_min_z := PackedFloat32Array()
var b_max_z := PackedFloat32Array()
var b_radius := PackedFloat32Array()
var _b_vert := PackedInt32Array()
var _b_rings := PackedInt32Array()
var _b_vert_start := PackedInt32Array()
var _b_vert_count := PackedInt32Array()
var _b_ring_base := PackedInt32Array()
var _b_ring_count := PackedByteArray()
var _b_winding := PackedInt32Array()  # 0=未算，±1=环绕方向（碰撞法线用）
var _building_by_chunk: Dictionary = {}
var _coll_grid: Dictionary = {}

# ── 道路 ──
var road_count: int = 0
var r_kind := PackedByteArray()
var r_width := PackedFloat32Array()
var r_lanes := PackedByteArray()
var r_flags := PackedByteArray()
var r_grade := PackedByteArray()
var r_name_idx := PackedInt32Array()
var r_name := PackedStringArray()
var _r_vert := PackedInt32Array()
var _r_vert_start := PackedInt32Array()
var _r_vert_count := PackedInt32Array()
var _road_segs: Dictionary = {}  # chunkKey → { 道路索引 → PackedInt32Array 线段起点下标 }

# ── 地面 ──
var ground_count: int = 0
var _g_vert := PackedInt32Array()
var _g_tri := PackedInt32Array()
var _g_tri_start := PackedInt32Array()
var _g_tri_count := PackedInt32Array()
var _g_layer := PackedByteArray()
var _ground_by_chunk: Dictionary = {}
var _surface_grid: Dictionary = {}
var _surface_cache_key: float = NAN  # NaN 与任何 key 都不相等（同 TS 版）
var _surface_cache := {"y": C.Y_LAND, "layer": 0}


## 从 city.bin + city-meta.json 构造（meta 仅作为元信息持有，不参与计算）
static func load_from(bin_path: String, meta_path: String) -> CityData:
	var b := CityBin.load_from(bin_path)
	if b == null:
		return null
	var text := FileAccess.get_file_as_string(meta_path)
	var m: Dictionary = {}
	if text.is_empty():
		push_error("city-meta.json 读取失败：%s" % meta_path)
	else:
		var parsed = JSON.parse_string(text)
		if parsed is Dictionary:
			m = parsed
		else:
			push_error("city-meta.json 不是合法 JSON 对象：%s" % meta_path)
	return CityData.new(b, m)


func _init(p_bin: CityBin, p_meta: Dictionary) -> void:
	bin = p_bin
	meta = p_meta
	_decode_buildings()
	_decode_roads()
	_decode_ground()
	# 构建期的桶统一用 Array（引用语义，原地 append），收尾压缩成 PackedInt32Array
	_compact(_building_by_chunk)
	_compact(_coll_grid)
	_compact(_ground_by_chunk)
	_compact(_surface_grid)
	_compact_nested(_road_segs)
	graph = RoadGraph.new(p_bin)


# ───────────────────────── 建筑 ─────────────────────────

func _decode_buildings() -> void:
	var bmeta := bin.slice_of("bmeta")
	var n := bin.section("bmeta").count
	building_count = n
	_b_vert = bin.i16("bvert")
	_b_rings = bin.u16("brings")
	_b_vert_start.resize(n)
	_b_vert_count.resize(n)
	_b_ring_base.resize(n)
	_b_ring_count.resize(n)
	_b_winding.resize(n)
	b_height.resize(n)
	b_style.resize(n)
	b_podium.resize(n)
	b_facade_layer.resize(n)
	b_roof_layer.resize(n)
	b_seed.resize(n)
	b_cx.resize(n)
	b_cz.resize(n)
	b_min_x.resize(n)
	b_max_x.resize(n)
	b_min_z.resize(n)
	b_max_z.resize(n)
	b_radius.resize(n)
	var ring_cursor := 0
	for i in n:
		var o := i * 20
		# 二进制里 start/count 以「扁平元素」计，这里一律换算成顶点下标/顶点数
		_b_vert_start[i] = bmeta.decode_u32(o) / 2
		_b_vert_count[i] = bmeta.decode_u32(o + 4) / 2
		b_height[i] = float(bmeta.decode_u16(o + 8)) / 10.0
		_b_ring_count[i] = bmeta.decode_u8(o + 12)
		b_style[i] = bmeta.decode_u8(o + 13)
		b_roof_layer[i] = bmeta.decode_u8(o + 14)
		b_podium[i] = bmeta.decode_u8(o + 15) & 1
		b_seed[i] = bmeta.decode_u16(o + 16)
		b_facade_layer[i] = bmeta.decode_u8(o + 18)
		_b_ring_base[i] = ring_cursor
		ring_cursor += _b_ring_count[i]

		# 轮廓：质心 + 包围盒
		var sx := 0.0
		var sz := 0.0
		var bx0 := INF
		var bx1 := -INF
		var bz0 := INF
		var bz1 := -INF
		var vs := _b_vert_start[i]
		var vc := _b_vert_count[i]
		if vc <= 0:
			push_error("建筑 %d 顶点数为 0（bmeta 数据异常）" % i)
			continue
		for v in vc:
			var x := float(_b_vert[(vs + v) * 2]) / C.Q
			var z := float(_b_vert[(vs + v) * 2 + 1]) / C.Q
			sx += x
			sz += z
			bx0 = minf(bx0, x)
			bx1 = maxf(bx1, x)
			bz0 = minf(bz0, z)
			bz1 = maxf(bz1, z)
		b_cx[i] = sx / float(vc)
		b_cz[i] = sz / float(vc)
		b_min_x[i] = bx0
		b_max_x[i] = bx1
		b_min_z[i] = bz0
		b_max_z[i] = bz1
		b_radius[i] = sqrt((bx1 - bx0) * (bx1 - bx0) + (bz1 - bz0) * (bz1 - bz0)) * 0.5

	# 分块索引 + 碰撞网格（32m 格子，按包围盒填充）
	for i in n:
		_push_chunk(_building_by_chunk, chunk_key(b_cx[i], b_cz[i]), i)
		var c0x := floori(b_min_x[i] / 32.0)
		var c1x := floori(b_max_x[i] / 32.0)
		var c0z := floori(b_min_z[i] / 32.0)
		var c1z := floori(b_max_z[i] / 32.0)
		for cx in range(c0x, c1x + 1):
			for cz in range(c0z, c1z + 1):
				_push_chunk(_coll_grid, _grid_key(cx, cz), i)


# ───────────────────────── 道路 ─────────────────────────

func _decode_roads() -> void:
	var rmeta := bin.slice_of("rmeta")
	var rn := bin.section("rmeta").count
	road_count = rn
	_r_vert = bin.i16("rvert")
	_r_vert_start.resize(rn)
	_r_vert_count.resize(rn)
	r_kind.resize(rn)
	r_width.resize(rn)
	r_lanes.resize(rn)
	r_flags.resize(rn)
	r_grade.resize(rn)
	r_name_idx.resize(rn)
	for i in rn:
		var o := i * 16
		# 同建筑：扁平元素 → 顶点下标/顶点数
		_r_vert_start[i] = rmeta.decode_u32(o) / 2
		_r_vert_count[i] = rmeta.decode_u16(o + 4) / 2
		r_kind[i] = rmeta.decode_u8(o + 6)
		r_width[i] = float(rmeta.decode_u8(o + 7)) / 10.0
		r_lanes[i] = rmeta.decode_u8(o + 8)
		r_flags[i] = rmeta.decode_u8(o + 9)
		r_name_idx[i] = rmeta.decode_u16(o + 10)
		r_grade[i] = rmeta.decode_u8(o + 12)

	var off := bin.u16("rname")
	var bytes := bin.u8("rnameStr")
	if off.size() > 0:
		r_name.resize(off.size() - 1)
		for i in range(off.size() - 1):
			r_name[i] = bytes.slice(off[i], off[i + 1]).get_string_from_utf8()

	# 分块索引：以每条线段的「中点」归属分块
	for r in rn:
		var vs := _r_vert_start[r]
		var vc := _r_vert_count[r]
		for i in range(vc - 1):
			var mx := float(_r_vert[(vs + i) * 2] + _r_vert[(vs + i + 1) * 2]) / (2.0 * C.Q)
			var mz := float(_r_vert[(vs + i) * 2 + 1] + _r_vert[(vs + i + 1) * 2 + 1]) / (2.0 * C.Q)
			var key := chunk_key(mx, mz)
			var bucket: Dictionary
			if _road_segs.has(key):
				bucket = _road_segs[key]
			else:
				bucket = {}
				_road_segs[key] = bucket
			if bucket.has(r):
				var segs: Array = bucket[r]
				segs.append(i)
			else:
				bucket[r] = [i]


# ───────────────────────── 地面 ─────────────────────────

func _decode_ground() -> void:
	var gn := bin.section("gpoly").count
	ground_count = gn
	_g_vert = bin.i16("gvert")
	_g_tri = _to_i32(bin.u32("gtri"))
	_g_tri_start.resize(gn)
	_g_tri_count.resize(gn)
	_g_layer.resize(gn)
	var gpoly := bin.slice_of("gpoly")
	for i in gn:
		var o := i * 8
		_g_tri_start[i] = gpoly.decode_u32(o)
		_g_tri_count[i] = gpoly.decode_u16(o + 4)
		_g_layer[i] = gpoly.decode_u8(o + 6)

	for p in gn:
		var bx0 := INF
		var bx1 := -INF
		var bz0 := INF
		var bz1 := -INF
		var ts := _g_tri_start[p]
		var tc := _g_tri_count[p]
		for t in tc:
			for v in 3:
				var gi := _g_tri[ts + t * 3 + v]
				var x := float(_g_vert[gi * 2]) / C.Q
				var z := float(_g_vert[gi * 2 + 1]) / C.Q
				bx0 = minf(bx0, x)
				bx1 = maxf(bx1, x)
				bz0 = minf(bz0, z)
				bz1 = maxf(bz1, z)
		if _g_layer[p] == 0:
			# 陆地：跨越的分块都要画（同坐标重复绘制不会闪烁）
			var c0x := floori(bx0 / C.CHUNK_SIZE)
			var c1x := floori(bx1 / C.CHUNK_SIZE)
			var c0z := floori(bz0 / C.CHUNK_SIZE)
			var c1z := floori(bz1 / C.CHUNK_SIZE)
			for cx in range(c0x, c1x + 1):
				for cz in range(c0z, c1z + 1):
					_push_chunk(_ground_by_chunk, chunk_key_2(cx, cz), p)
		else:
			_push_chunk(_ground_by_chunk, chunk_key((bx0 + bx1) * 0.5, (bz0 + bz1) * 0.5), p)
		# 地表查询网格：按三角形逐格索引（code = poly << 12 | tri）
		for t in tc:
			var tx0 := INF
			var tx1 := -INF
			var tz0 := INF
			var tz1 := -INF
			for v in 3:
				var gi := _g_tri[ts + t * 3 + v]
				var x := float(_g_vert[gi * 2]) / C.Q
				var z := float(_g_vert[gi * 2 + 1]) / C.Q
				tx0 = minf(tx0, x)
				tx1 = maxf(tx1, x)
				tz0 = minf(tz0, z)
				tz1 = maxf(tz1, z)
			var g0x := floori(tx0 / GROUND_CELL)
			var g1x := floori(tx1 / GROUND_CELL)
			var g0z := floori(tz0 / GROUND_CELL)
			var g1z := floori(tz1 / GROUND_CELL)
			for cx in range(g0x, g1x + 1):
				for cz in range(g0z, g1z + 1):
					_push_chunk(_surface_grid, _grid_key(cx, cz), (p << 12) | mini(4095, t))


# ───────────────────────── 工具 ─────────────────────────

func _push_chunk(map: Dictionary, key: int, value: int) -> void:
	if map.has(key):
		var arr: Array = map[key]
		arr.append(value)
	else:
		map[key] = [value]


func _compact(map: Dictionary) -> void:
	for k in map:
		map[k] = PackedInt32Array(map[k])


func _compact_nested(map: Dictionary) -> void:
	for k in map:
		var bucket: Dictionary = map[k]
		for r in bucket:
			bucket[r] = PackedInt32Array(bucket[r])


func _grid_key(cx: int, cz: int) -> int:
	return (cx + 4096) * 8192 + (cz + 4096)


func chunk_key(x: float, z: float) -> int:
	return chunk_key_2(floori(x / C.CHUNK_SIZE), floori(z / C.CHUNK_SIZE))


func chunk_key_2(cx: int, cz: int) -> int:
	return (cx + 512) * 4096 + (cz + 512)


## 反解分块坐标（写出 out["cx"] / out["cz"]）
func chunk_key_coords(key: int, out: Dictionary) -> void:
	out["cz"] = (key % 4096) - 512
	out["cx"] = floori(float(key) / 4096.0) - 512


func buildings_in_chunk(key: int) -> PackedInt32Array:
	if not _building_by_chunk.has(key):
		return PackedInt32Array()
	return _building_by_chunk[key]


func ground_in_chunk(key: int) -> PackedInt32Array:
	if not _ground_by_chunk.has(key):
		return PackedInt32Array()
	return _ground_by_chunk[key]


## 该分块内的道路线段：道路索引 → 线段起点下标数组
func road_segments_in_chunk(key: int) -> Dictionary:
	if not _road_segs.has(key):
		return {}
	return _road_segs[key]


## 读取建筑轮廓（out_rings[0] 为外圈，其后为洞），返回圈数
func read_rings(index: int, out_rings: Array) -> int:
	if index < 0 or index >= building_count:
		push_error("read_rings：建筑索引越界 %d" % index)
		return 0
	var rc := _b_ring_count[index]
	var cursor := _b_vert_start[index]
	var base := _b_ring_base[index]
	for r in rc:
		var count := _b_rings[base + r]
		var ring := PackedFloat32Array()
		ring.resize(count * 2)
		for i in count:
			ring[i * 2] = float(_b_vert[(cursor + i) * 2]) / C.Q
			ring[i * 2 + 1] = float(_b_vert[(cursor + i) * 2 + 1]) / C.Q
		cursor += count
		if r < out_rings.size():
			out_rings[r] = ring
		else:
			out_rings.append(ring)
	out_rings.resize(rc)
	return rc


## 道路折线第 i 个顶点：Vector2(x=世界x, y=世界z)（Godot 的 Vector2 只有 xy）
func road_point(road: int, i: int) -> Vector2:
	if road < 0 or road >= road_count:
		push_error("road_point：道路索引越界 %d" % road)
		return Vector2.ZERO
	if i < 0 or i >= _r_vert_count[road]:
		push_error("road_point：顶点下标越界 %d（道路 %d，共 %d 点）" % [i, road, _r_vert_count[road]])
		return Vector2.ZERO
	var idx := _r_vert_start[road] + i
	return Vector2(float(_r_vert[idx * 2]) / C.Q, float(_r_vert[idx * 2 + 1]) / C.Q)


## 道路折线顶点数
func road_vert_count(road: int) -> int:
	if road < 0 or road >= road_count:
		push_error("road_vert_count：道路索引越界 %d" % road)
		return 0
	return _r_vert_count[road]


## 地面多边形贴图分层：0 陆地 / 1 草地 / 2 水体
func ground_layer(poly: int) -> int:
	if poly < 0 or poly >= ground_count:
		push_error("ground_layer：地面索引越界 %d" % poly)
		return 0
	return _g_layer[poly]


## 地面多边形三角数
func ground_tri_count(poly: int) -> int:
	if poly < 0 or poly >= ground_count:
		push_error("ground_tri_count：地面索引越界 %d" % poly)
		return 0
	return _g_tri_count[poly]


## 地面多边形的第 tri 个三角形：返回 6 个数（x0,z0,x1,z1,x2,z2）
func poly_triangle(poly: int, tri: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(6)
	if poly < 0 or poly >= ground_count:
		push_error("poly_triangle：地面索引越界 %d" % poly)
		return out
	if tri < 0 or tri >= _g_tri_count[poly]:
		push_error("poly_triangle：三角下标越界 %d（地面 %d，共 %d 个）" % [tri, poly, _g_tri_count[poly]])
		return out
	var ts := _g_tri_start[poly] + tri * 3
	for v in 3:
		var gi := _g_tri[ts + v]
		out[v * 2] = float(_g_vert[gi * 2]) / C.Q
		out[v * 2 + 1] = float(_g_vert[gi * 2 + 1]) / C.Q
	return out


## 地表高度与类型（带一帧缓存，物理每帧调用）
## 返回 {y, layer}：layer 0 陆地 / 1 草地 / 2 水体 / -1 未知（海面）
func surface_at(x: float, z: float) -> Dictionary:
	var key := roundi(x * 8.0) * 10000000 + roundi(z * 8.0)
	if key == _surface_cache_key:
		return _surface_cache
	_surface_cache_key = key
	var layer := -1
	var y := -1.0
	var cx := floori(x / GROUND_CELL)
	var cz := floori(z / GROUND_CELL)
	for ax in range(-1, 2):
		for az in range(-1, 2):
			if layer >= 0:
				break
			var k := _grid_key(cx + ax, cz + az)
			if not _surface_grid.has(k):
				continue
			var arr: PackedInt32Array = _surface_grid[k]
			for code in arr:
				var poly := code >> 12
				var t := code & 4095
				if t >= _g_tri_count[poly]:
					continue
				if _point_in_tri(poly, t, x, z):
					layer = _g_layer[poly]
					y = C.Y_WATER if layer == 2 else (C.Y_GRASS if layer == 1 else C.Y_LAND)
					break
		if layer >= 0:
			break
	if layer < 0:
		layer = -1
		y = C.Y_SEA
	_surface_cache = {"y": y, "layer": layer}
	return _surface_cache


func _point_in_tri(poly: int, t: int, x: float, z: float) -> bool:
	var ts := _g_tri_start[poly] + t * 3
	var i0 := _g_tri[ts]
	var i1 := _g_tri[ts + 1]
	var i2 := _g_tri[ts + 2]
	var ax := float(_g_vert[i0 * 2]) / C.Q
	var az := float(_g_vert[i0 * 2 + 1]) / C.Q
	var bx := float(_g_vert[i1 * 2]) / C.Q
	var bz := float(_g_vert[i1 * 2 + 1]) / C.Q
	var cx := float(_g_vert[i2 * 2]) / C.Q
	var cz := float(_g_vert[i2 * 2 + 1]) / C.Q
	var d1 := (x - bx) * (az - bz) - (ax - bx) * (z - bz)
	var d2 := (x - cx) * (bz - cz) - (bx - cx) * (z - cz)
	var d3 := (x - ax) * (cz - az) - (cx - ax) * (z - az)
	var has_neg := d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var has_pos := d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	return not (has_neg and has_pos)


## 点是否落在建筑包围盒内（道具摆放规避用，纯 bbox 近似）
func blocked_at(x: float, z: float, pad: float = 0.0) -> bool:
	var k := _grid_key(floori(x / 32.0), floori(z / 32.0))
	if not _coll_grid.has(k):
		return false
	var arr: PackedInt32Array = _coll_grid[k]
	for bi in arr:
		if x >= b_min_x[bi] - pad and x <= b_max_x[bi] + pad and z >= b_min_z[bi] - pad and z <= b_max_z[bi] + pad:
			return true
	return false


## 圆形与建筑碰撞：命中时 out 写出推出后的位置与法线（{x, z, nx, nz, hit}）
func collide_circle(x: float, z: float, radius: float, out: Dictionary) -> bool:
	var cx := floori(x / 32.0)
	var cz := floori(z / 32.0)
	var worst_pen := 0.0
	var best_nx := 0.0
	var best_nz := 0.0
	for ax in range(-1, 2):
		for az in range(-1, 2):
			var k := _grid_key(cx + ax, cz + az)
			if not _coll_grid.has(k):
				continue
			var arr: PackedInt32Array = _coll_grid[k]
			for bi in arr:
				if x < b_min_x[bi] - radius or x > b_max_x[bi] + radius:
					continue
				if z < b_min_z[bi] - radius or z > b_max_z[bi] + radius:
					continue
				var pen := _outer_ring_penetration(bi, x, z, radius, out)
				if pen > worst_pen:
					worst_pen = pen
					best_nx = out["nx"]
					best_nz = out["nz"]
	if worst_pen <= 0.0:
		out["hit"] = false
		return false
	out["x"] = x + best_nx * worst_pen
	out["z"] = z + best_nz * worst_pen
	out["nx"] = best_nx
	out["nz"] = best_nz
	out["hit"] = true
	return true


## 外圈轮廓：判断圆是否穿透，返回穿透深度并写出法线（out["nx"] / out["nz"]）
func _outer_ring_penetration(bi: int, x: float, z: float, radius: float, out: Dictionary) -> float:
	var vs := _b_vert_start[bi]
	var count := _b_rings[_b_ring_base[bi]]
	if count <= 0:
		return 0.0
	# 环绕方向（决定内外法线方向），缓存
	var wind := _b_winding[bi]
	if wind == 0:
		var area := 0.0
		for i in count:
			var j := (i + 1) % count
			var ax := float(_b_vert[(vs + i) * 2]) / C.Q
			var az := float(_b_vert[(vs + i) * 2 + 1]) / C.Q
			var bx := float(_b_vert[(vs + j) * 2]) / C.Q
			var bz := float(_b_vert[(vs + j) * 2 + 1]) / C.Q
			area += ax * bz - bx * az
		wind = 1 if area > 0.0 else -1
		_b_winding[bi] = wind
	var inside := true
	var best_d := -INF
	var bnx := 0.0
	var bnz := 0.0
	var near_d := INF
	var nnx := 0.0
	var nnz := 0.0
	for i in count:
		var j := (i + 1) % count
		var ax := float(_b_vert[(vs + i) * 2]) / C.Q
		var az := float(_b_vert[(vs + i) * 2 + 1]) / C.Q
		var bx := float(_b_vert[(vs + j) * 2]) / C.Q
		var bz := float(_b_vert[(vs + j) * 2 + 1]) / C.Q
		var ex := bx - ax
		var ez := bz - az
		var nl := sqrt(ex * ex + ez * ez)
		if nl == 0.0:
			nl = 1.0
		# 内侧法线
		var nx := -ez * wind
		var nz := ex * wind
		var d := ((x - ax) * nx + (z - az) * nz) / nl
		if d > 0.0:
			inside = false
		if d > best_d:
			best_d = d
			bnx = nx / nl
			bnz = nz / nl
		var seg_len2 := ex * ex + ez * ez
		if seg_len2 == 0.0:
			seg_len2 = 1.0
		var t := clampf(((x - ax) * ex + (z - az) * ez) / seg_len2, 0.0, 1.0)
		var px := ax + ex * t
		var pz := az + ez * t
		var pd := sqrt((x - px) * (x - px) + (z - pz) * (z - pz))
		if pd < near_d:
			near_d = pd
			var dl := pd if pd > 0.0 else 1.0
			nnx = (x - px) / dl
			nnz = (z - pz) / dl
	if inside:
		out["nx"] = -bnx
		out["nz"] = -bnz
		return -best_d + radius
	if near_d < radius:
		out["nx"] = nnx
		out["nz"] = nnz
		return radius - near_d
	return 0.0


static func _to_i32(src: PackedInt64Array) -> PackedInt32Array:
	## u32 段在 city_bin 里用 64 位承载；这里值域都远小于 int32，压缩为 int32 提速
	var out := PackedInt32Array()
	out.resize(src.size())
	for i in src.size():
		out[i] = src[i]
	return out