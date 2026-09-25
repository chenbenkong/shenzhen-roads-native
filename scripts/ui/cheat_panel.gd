## 作弊菜单（破解版玩法）：无敌 / 引擎强化 / 通缉星级 / 时间 / 传送 / 统计
##
## 版式与设置面板保持一致（居中宽扁单页、深色玻璃 + 金边），V 键开关。
## 面板只改数据，效果由主循环与载具物理读取 —— 面板不直接碰玩法对象。
class_name CheatPanel
extends PanelContainer

signal invincible_toggled(on: bool)
signal boost_toggled(on: bool)
signal wanted_changed(level: int)
signal time_changed(t: float)
signal time_fast_toggled(on: bool)
signal teleport_requested(kind: String)
signal stats_reset
signal closed

const GOLD := Color(0.847, 0.635, 0.290)
const TEXT := Color(0.93, 0.94, 0.96)
const TEXT_DIM := Color(0.62, 0.66, 0.72)

var invincible := false
var boost := false
var wanted := -1
var time_of_day := 0.42
var time_fast := false

var _stats := {"odometer": 0.0, "top": 0.0, "crashes": 0, "escapes": 0}

var _inv_button: Button
var _boost_button: Button
var _wanted_buttons: Array = []
var _time_slider: HSlider
var _time_label: Label
var _fast_button: Button
var _stats_label: Label
var _ready_done := false


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.043, 0.052, 0.066, 0.96)
	panel.set_corner_radius_all(14)
	panel.set_border_width_all(1)
	panel.border_color = Color(0.85, 0.66, 0.32, 0.34)
	panel.content_margin_left = 30.0
	panel.content_margin_right = 30.0
	panel.content_margin_top = 22.0
	panel.content_margin_bottom = 22.0
	add_theme_stylebox_override("panel", panel)


func _ready() -> void:
	custom_minimum_size = Vector2(820.0, 0.0)
	_build()
	_ready_done = true


func _build() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	add_child(root)

	var head := HBoxContainer.new()
	head.add_child(_title("作弊菜单 · 破解版"))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	head.add_child(_dim("V 或 Esc 返回游戏"))
	root.add_child(head)
	root.add_child(_rule())

	# 开关
	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 12)
	r1.add_child(_label("车辆状态", 96.0))
	_inv_button = _toggle("车辆无敌（车损归零）")
	_inv_button.pressed.connect(_on_inv)
	r1.add_child(_inv_button)
	_boost_button = _toggle("引擎强化（加速 ×2.1 · 极速 ×1.55）")
	_boost_button.pressed.connect(_on_boost)
	r1.add_child(_boost_button)
	root.add_child(r1)

	# 通缉星级
	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 12)
	r2.add_child(_label("通缉星级", 96.0))
	for i in 6:
		var b := _small(str(i))
		b.pressed.connect(_on_wanted.bind(i))
		r2.add_child(b)
		_wanted_buttons.append(b)
	var back := _small("交还玩法")
	back.custom_minimum_size = Vector2(96.0, 34.0)
	back.pressed.connect(_on_wanted.bind(-1))
	r2.add_child(back)
	root.add_child(r2)

	# 时间
	var r3 := HBoxContainer.new()
	r3.add_theme_constant_override("separation", 12)
	r3.add_child(_label("时刻", 96.0))
	_time_slider = HSlider.new()
	_time_slider.min_value = 0.0
	_time_slider.max_value = 1.0
	_time_slider.step = 0.005
	_time_slider.value = time_of_day
	_time_slider.custom_minimum_size = Vector2(320.0, 26.0)
	_time_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_time_slider.focus_mode = Control.FOCUS_NONE
	_time_slider.value_changed.connect(_on_time)
	r3.add_child(_time_slider)
	_time_label = Label.new()
	_time_label.custom_minimum_size = Vector2(70.0, 0.0)
	_time_label.add_theme_font_size_override("font_size", 15)
	_time_label.add_theme_color_override("font_color", GOLD)
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	r3.add_child(_time_label)
	_fast_button = _toggle("时间快进")
	_fast_button.pressed.connect(_on_fast)
	r3.add_child(_fast_button)
	root.add_child(r3)

	# 传送
	var r4 := HBoxContainer.new()
	r4.add_theme_constant_override("separation", 12)
	r4.add_child(_label("传送", 96.0))
	for entry in [["spawn", "出生点"], ["sea", "海边"], ["center", "市中心"], ["sky", "高空"], ["ground", "落到地面"]]:
		var b := _small(entry[1])
		b.pressed.connect(func() -> void: teleport_requested.emit(entry[0]))
		r4.add_child(b)
	root.add_child(r4)

	root.add_child(_rule())

	# 统计 + 底部
	var r5 := HBoxContainer.new()
	r5.add_theme_constant_override("separation", 12)
	_stats_label = Label.new()
	_stats_label.add_theme_font_size_override("font_size", 14)
	_stats_label.add_theme_color_override("font_color", TEXT_DIM)
	r5.add_child(_stats_label)
	var sp2 := Control.new()
	sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r5.add_child(sp2)
	var reset := _small("重置统计")
	reset.pressed.connect(func() -> void: stats_reset.emit())
	r5.add_child(reset)
	var close := _small("关闭")
	close.custom_minimum_size = Vector2(96.0, 36.0)
	close.pressed.connect(func() -> void: closed.emit())
	r5.add_child(close)
	root.add_child(r5)

	_refresh()

# ============================================================================
# 构建小工具（与设置面板同一套观感）
# ============================================================================


func _title(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 23)
	l.add_theme_color_override("font_color", TEXT)
	return l


func _dim(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", TEXT_DIM)
	return l


func _label(text: String, width: float) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(width, 0.0)
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", TEXT)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _rule() -> HSeparator:
	var s := HSeparator.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.85, 0.66, 0.32, 0.18)
	sb.content_margin_top = 1.0
	s.add_theme_stylebox_override("separator", sb)
	return s


func _toggle(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0.0, 36.0)
	_style(b)
	return b


func _small(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(58.0, 34.0)
	_style(b)
	return b


func _style(b: Button) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(1, 1, 1, 0.05)
	normal.set_corner_radius_all(7)
	normal.set_border_width_all(1)
	normal.border_color = Color(1, 1, 1, 0.10)
	normal.content_margin_left = 14.0
	normal.content_margin_right = 14.0
	normal.content_margin_top = 7.0
	normal.content_margin_bottom = 7.0
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(1, 1, 1, 0.10)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.85, 0.66, 0.32, 0.22)
	pressed.border_color = Color(0.85, 0.66, 0.32, 0.75)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", normal)
	b.add_theme_stylebox_override("disabled", normal)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", GOLD)
	b.add_theme_font_size_override("font_size", 14)

# ============================================================================
# 交互
# ============================================================================


func _on_inv() -> void:
	invincible = _inv_button.button_pressed
	_refresh()
	invincible_toggled.emit(invincible)


func _on_boost() -> void:
	boost = _boost_button.button_pressed
	_refresh()
	boost_toggled.emit(boost)


func _on_wanted(level: int) -> void:
	wanted = level
	_refresh()
	wanted_changed.emit(level)


func _on_time(v: float) -> void:
	time_of_day = v
	_update_time_label()
	time_changed.emit(v)


func _on_fast() -> void:
	time_fast = _fast_button.button_pressed
	time_fast_toggled.emit(time_fast)


## 主循环每帧调用：同步实际时间与统计（时间可能被快进推动）
func sync_live(t: float, stats: Dictionary) -> void:
	if not _ready_done:
		return
	time_of_day = t
	if absf(_time_slider.value - t) > 0.0005:
		_time_slider.set_value_no_signal(t)
	_update_time_label()
	_stats = stats
	_update_stats()


func _update_time_label() -> void:
	var total := time_of_day * 24.0
	var hh := int(total)
	var mm := int((total - float(hh)) * 60.0)
	_time_label.text = "%02d:%02d" % [hh, mm]


func _update_stats() -> void:
	_stats_label.text = "里程 %.1f km · 最高速 %.0f km/h · 撞车 %d 次 · 逃脱通缉 %d 次" % [
		float(_stats.get("odometer", 0.0)) / 1000.0,
		float(_stats.get("top", 0.0)),
		int(_stats.get("crashes", 0)),
		int(_stats.get("escapes", 0)),
	]


func _refresh() -> void:
	if not _ready_done:
		return
	_inv_button.button_pressed = invincible
	_boost_button.button_pressed = boost
	_fast_button.button_pressed = time_fast
	for i in _wanted_buttons.size():
		var b: Button = _wanted_buttons[i]
		b.add_theme_color_override("font_color", GOLD if i == wanted else TEXT)
	_update_time_label()
	_update_stats()