## 路网图 —— Web 版 `src/data/roadGraph.ts` 的逐语义 GDScript 移植
##
## 结构：节点（路口）+ 有向边（单行道只能 A→B）。对外提供
##   · 几何采样：sample_edge / edge_polyline / road_polyline / road_width
##   · 空间查询：closest_edge / project_edge / closest_node（64m 哈希网格）
##   · 桥面高程：node_y / edge_y / road_elev_of（仅含桥的道路生成逐顶点高程）
##   · A* 寻路：path / path_points
## 供交通 AI / 行人 / 导航 / 车辆贴地共用。热路径全部走裸 float + Packed 数组，
## 不引入 Vector3 / Dictionary 分配（sample_edge 的 out 由调用方复用）。
##
## GDScript 适配约定（语义等价，仅表达方式不同）：
##   · 查询类接口未命中时返回「空 Dictionary」（TS 版返回 null），调用方用 is_empty() 判断
##   · Packed*Array 是值语义、无法通过参数回写，故折线类接口改为「返回新数组」
##   · 私有成员统一 `_` 前缀（对应 TS 的 private）
class_name RoadGraph
extends RefCounted

const HEAP_CAP := 1 << 16  # A* 二叉堆容量（与 TS 版一致）

# ── 节点（路口）──
var node_count: int = 0
var node_x := PackedFloat32Array()
var node_z := PackedFloat32Array()
var node_y := PackedFloat32Array()
var edge_off := PackedInt32Array()   # 邻接表偏移（node_count+1）
var edge_list := PackedInt32Array()  # 邻接边索引

# ── 有向边 ──
var edge_count: int = 0
var e_road := PackedInt32Array()
var e_a := PackedInt32Array()
var e_b := PackedInt32Array()
var e_arc := PackedFloat32Array()    # 边起点在道路折线上的弧长
var e_len := PackedFloat32Array()
var e_kind := PackedByteArray()
var e_flags := PackedByteArray()     # bit0 单向 A→B / bit1 桥
var e_lanes := PackedByteArray()
var e_speed := PackedFloat32Array()

# ── 道路（折线 + 宽度）──
var _r_vert := PackedInt32Array()        # 扁平元素（x,z 交替，量化 0.25m）
var _r_vert_start := PackedInt32Array()  # 顶点下标（= 元素下标 / 2）
var _r_vert_count := PackedInt32Array()  # 顶点数（= 元素个数 / 2）
var _r_width := PackedFloat32Array()
## 道路折线逐顶点高程：仅含桥的道路生成，其余为 null → 调用方回退路面高度
var _road_elev: Array = []

# ── 最近边查询网格 ──
const _CELL := 64.0
var _grid: Dictionary = {}  # key(cx,cz) → PackedInt32Array 边索引

# ── A* 二叉堆 ──
var _heap_node := PackedInt32Array()
var _heap_cost := PackedFloat32Array()
var _heap_size: int = 0
var _g_score := PackedFloat32Array()
var _f_score := PackedFloat32Array()
var _came_from := PackedInt32Array()
var _visited := PackedByteArray()
var _stamp := PackedInt32Array()
var _stamp_id: int = 0


func _init(bin: CityBin) -> void:
	# A* 堆预分配（与 TS 版的 Int32Array(HEAP_CAP) 一致）
	_heap_node.resize(HEAP_CAP)
	_heap_cost.resize(HEAP_CAP)

	edge_count = bin.section("emeta").count
	node_count = bin.section("npos").count / 2  # npos 以扁平元素计

	var npos := bin.i16("npos")
	node_x.resize(node_count)
	node_z.resize(node_count)
	for i in node_count:
		node_x[i] = float(npos[i * 2]) / C.Q
		node_z[i] = float(npos[i * 2 + 1]) / C.Q
	edge_off = _to_i32(bin.u32("nEdgeOff"))
	edge_list = _to_i32(bin.u32("nEdge"))

	var n := edge_count
	e_road.resize(n)
	e_a.resize(n)
	e_b.resize(n)
	e_arc.resize(n)
	e_len.resize(n)
	e_kind.resize(n)
	e_flags.resize(n)
	e_lanes.resize(n)
	e_speed.resize(n)
	var dv_e := bin.slice_of("emeta")
	for i in n:
		var o := i * 16
		e_road[i] = dv_e.decode_u16(o)
		e_a[i] = dv_e.decode_u16(o + 2)
		e_b[i] = dv_e.decode_u16(o + 4)
		e_arc[i] = float(dv_e.decode_u16(o + 6)) / 10.0
		e_len[i] = float(dv_e.decode_u16(o + 8)) / 10.0
		e_kind[i] = dv_e.decode_u8(o + 10)
		e_flags[i] = dv_e.decode_u8(o + 11)
		e_lanes[i] = dv_e.decode_u8(o + 12)
		var k := e_kind[i]
		e_speed[i] = C.KIND_SPEED[k] if k < C.KIND_SPEED.size() else 9.0  # 与 TS 的 ?? 9 一致

	_r_vert = bin.i16("rvert")
	var rn := bin.section("rmeta").count
	_r_vert_start.resize(rn)
	_r_vert_count.resize(rn)
	_r_width.resize(rn)
	var dv_r := bin.slice_of("rmeta")
	for i in rn:
		var o := i * 16
		# rmeta 的 start/count 以「扁平元素」（x,z 交替）计，这里一律换算成顶点下标/顶点数
		_r_vert_start[i] = dv_r.decode_u32(o) / 2
		_r_vert_count[i] = dv_r.decode_u16(o + 4) / 2
		_r_width[i] = float(dv_r.decode_u8(o + 7)) / 10.0

	# 节点高程：所有相邻边都是桥 → 桥面高度（配合 edge_y 形成自然引桥坡道）
	node_y.resize(node_count)
	var total := PackedInt32Array()
	var bridge := PackedInt32Array()
	total.resize(node_count)
	bridge.resize(node_count)
	for e in n:
		var a := e_a[e]
		var b := e_b[e]
		total[a] += 1
		total[b] += 1
		if e_flags[e] & 2:
			bridge[a] += 1
			bridge[b] += 1
	for i in node_count:
		node_y[i] = C.Y_BRIDGE if (total[i] > 0 and bridge[i] == total[i]) else C.Y_ROAD

	_build_elevation()
	_build_grid()


## 桥面高程：把「边」两端的节点高程展开到「道路折线」的每个顶点，
## 渲染（桥面板 / 桥墩）与车辆贴地共用同一份数据，避免悬空或穿模。
func _build_elevation() -> void:
	var road_total := _r_vert_start.size()
	var buckets: Dictionary = {}  # road → Array[edge]
	for e in edge_count:
		var r := e_road[e]
		if buckets.has(r):
			var arr: Array = buckets[r]
			arr.append(e)
		else:
			buckets[r] = [e]
	_road_elev.resize(road_total)  # 填 null
	for r in road_total:
		if not buckets.has(r):
			continue
		var list: Array = buckets[r]
		var lifted := false
		for e in list:
			if e_flags[e] & 2:
				lifted = true
				break
		if not lifted:
			continue
		var vs := _r_vert_start[r]
		var vc := _r_vert_count[r]
		var elev := PackedFloat32Array()
		elev.resize(vc)
		var arc := 0.0
		for i in vc:
			if i > 0:
				var dx := float(_r_vert[(vs + i) * 2] - _r_vert[(vs + i - 1) * 2]) / C.Q
				var dz := float(_r_vert[(vs + i) * 2 + 1] - _r_vert[(vs + i - 1) * 2 + 1]) / C.Q
				arc += sqrt(dx * dx + dz * dz)
			var y := C.Y_ROAD
			for e in list:
				var a0 := e_arc[e]
				if arc >= a0 - 0.25 and arc <= a0 + e_len[e] + 0.25:
					y = edge_y(e, arc - a0)
					break
			elev[i] = y
		_road_elev[r] = elev


## 道路折线逐顶点高程；无桥道路返回空数组（调用方回退路面高度）。
## 注意：Packed 数组是值语义，这里返回的是副本，调用方如需逐帧读取请自行缓存。
func road_elev_of(road: int) -> PackedFloat32Array:
	if road < 0 or road >= _road_elev.size():
		push_error("road_elev_of：道路索引越界 %d" % road)
		return PackedFloat32Array()
	var el = _road_elev[road]
	return el if el != null else PackedFloat32Array()


# ───────────────────────── 几何采样 ─────────────────────────

## 道路折线上的弧长采样（写出 x/z），返回该处切向角（atan2(dx, dz)）
func _road_point(road: int, arc: float, out: Dictionary) -> float:
	var start := _r_vert_start[road]
	var count := _r_vert_count[road]
	var acc := 0.0
	var px := float(_r_vert[start * 2]) / C.Q
	var pz := float(_r_vert[start * 2 + 1]) / C.Q
	if count < 2:
		out["x"] = px
		out["z"] = pz
		return 0.0
	for i in range(1, count):
		var qx := float(_r_vert[(start + i) * 2]) / C.Q
		var qz := float(_r_vert[(start + i) * 2 + 1]) / C.Q
		var seg := sqrt((qx - px) * (qx - px) + (qz - pz) * (qz - pz))
		if acc + seg >= arc:
			var t := (arc - acc) / seg if seg > 1e-6 else 0.0
			out["x"] = px + (qx - px) * t
			out["z"] = pz + (qz - pz) * t
			return atan2(qx - px, qz - pz) if seg > 1e-6 else 0.0
		acc += seg
		px = qx
		pz = qz
	out["x"] = px
	out["z"] = pz
	return 0.0


## 桥面高程：两端节点高程之间做 smoothstep 插值
func edge_y(edge: int, s: float) -> float:
	if edge < 0 or edge >= edge_count:
		push_error("edge_y：边索引越界 %d" % edge)
		return C.Y_ROAD
	var a := node_y[e_a[edge]]
	var b := node_y[e_b[edge]]
	if a == b:
		return a
	var t := clampf(s / maxf(1e-3, e_len[edge]), 0.0, 1.0)
	var st := t * t * (3.0 - 2.0 * t)
	return a + (b - a) * st


## 沿 A→B 方向、距起点 s 米的采样（写出 x/z/y/dx/dz；out 由调用方复用）
func sample_edge(edge: int, s: float, out: Dictionary) -> void:
	if edge < 0 or edge >= edge_count:
		push_error("sample_edge：边索引越界 %d" % edge)
		return
	var road := e_road[edge]
	var cs := clampf(s, 0.0, e_len[edge])
	var yaw := _road_point(road, e_arc[edge] + cs, out)
	out["y"] = edge_y(edge, cs)
	out["dx"] = sin(yaw)
	out["dz"] = cos(yaw)


## 边的折线点（x,z 交替），供交通车灯路径 / 地图绘制使用
func edge_polyline(edge: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if edge < 0 or edge >= edge_count:
		push_error("edge_polyline：边索引越界 %d" % edge)
		return out
	var road := e_road[edge]
	var start := _r_vert_start[road]
	var count := _r_vert_count[road]
	var arc0 := e_arc[edge]
	var arc1 := arc0 + e_len[edge]
	var acc := 0.0
	for i in count:
		var x := float(_r_vert[(start + i) * 2]) / C.Q
		var z := float(_r_vert[(start + i) * 2 + 1]) / C.Q
		if i > 0:
			if out.size() >= 2:
				var dx := x - out[out.size() - 2]
				var dz := z - out[out.size() - 1]
				acc += sqrt(dx * dx + dz * dz)
			else:
				# TS 版此处会读到空数组的 undefined → 累加变 NaN，后续区间比较恒 false，
				# 最终落到下面的兜底分支。这里显式写 NaN，保持同一语义且不越界报错。
				acc = NAN
		if acc >= arc0 and acc <= arc1:
			out.append(x)
			out.append(z)
	if out.size() < 2:
		var s := {"x": 0.0, "z": 0.0, "y": 0.0, "dx": 0.0, "dz": 0.0}
		sample_edge(edge, 0.0, s)
		out.append(s["x"])
		out.append(s["z"])
		sample_edge(edge, e_len[edge], s)
		out.append(s["x"])
		out.append(s["z"])
	return out


## 道路整体折线（x,z 交替，地图绘制用）
func road_polyline(road: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if road < 0 or road >= _r_vert_start.size():
		push_error("road_polyline：道路索引越界 %d" % road)
		return out
	var start := _r_vert_start[road]
	var count := _r_vert_count[road]
	out.resize(count * 2)
	for i in count:
		out[i * 2] = float(_r_vert[(start + i) * 2]) / C.Q
		out[i * 2 + 1] = float(_r_vert[(start + i) * 2 + 1]) / C.Q
	return out


func road_width(road: int) -> float:
	if road < 0 or road >= _r_width.size():
		push_error("road_width：道路索引越界 %d" % road)
		return 0.0
	return _r_width[road]


# ───────────────────────── 空间索引 / 查询 ─────────────────────────

func _key(cx: int, cz: int) -> int:
	return (cx + 4096) * 8192 + (cz + 4096)


func _build_grid() -> void:
	var s := {"x": 0.0, "z": 0.0, "y": 0.0, "dx": 0.0, "dz": 0.0}
	var acc: Dictionary = {}  # key → Array[edge]（构建期用引用语义的 Array，最后压缩）
	for e in edge_count:
		var len := e_len[e]
		var steps := maxi(1, ceili(len / 24.0))
		for i in range(steps + 1):
			var a0 := (float(i) / float(steps)) * len
			var a1 := minf(len, a0 + len / float(steps))
			sample_edge(e, (a0 + a1) * 0.5, s)
			var k := _key(floori(s["x"] / _CELL), floori(s["z"] / _CELL))
			if acc.has(k):
				var arr: Array = acc[k]
				arr.append(e)
			else:
				acc[k] = [e]
	for k in acc:
		_grid[k] = PackedInt32Array(acc[k])


## 最近边（投影到折线，返回 {edge, s, dist, dx, dz}；未命中返回空 Dictionary）
func closest_edge(x: float, z: float, max_radius: float = 320.0) -> Dictionary:
	var r := maxf(_CELL, max_radius)
	var c0x := floori((x - r) / _CELL)
	var c1x := floori((x + r) / _CELL)
	var c0z := floori((z - r) / _CELL)
	var c1z := floori((z + r) / _CELL)
	var best := {}
	var seen := {}
	for cx in range(c0x, c1x + 1):
		for cz in range(c0z, c1z + 1):
			var k := _key(cx, cz)
			if not _grid.has(k):
				continue
			var arr: PackedInt32Array = _grid[k]
			for e in arr:
				if seen.has(e):
					continue
				seen[e] = true
				var hit := project_edge(e, x, z)
				if not hit.is_empty() and (best.is_empty() or hit["dist"] < best["dist"]):
					best = hit
	return best


## 点到边的投影（沿折线精确；返回 {edge, s, dist, dx, dz}，未命中返回空 Dictionary）
func project_edge(edge: int, x: float, z: float) -> Dictionary:
	if edge < 0 or edge >= edge_count:
		push_error("project_edge：边索引越界 %d" % edge)
		return {}
	var road := e_road[edge]
	var start := _r_vert_start[road]
	var count := _r_vert_count[road]
	var arc0 := e_arc[edge]
	var len := e_len[edge]
	var acc := 0.0
	var best_dist := INF
	var best_s := 0.0
	var best_dx := 0.0
	var best_dz := 0.0
	for i in range(count - 1):
		var ax := float(_r_vert[(start + i) * 2]) / C.Q
		var az := float(_r_vert[(start + i) * 2 + 1]) / C.Q
		var bx := float(_r_vert[(start + i + 1) * 2]) / C.Q
		var bz := float(_r_vert[(start + i + 1) * 2 + 1]) / C.Q
		var dx := bx - ax
		var dz := bz - az
		var seg_len := sqrt(dx * dx + dz * dz)
		if seg_len < 1e-6:
			continue
		var seg_start := acc
		acc += seg_len
		if acc < arc0 or seg_start > arc0 + len:
			continue
		var t := clampf(((x - ax) * dx + (z - az) * dz) / (seg_len * seg_len), 0.0, 1.0)
		var px := ax + dx * t
		var pz := az + dz * t
		var d := sqrt((x - px) * (x - px) + (z - pz) * (z - pz))
		if d < best_dist:
			best_dist = d
			best_s = clampf(seg_start + t * seg_len - arc0, 0.0, len)
			best_dx = dx / seg_len
			best_dz = dz / seg_len
	if best_dist == INF:
		return {}
	return {"edge": edge, "s": best_s, "dist": best_dist, "dx": best_dx, "dz": best_dz}


func closest_node(x: float, z: float) -> int:
	var best := -1
	var best_d := INF
	var ce := closest_edge(x, z, 400.0)
	if not ce.is_empty():
		var a := e_a[ce["edge"]]
		var b := e_b[ce["edge"]]
		var da := sqrt((node_x[a] - x) * (node_x[a] - x) + (node_z[a] - z) * (node_z[a] - z))
		var db := sqrt((node_x[b] - x) * (node_x[b] - x) + (node_z[b] - z) * (node_z[b] - z))
		best = a if da < db else b
		best_d = minf(da, db)
		if best_d < 60.0:
			return best
	# 兜底：线性扫描（极少发生）
	for i in node_count:
		var d := sqrt((node_x[i] - x) * (node_x[i] - x) + (node_z[i] - z) * (node_z[i] - z))
		if d < best_d:
			best_d = d
			best = i
	return best


## 边的行进方向（从 from_node 出发）
func edge_yaw_from(edge: int, from_node: int) -> float:
	if edge < 0 or edge >= edge_count:
		push_error("edge_yaw_from：边索引越界 %d" % edge)
		return 0.0
	if from_node < 0 or from_node >= node_count:
		push_error("edge_yaw_from：节点索引越界 %d" % from_node)
		return 0.0
	var a := e_a[edge]
	var b := e_b[edge]
	var other := b if from_node == a else a
	return atan2(node_x[other] - node_x[from_node], node_z[other] - node_z[from_node])


## 是否允许从 from_node 沿此边行驶（考虑单行：bit0 置位时只能 A→B）
func can_traverse(edge: int, from_node: int) -> bool:
	if edge < 0 or edge >= edge_count:
		push_error("can_traverse：边索引越界 %d" % edge)
		return false
	if not (e_flags[edge] & 1):
		return true
	return e_a[edge] == from_node


# ───────────────────────── A* 寻路 ─────────────────────────

func _heap_push(node: int, cost: float) -> void:
	if _heap_size >= HEAP_CAP - 1:
		return
	var i := _heap_size
	_heap_size += 1
	_heap_node[i] = node
	_heap_cost[i] = cost
	while i > 0:
		var p := (i - 1) >> 1
		if _heap_cost[p] <= _heap_cost[i]:
			break
		var tn := _heap_node[p]
		var tc := _heap_cost[p]
		_heap_node[p] = _heap_node[i]
		_heap_cost[p] = _heap_cost[i]
		_heap_node[i] = tn
		_heap_cost[i] = tc
		i = p


func _heap_pop() -> int:
	var top := _heap_node[0]
	_heap_size -= 1
	if _heap_size > 0:
		_heap_node[0] = _heap_node[_heap_size]
		_heap_cost[0] = _heap_cost[_heap_size]
		var i := 0
		while true:
			var l := i * 2 + 1
			var rr := l + 1
			var m := i
			if l < _heap_size and _heap_cost[l] < _heap_cost[m]:
				m = l
			if rr < _heap_size and _heap_cost[rr] < _heap_cost[m]:
				m = rr
			if m == i:
				break
			var tn := _heap_node[m]
			var tc := _heap_cost[m]
			_heap_node[m] = _heap_node[i]
			_heap_cost[m] = _heap_cost[i]
			_heap_node[i] = tn
			_heap_cost[i] = tc
			i = m
	return top


func _ensure_search_buffers() -> void:
	# 用 stamp 记录「本次搜索是否写过」，所以 resize 保留旧值也无影响（与 TS 的惰性分配等价）
	if _g_score.size() != node_count:
		_g_score.resize(node_count)
		_f_score.resize(node_count)
		_came_from.resize(node_count)
		_visited.resize(node_count)
		_stamp.resize(node_count)


func _h(n: int, tx: float, tz: float) -> float:
	var dx := node_x[n] - tx
	var dz := node_z[n] - tz
	return sqrt(dx * dx + dz * dz)


## A*：返回节点序列（含起终点），无路可走返回空数组
func path(from_node: int, to_node: int, max_nodes: int = 12000) -> PackedInt32Array:
	var out := PackedInt32Array()
	if from_node < 0 or to_node < 0 or from_node >= node_count or to_node >= node_count:
		return out
	if from_node == to_node:
		out.append(from_node)
		return out
	_ensure_search_buffers()
	_stamp_id += 1
	var id := _stamp_id
	_heap_size = 0
	var tx := node_x[to_node]
	var tz := node_z[to_node]
	_g_score[from_node] = 0.0
	_f_score[from_node] = _h(from_node, tx, tz)
	_came_from[from_node] = -1
	_stamp[from_node] = id
	_visited[from_node] = 0
	_heap_push(from_node, _f_score[from_node])
	var expanded := 0
	while _heap_size > 0:
		var cur := _heap_pop()
		if _visited[cur] == 1 and _stamp[cur] == id:
			continue
		_visited[cur] = 1
		if cur == to_node:
			var result := PackedInt32Array()
			var n := cur
			while n >= 0:
				result.append(n)
				n = _came_from[n]
			result.reverse()
			return result
		expanded += 1
		if expanded > max_nodes:
			break
		var k_end := edge_off[cur + 1]
		for k in range(edge_off[cur], k_end):
			var e := edge_list[k]
			if not can_traverse(e, cur):
				continue
			var other := e_b[e] if e_a[e] == cur else e_a[e]
			var w := e_len[e] / maxf(3.0, e_speed[e])
			var tent := _g_score[cur] + w
			if _stamp[other] != id or tent < _g_score[other]:
				_stamp[other] = id
				_g_score[other] = tent
				_came_from[other] = cur
				_f_score[other] = tent + _h(other, tx, tz) * 1.0
				_visited[other] = 0
				_heap_push(other, _f_score[other])
	return out


## 把节点序列转成折线点（x,z 交替），供导航线与小地图使用
func path_points(nodes: PackedInt32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var s := {"x": 0.0, "z": 0.0, "y": 0.0, "dx": 0.0, "dz": 0.0}
	for i in range(nodes.size() - 1):
		var a := nodes[i]
		var b := nodes[i + 1]
		var edge := -1
		for k in range(edge_off[a], edge_off[a + 1]):
			var e := edge_list[k]
			if (e_a[e] == a and e_b[e] == b) or (e_a[e] == b and e_b[e] == a):
				edge = e
				break
		if edge < 0:
			out.append(node_x[a])
			out.append(node_z[a])
			continue
		var back := 1 if e_a[edge] == a else -1
		var len := e_len[edge]
		var steps := maxi(1, roundi(len / 30.0))
		for j in range(steps + 1):
			var arc := 0.0
			if back == 1:
				arc = (float(j) / float(steps)) * len
			else:
				arc = len - (float(j) / float(steps)) * len
			sample_edge(edge, arc, s)
			out.append(s["x"])
			out.append(s["z"])
	if nodes.size() > 0:
		out.append(node_x[nodes[nodes.size() - 1]])
		out.append(node_z[nodes[nodes.size() - 1]])
	return out


static func _to_i32(src: PackedInt64Array) -> PackedInt32Array:
	## u32 段在 city_bin 里用 64 位承载；这里值域都远小于 int32，压缩为 int32 提速
	var out := PackedInt32Array()
	out.resize(src.size())
	for i in src.size():
		out[i] = src[i]
	return out