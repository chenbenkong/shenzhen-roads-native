## 数据层自检 —— 构造 CityData，打印关键计数并跑通最近边 / 地表 / A* / 桥面高程 / 其余接口。
## 与 Web 版的校验脚本数字对照（建筑 15819 / 道路 12202 / 地面 2013 / 节点 17065 / 边 23135）。
##
## 运行方式（二选一，均不需改 main.tscn）：
##   godot --headless --path . -s res://scripts/test_data.gd
##   godot --headless --path . res://scenes/test_data.tscn
extends SceneTree

const BIN_PATH := "res://data/city.bin"
const META_PATH := "res://data/city-meta.json"
const SPAWN_X := -2804.5
const SPAWN_Z := -892.0


func _initialize() -> void:
	quit(run_all())


static func run_all() -> int:
	var t0 := Time.get_ticks_msec()
	var cd := CityData.load_from(BIN_PATH, META_PATH)
	if cd == null:
		push_error("CityData 构造失败")
		return 1
	var t1 := Time.get_ticks_msec()

	print("── CityData 构造 ──")
	print("耗时 %d ms" % (t1 - t0))
	print("建筑 %d 栋 / 道路 %d 条 / 地面 %d 块 / 节点 %d 个 / 边 %d 条" % [
		cd.building_count, cd.road_count, cd.ground_count, cd.graph.node_count, cd.graph.edge_count])

	# ── 最近边 + 地表 ──
	var ce := cd.graph.closest_edge(SPAWN_X, SPAWN_Z)
	if ce.is_empty():
		push_error("closest_edge 在出生点未命中")
		return 1
	var edge: int = ce["edge"]
	var road := cd.graph.e_road[edge]
	print("出生点最近边：edge=%d dist=%.2f m 道路=%d 宽=%.1f m" % [edge, ce["dist"], road, cd.graph.road_width(road)])
	var surf := cd.surface_at(SPAWN_X, SPAWN_Z)
	print("出生点地表：y=%.2f layer=%d" % [surf["y"], surf["layer"]])

	# ── A* ──
	var from_node := cd.graph.closest_node(SPAWN_X, SPAWN_Z)
	var to_node := cd.graph.closest_node(SPAWN_X + 3000.0, SPAWN_Z)
	var a0 := Time.get_ticks_msec()
	var nodes := cd.graph.path(from_node, to_node, 12000)
	var a1 := Time.get_ticks_msec()
	var pts := cd.graph.path_points(nodes)
	var total := 0.0
	for i in range(pts.size() / 2 - 1):
		var dx := pts[i * 2 + 2] - pts[i * 2]
		var dz := pts[i * 2 + 3] - pts[i * 2 + 1]
		total += sqrt(dx * dx + dz * dz)
	print("A*：节点 %d → %d，路径节点数 %d，折线点数 %d，总长度 %.1f m（耗时 %d ms）" % [
		from_node, to_node, nodes.size(), pts.size() / 2, total, a1 - a0])

	# ── 桥面高程 ──
	# 口径与 Web 版 scripts/_tmp-bridge-check.mjs 一致：
	#   桥面顶点 = y > 6.3（真正抬到桥面高度）；坡道顶点 = 0.5 < y <= 6.3
	var bridge_roads := 0
	var bridge_verts := 0
	var deck_verts := 0
	var ramp_verts := 0
	var max_elev := 0.0
	for r in cd.road_count:
		var el := cd.graph.road_elev_of(r)
		if el.size() > 0:
			bridge_roads += 1
			bridge_verts += el.size()
			for v in el:
				if v > 6.3:
					deck_verts += 1
				elif v > 0.5:
					ramp_verts += 1
				max_elev = maxf(max_elev, v)
	print("桥面高程：含桥道路 %d 条 / 桥面顶点 %d 个（坡道 %d，含桥道路共 %d 个顶点）/ 最高 %.2f m" % [
		bridge_roads, deck_verts, ramp_verts, bridge_verts, max_elev])

	# ── 其余接口冒烟（覆盖所有对外方法，确保无越界 / 无运行时错误）──
	var key := cd.chunk_key(SPAWN_X, SPAWN_Z)
	var coords := {}
	cd.chunk_key_coords(key, coords)
	var b_in := cd.buildings_in_chunk(key)
	var g_in := cd.ground_in_chunk(key)
	var segs := cd.road_segments_in_chunk(key)
	var out := {"x": SPAWN_X, "z": SPAWN_Z, "nx": 0.0, "nz": 0.0, "hit": false}
	var coll := cd.collide_circle(SPAWN_X, SPAWN_Z, 1.5, out)
	var rings := []
	var rc := cd.read_rings(0, rings)
	var tri := cd.poly_triangle(0, 0)
	var samp := {"x": 0.0, "z": 0.0, "y": 0.0, "dx": 0.0, "dz": 0.0}
	cd.graph.sample_edge(edge, 0.0, samp)
	var proj := cd.graph.project_edge(edge, SPAWN_X, SPAWN_Z)
	var ep := cd.graph.edge_polyline(edge)
	var rp := cd.graph.road_polyline(road)
	var yaw := cd.graph.edge_yaw_from(edge, cd.graph.e_a[edge])
	var trav_fwd := cd.graph.can_traverse(edge, cd.graph.e_a[edge])
	print("冒烟：chunk(%d,%d) 建筑 %d / 地面 %d / 道路 %d；blocked=%s collide=%s(pen=%.2f)；建筑0 圈 %d；地面0 三角0 %s；layer=%d tricount=%d；路折线 %d 点 / 边折线 %d 点；sample y=%.2f；投影 s=%.1f dist=%.2f；可通行=%s yaw=%.2f；道路顶点 %d" % [
		coords["cx"], coords["cz"], b_in.size(), g_in.size(), segs.size(),
		cd.blocked_at(SPAWN_X, SPAWN_Z, 0.0), coll, out["x"] - SPAWN_X,
		rc, "OK" if tri.size() == 6 else "异常", cd.ground_layer(0), cd.ground_tri_count(0),
		rp.size() / 2, ep.size() / 2, samp["y"], proj["s"], proj["dist"], trav_fwd, yaw,
		cd.road_vert_count(road)])

	# ── 记录式小节逐字段解码抽查（bmeta 20B / rmeta 16B 最容易写错）──
	print("建筑0：height=%.1f 外圈顶点=%d style=%d roofLayer=%d podium=%d seed=%d facadeLayer=%d centroid=(%.3f,%.3f)" % [
		cd.b_height[0], rings[0].size() / 2, cd.b_style[0], cd.b_roof_layer[0],
		cd.b_podium[0], cd.b_seed[0], cd.b_facade_layer[0], cd.b_cx[0], cd.b_cz[0]])
	print("道路%d：kind=%d 宽=%.1f 车道=%d flags=%d grade=%d nameIdx=%d 顶点=%d 名=%s" % [
		road, cd.r_kind[road], cd.r_width[road], cd.r_lanes[road], cd.r_flags[road],
		cd.r_grade[road], cd.r_name_idx[road], cd.road_vert_count(road), _road_name(cd, road)])

	# ── 预期值核对 ──
	print("── 预期值核对 ──")
	var fail := 0
	fail += _check("建筑数", cd.building_count, 15819)
	fail += _check("道路数", cd.road_count, 12202)
	fail += _check("地面块数", cd.ground_count, 2013)
	fail += _check("节点数", cd.graph.node_count, 17065)
	fail += _check("边数", cd.graph.edge_count, 23135)
	fail += _check("含桥道路数", bridge_roads, 730)
	fail += _check("桥面顶点数", deck_verts, 544)
	fail += _check("坡道顶点数", ramp_verts, 436)
	fail += _check("最高高程×100", roundi(max_elev * 100.0), 650)
	if fail > 0:
		push_error("自检失败：%d 项与预期不符" % fail)
		return 1
	print("自检通过：全部计数与预期一致")
	print("总耗时 %d ms" % (Time.get_ticks_msec() - t0))
	return 0


static func _check(name: String, got: int, want: int) -> int:
	var ok := got == want
	print("  %-10s 实际 %-8d 预期 %-8d %s" % [name, got, want, "OK" if ok else "不符!"])
	return 0 if ok else 1


static func _road_name(cd: CityData, road: int) -> String:
	var idx := cd.r_name_idx[road]
	if idx == 0xffff or idx >= cd.r_name.size():
		return "(无名)"
	return cd.r_name[idx]