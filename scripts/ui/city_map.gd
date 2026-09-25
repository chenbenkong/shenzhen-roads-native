## 城市地图烘焙：把路网 / 水域 / 绿地一次性画成一张贴图，供小地图与大地图共用
##
## 做法：把绘制放进一个 2048×2048 的 SubViewport，用 CanvasItem 的绘制 API 让 GPU 光栅化，
## 渲染一帧后取回 ImageTexture。比在 GDScript 里逐像素画线快两个数量级，
## 而且 draw_line 自带抗锯齿，道路边缘干净。
##
## 坐标约定：世界 (x, z) → 贴图 (u, v)，两者同向；地图「上」= 世界 -z（与游戏内视角一致）。
class_name CityMap
extends RefCounted

const SIZE := 2048
const MARGIN := 300.0  # 世界范围外扩（米），避免城市贴边

# 低调的城市图配色：深底、灰路、暗蓝水、暗绿绿地
const C_BG := Color(0.050, 0.057, 0.068)
const C_WATER := Color(0.055, 0.120, 0.155)
const C_GRASS := Color(0.072, 0.112, 0.078)
const C_ROAD_MINOR := Color(0.235, 0.250, 0.275)
const C_ROAD_MID := Color(0.46, 0.48, 0.51)
const C_ROAD_MAJOR := Color(0.66, 0.68, 0.70)
const C_ROAD_HIGH := Color(0.82, 0.72, 0.46)

var texture: ImageTexture
var min_x := 0.0
var min_z := 0.0
var scale := 1.0
var span_x := 1.0
var span_z := 1.0


## 异步烘焙（需要渲染设备，headless 下不可用）
static func bake(tree: SceneTree, data: CityData) -> CityMap:
	var t0 := Time.get_ticks_msec()
	var m := CityMap.new()
	m._compute_bounds(data)

	var vp := SubViewport.new()
	vp.size = Vector2i(SIZE, SIZE)
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var painter := _Painter.new()
	painter.data = data
	painter.map = m
	vp.add_child(painter)
	# 用 call_deferred：烘焙常在 _ready 期间被调用，那时父节点正在装配子节点，直接 add_child 会失败
	tree.root.add_child.call_deferred(vp)

	# 等两帧：第一帧执行 _draw，第二帧保证渲染目标已就绪
	await tree.process_frame
	await tree.process_frame

	var img := vp.get_texture().get_image()
	if img == null:
		push_error("地图烘焙失败：无法取回渲染目标")
	else:
		m.texture = ImageTexture.create_from_image(img)
	vp.queue_free()
	print("[地图] 烘焙完成 %d ms（范围 %.0f×%.0f m，比例 %.4f px/m）" % [
		Time.get_ticks_msec() - t0, m.span_x, m.span_z, m.scale
	])
	return m


func _compute_bounds(data: CityData) -> void:
	var ext: Array = data.meta.get("extent", [])
	if ext.size() >= 4:
		min_x = float(ext[0])
		min_z = float(ext[1])
		span_x = float(ext[2]) - min_x
		span_z = float(ext[3]) - min_z
	else:
		min_x = 1e9
		min_z = 1e9
		var max_x := -1e9
		var max_z := -1e9
		for r in data.road_count:
			var n := data.road_vert_count(r)
			for i in n:
				var p := data.road_point(r, i)
				min_x = minf(min_x, p.x)
				max_x = maxf(max_x, p.x)
				min_z = minf(min_z, p.y)
				max_z = maxf(max_z, p.y)
		span_x = max_x - min_x
		span_z = max_z - min_z
	min_x -= MARGIN
	min_z -= MARGIN
	span_x += MARGIN * 2.0
	span_z += MARGIN * 2.0
	scale = float(SIZE) / maxf(span_x, span_z)


## 世界 → 贴图像素
func to_px(x: float, z: float) -> Vector2:
	return Vector2((x - min_x) * scale, (z - min_z) * scale)


## 贴图像素 → 世界
func to_world(px: float, py: float) -> Vector2:
	return Vector2(min_x + px / scale, min_z + py / scale)


## 取一小块区域的 UV（给 Control 用 draw_texture_rect_region）
func region_of(cx: float, cz: float, half_extent_m: float) -> Rect2:
	var c := to_px(cx, cz)
	var half := half_extent_m * scale
	return Rect2(c.x - half, c.y - half, half * 2.0, half * 2.0)

# ============================================================================
# 绘制器（GPU 光栅化）
# ============================================================================


class _Painter:
	extends Node2D
	var data: CityData
	var map: CityMap

	func _draw() -> void:
		draw_rect(Rect2(0, 0, CityMap.SIZE, CityMap.SIZE), CityMap.C_BG)
		_paint_areas()
		_paint_roads()

	func _paint_areas() -> void:
		var pts := PackedVector2Array()
		pts.resize(3)
		for poly in data.ground_count:
			var layer := data.ground_layer(poly)
			if layer == 0:
				continue  # 普通陆地与底色一致，不画
			var col := CityMap.C_WATER if layer == 2 else CityMap.C_GRASS
			var tc := data.ground_tri_count(poly)
			for t in tc:
				var tri := data.poly_triangle(poly, t)
				var a := map.to_px(tri[0], tri[1])
				var b := map.to_px(tri[2], tri[3])
				var c := map.to_px(tri[4], tri[5])
				# 退化三角形（三点共线或亚像素面积）会让 draw_colored_polygon 报错，先按面积过滤
				var cross := (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
				if absf(cross) < 0.45:
					continue
				pts[0] = a
				pts[1] = b
				pts[2] = c
				draw_colored_polygon(pts, col)

	func _paint_roads() -> void:
		# 分桶后从低等级画到高等级，让主干道压在支路之上
		var buckets: Array = [[], [], [], [], []]
		for r in data.road_count:
			var k: int = clampi(data.r_kind[r], 0, 4)
			buckets[k].append(r)
		for k in [1, 4, 2, 3, 0]:
			var list: Array = buckets[k]
			var w := 1.2
			var col := CityMap.C_ROAD_MINOR
			match k:
				0:
					w = 5.5
					col = CityMap.C_ROAD_HIGH
				3:
					w = 4.0
					col = CityMap.C_ROAD_MAJOR
				2:
					w = 2.6
					col = CityMap.C_ROAD_MID
				4:
					w = 1.8
					col = CityMap.C_ROAD_MINOR.lightened(0.18)
			for r in list:
				var n := data.road_vert_count(int(r))
				if n < 2:
					continue
				var prev := data.road_point(int(r), 0)
				var a := map.to_px(prev.x, prev.y)
				for i in range(1, n):
					var cur := data.road_point(int(r), i)
					var b := map.to_px(cur.x, cur.y)
					draw_line(a, b, col, w, true)
					a = b