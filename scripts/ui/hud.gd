## 游戏内 HUD：仪表 + 小地图 + 通知 + 大地图
##
## 设计基调：克制的深色玻璃面板 + 金色高光（与图标、标题同一套配色），
## 信息按「视线最近处最重要」排布：左下速度、右下地图、顶部左侧状态、底部中央通知。
##
## 全部用 Control._draw 自绘（不用一堆 Label），减少节点数也更好控制排版。
class_name Hud
extends Control

const GOLD := Color(0.847, 0.635, 0.290)
const INK := Color(0.055, 0.066, 0.082, 0.72)
const INK_SOLID := Color(0.045, 0.055, 0.070, 0.92)
const TEXT := Color(0.93, 0.94, 0.96)
const TEXT_DIM := Color(0.66, 0.69, 0.74, 0.9)
const LINE := Color(0.85, 0.66, 0.32, 0.5)

const MINIMAP_SIZE := 168.0
const MINIMAP_RANGE := 420.0  # 小地图覆盖的世界半径（米）

var map: CityMap
var show_map := false

# ── 由主循环每帧填充 ──
var mode_text := "驾驶"
var title := ""
var speed_kmh := 0.0
var speed_limit := 200.0
var gear_text := ""
var sub_text := ""
var health_ratio := 1.0
var notice := ""
var notice_alpha := 0.0
var px := 0.0
var pz := 0.0
var yaw := 0.0
var extra_hint := ""

var _font: Font
var _panel := StyleBoxFlat.new()
var _panel_solid := StyleBoxFlat.new()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font = get_theme_default_font()
	_panel.bg_color = INK
	_panel.set_corner_radius_all(10)
	_panel.border_width_left = 1
	_panel.border_width_right = 1
	_panel.border_width_top = 1
	_panel.border_width_bottom = 1
	_panel.border_color = Color(0.85, 0.66, 0.32, 0.18)
	_panel_solid.bg_color = INK_SOLID
	_panel_solid.set_corner_radius_all(12)
	_panel_solid.border_width_left = 1
	_panel_solid.border_width_right = 1
	_panel_solid.border_width_top = 1
	_panel_solid.border_width_bottom = 1
	_panel_solid.border_color = Color(0.85, 0.66, 0.32, 0.28)

# ============================================================================
# 绘制
# ============================================================================


func _draw() -> void:
	# 直接用视口尺寸而不是 Control.size：HUD 是纯绘制层，不参与容器布局，
	# 拿 size 有时会在第一帧为 0（元素全挤在左上角）。
	var vp := get_viewport_rect().size
	var w := vp.x
	var h := vp.y
	if show_map:
		_draw_big_map(w, h)
	_draw_speed(w, h)
	_draw_minimap(w, h)
	_draw_status(w, h)
	_draw_notice(w, h)


## 左下：速度 + 单位 + 档位
func _draw_speed(w: float, h: float) -> void:
	var box := Rect2(26.0, h - 148.0, 246.0, 122.0)
	draw_style_box(_panel, box)

	var label := "SPEED"
	draw_string(_font, Vector2(box.position.x + 18.0, box.position.y + 24.0), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, TEXT_DIM)
	draw_line(
		Vector2(box.position.x + 18.0, box.position.y + 32.0),
		Vector2(box.position.x + 74.0, box.position.y + 32.0),
		LINE, 1.0
	)

	var value := int(round(speed_kmh))
	var text := str(value)
	var big := 54
	var tw := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, big).x
	draw_string(_font, Vector2(box.position.x + 18.0, box.position.y + 86.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, big, TEXT)
	draw_string(_font, Vector2(box.position.x + 22.0 + tw, box.position.y + 86.0), "km/h",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, TEXT_DIM)

	# 档位 / 模式
	if gear_text != "":
		var gbox := Rect2(box.position.x + 176.0, box.position.y + 54.0, 52.0, 48.0)
		draw_style_box(_panel_solid, gbox)
		var gs := _font.get_string_size(gear_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
		draw_string(_font, Vector2(gbox.position.x + (52.0 - gs) * 0.5, gbox.position.y + 32.0),
			gear_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, GOLD)

	# 速度条（宽度随速度）
	var bar := Rect2(box.position.x + 18.0, box.position.y + 100.0, 210.0, 4.0)
	draw_rect(bar, Color(1, 1, 1, 0.09))
	var ratio := clampf(speed_kmh / maxf(1.0, speed_limit), 0.0, 1.0)
	draw_rect(Rect2(bar.position.x, bar.position.y, bar.size.x * ratio, bar.size.y), GOLD)


## 右下：小地图（圆角面板 + 地图取景 + 玩家箭头）
func _draw_minimap(w: float, h: float) -> void:
	var box := Rect2(w - MINIMAP_SIZE - 26.0, h - MINIMAP_SIZE - 26.0, MINIMAP_SIZE, MINIMAP_SIZE)
	draw_style_box(_panel_solid, box)
	if map != null and map.texture != null:
		var inner := box.grow(-6.0)
		var region := map.region_of(px, pz, MINIMAP_RANGE)
		# 取景越界时把区域夹回贴图内，避免出现空白边
		var max_px := float(CityMap.SIZE)
		region.position.x = clampf(region.position.x, 0.0, maxf(0.0, max_px - region.size.x))
		region.position.y = clampf(region.position.y, 0.0, maxf(0.0, max_px - region.size.y))
		draw_texture_rect_region(map.texture, inner, region)
		# 边框与十字准星
		draw_rect(inner, Color(0.85, 0.66, 0.32, 0.22), false, 1.0)
		var cx := box.position.x + box.size.x * 0.5
		var cy := box.position.y + box.size.y * 0.5
		draw_line(Vector2(cx - 7.0, cy), Vector2(cx + 7.0, cy), Color(1, 1, 1, 0.13), 1.0)
		draw_line(Vector2(cx, cy - 7.0), Vector2(cx, cy + 7.0), Color(1, 1, 1, 0.13), 1.0)
		# 玩家箭头（朝上为世界 -z，箭头按 yaw 旋转）
		_draw_arrow(Vector2(cx, cy), yaw)
	# 标注
	draw_string(_font, Vector2(box.position.x + 8.0, box.position.y - 8.0), "地图  M 放大",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, TEXT_DIM)


func _draw_arrow(center: Vector2, angle: float) -> void:
	# 世界 yaw：0 = 朝 +z（地图下方）；屏幕上 +z 向下 → 箭头初始朝下
	var dir := Vector2(sin(angle), cos(angle))
	var perp := Vector2(-dir.y, dir.x)
	var tip := center + dir * 9.0
	var a := center - dir * 5.0 + perp * 5.5
	var b := center - dir * 5.0 - perp * 5.5
	draw_colored_polygon(PackedVector2Array([tip, a, b]), GOLD)
	draw_polyline(PackedVector2Array([tip, a, b, tip]), Color(1, 1, 1, 0.55), 1.0)


## 左上：载具 / 模式 / 车损
func _draw_status(w: float, h: float) -> void:
	var box := Rect2(26.0, 22.0, 320.0, 74.0)
	draw_style_box(_panel, box)
	draw_string(_font, Vector2(box.position.x + 16.0, box.position.y + 27.0), mode_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, GOLD)
	draw_string(_font, Vector2(box.position.x + 16.0, box.position.y + 50.0), title,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 19, TEXT)
	if sub_text != "":
		draw_string(_font, Vector2(box.position.x + 16.0, box.position.y + 67.0), sub_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, TEXT_DIM)
	# 车损条
	var bar := Rect2(box.position.x + 232.0, box.position.y + 40.0, 72.0, 5.0)
	draw_rect(bar, Color(1, 1, 1, 0.1))
	var col := Color(0.42, 0.78, 0.52) if health_ratio > 0.6 else (
		Color(0.88, 0.72, 0.35) if health_ratio > 0.3 else Color(0.85, 0.35, 0.32)
	)
	draw_rect(Rect2(bar.position.x, bar.position.y, bar.size.x * clampf(health_ratio, 0.0, 1.0), bar.size.y), col)
	draw_string(_font, Vector2(box.position.x + 232.0, box.position.y + 30.0), "车况",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 10, TEXT_DIM)


## 底部中央：通知与操作提示
func _draw_notice(w: float, h: float) -> void:
	var y := h - 52.0
	if notice_alpha > 0.01 and notice != "":
		var tw := _font.get_string_size(notice, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
		var box := Rect2(w * 0.5 - tw * 0.5 - 18.0, y - 24.0, tw + 36.0, 34.0)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.05, 0.06, 0.075, 0.82 * notice_alpha)
		sb.set_corner_radius_all(8)
		sb.border_width_left = 1
		sb.border_width_right = 1
		sb.border_width_top = 1
		sb.border_width_bottom = 1
		sb.border_color = Color(0.85, 0.66, 0.32, 0.30 * notice_alpha)
		draw_style_box(sb, box)
		draw_string(_font, Vector2(box.position.x + 18.0, y), notice,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(TEXT.r, TEXT.g, TEXT.b, notice_alpha))
	if extra_hint != "":
		var hw := _font.get_string_size(extra_hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		draw_string(_font, Vector2(w * 0.5 - hw * 0.5, h - 14.0), extra_hint,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 0.65))


## 大地图（全屏）
func _draw_big_map(w: float, h: float) -> void:
	draw_rect(Rect2(0, 0, w, h), Color(0.02, 0.025, 0.032, 0.93))
	if map == null or map.texture == null:
		return
	var side := minf(w, h) - 96.0
	var box := Rect2((w - side) * 0.5, (h - side) * 0.5, side, side)
	draw_style_box(_panel_solid, box.grow(8.0))
	draw_texture_rect(map.texture, box, false)

	# 玩家位置
	var p := map.to_px(px, pz)
	var local := Vector2(
		box.position.x + p.x / float(CityMap.SIZE) * box.size.x,
		box.position.y + p.y / float(CityMap.SIZE) * box.size.y
	)
	_draw_arrow(local, yaw)
	draw_circle(local, 12.0, Color(0.85, 0.66, 0.32, 0.16))

	draw_string(_font, Vector2(box.position.x, box.position.y - 16.0), "深圳路网 · 全城",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, TEXT)
	draw_string(_font, Vector2(box.position.x, box.position.y + box.size.y + 30.0),
		"M 或 Esc 关闭        坐标 %.0f, %.0f" % [px, pz],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, TEXT_DIM)