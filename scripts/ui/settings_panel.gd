## 设置面板：画质档位 / 音量 / 鼠标灵敏度 / 调试信息
##
## 版式：宽扁单页（一屏放下，不滚动），深色玻璃底 + 金边，与 HUD 同一套视觉语言。
## 所有控件用 Godot 内置控件 + 自定义 StyleBox，避免自绘带来的焦点与可访问性问题。
class_name SettingsPanel
extends PanelContainer

signal quality_changed(index: int)
signal volume_changed(value: float)
signal sensitivity_changed(value: float)
signal debug_toggled(on: bool)
signal closed

## 四档画质：视距 / 3D 渲染分辨率缩放 / 交通与行人上限
const QUALITY_NAMES := ["流畅", "均衡", "高清", "极致"]
const QUALITY_LOD := [520.0, 780.0, 1050.0, 1400.0]
const QUALITY_SCALE := [0.60, 0.78, 0.92, 1.0]
const QUALITY_TRAFFIC := [32, 48, 64, 80]
const QUALITY_PEDS := [40, 64, 96, 128]

const GOLD := Color(0.847, 0.635, 0.290)
const TEXT := Color(0.93, 0.94, 0.96)
const TEXT_DIM := Color(0.62, 0.66, 0.72)

var quality := 1
var volume := 0.8
var sensitivity := 1.0
var debug_info := false

var _quality_buttons: Array = []
var _volume_slider: HSlider
var _volume_label: Label
var _sens_slider: HSlider
var _sens_label: Label
var _debug_button: Button
var _desc_label: Label


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 面板本体样式
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.043, 0.052, 0.066, 0.96)
	panel.set_corner_radius_all(14)
	panel.set_border_width_all(1)
	panel.border_color = Color(0.85, 0.66, 0.32, 0.30)
	panel.content_margin_left = 30.0
	panel.content_margin_right = 30.0
	panel.content_margin_top = 22.0
	panel.content_margin_bottom = 22.0
	add_theme_stylebox_override("panel", panel)


func _ready() -> void:
	# 尺寸交给外层 CenterContainer 居中（面板不要在 _ready 里动锚点，
	# 那样会和容器的布局计算打架，导致跑到左上角、内容挤成一团）
	custom_minimum_size = Vector2(760.0, 0.0)
	_build()


func _build() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 16)
	add_child(root)

	# ── 标题 ──
	var head := HBoxContainer.new()
	var title := Label.new()
	title.text = "设置"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", TEXT)
	head.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	var hint := Label.new()
	hint.text = "Esc 或 关闭 返回游戏"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", TEXT_DIM)
	head.add_child(hint)
	root.add_child(head)
	root.add_child(_rule())

	# ── 画质档位（宽扁一行）──
	var qrow := HBoxContainer.new()
	qrow.add_theme_constant_override("separation", 12)
	qrow.add_child(_label("画质档位", 96.0))
	for i in QUALITY_NAMES.size():
		var b := Button.new()
		b.text = QUALITY_NAMES[i]
		b.custom_minimum_size = Vector2(104.0, 40.0)
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		_style_button(b)
		b.pressed.connect(_on_quality.bind(i))
		qrow.add_child(b)
		_quality_buttons.append(b)
	root.add_child(qrow)

	# ── 音量 ──
	var vrow := HBoxContainer.new()
	vrow.add_theme_constant_override("separation", 12)
	vrow.add_child(_label("音量", 96.0))
	_volume_slider = _slider(0.0, 1.0, 0.01, volume)
	_volume_slider.value_changed.connect(_on_volume)
	vrow.add_child(_volume_slider)
	_volume_label = _value_label("%d%%" % int(volume * 100.0))
	vrow.add_child(_volume_label)
	root.add_child(vrow)

	# ── 鼠标灵敏度 ──
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 12)
	srow.add_child(_label("视角灵敏度", 96.0))
	_sens_slider = _slider(0.3, 2.5, 0.05, sensitivity)
	_sens_slider.value_changed.connect(_on_sensitivity)
	srow.add_child(_sens_slider)
	_sens_label = _value_label("%.2f×" % sensitivity)
	srow.add_child(_sens_label)
	root.add_child(srow)

	# ── 调试信息 ──
	var drow := HBoxContainer.new()
	drow.add_theme_constant_override("separation", 12)
	drow.add_child(_label("调试信息", 96.0))
	_debug_button = Button.new()
	_debug_button.text = "F3 开关（帧率 / draw call / 三角数）"
	_debug_button.toggle_mode = true
	_debug_button.focus_mode = Control.FOCUS_NONE
	_debug_button.custom_minimum_size = Vector2(280.0, 36.0)
	_style_button(_debug_button)
	_debug_button.pressed.connect(_on_debug)
	drow.add_child(_debug_button)
	root.add_child(drow)

	root.add_child(_rule())

	# ── 说明 + 关闭 ──
	var frow := HBoxContainer.new()
	_desc_label = Label.new()
	_desc_label.add_theme_font_size_override("font_size", 13)
	_desc_label.add_theme_color_override("font_color", TEXT_DIM)
	frow.add_child(_desc_label)
	var sp2 := Control.new()
	sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frow.add_child(sp2)
	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(120.0, 40.0)
	close.focus_mode = Control.FOCUS_NONE
	_style_button(close)
	close.pressed.connect(func() -> void: closed.emit())
	frow.add_child(close)
	root.add_child(frow)

	_refresh()


func _rule() -> HSeparator:
	var s := HSeparator.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.85, 0.66, 0.32, 0.18)
	sb.content_margin_top = 1.0
	sb.content_margin_bottom = 0.0
	s.add_theme_stylebox_override("separator", sb)
	return s


func _label(text: String, width: float) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(width, 0.0)
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", TEXT)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _value_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(86.0, 0.0)
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", GOLD)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _slider(minv: float, maxv: float, step: float, value: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = minv
	s.max_value = maxv
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(320.0, 28.0)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.focus_mode = Control.FOCUS_NONE
	return s


## 按钮样式：默认深色玻璃，选中/按下为金色描边 + 淡金底
func _style_button(b: Button) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(1, 1, 1, 0.05)
	normal.set_corner_radius_all(7)
	normal.set_border_width_all(1)
	normal.border_color = Color(1, 1, 1, 0.10)
	normal.content_margin_left = 14.0
	normal.content_margin_right = 14.0
	normal.content_margin_top = 8.0
	normal.content_margin_bottom = 8.0

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(1, 1, 1, 0.10)

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.85, 0.66, 0.32, 0.22)
	pressed.border_color = Color(0.85, 0.66, 0.32, 0.75)

	var focus := normal.duplicate() as StyleBoxFlat
	focus.border_color = Color(0.85, 0.66, 0.32, 0.55)

	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", focus)
	b.add_theme_stylebox_override("disabled", normal)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_pressed_color", GOLD)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_font_size_override("font_size", 15)

# ============================================================================
# 交互
# ============================================================================


func _on_quality(index: int) -> void:
	quality = index
	_refresh()
	quality_changed.emit(index)


func _on_volume(v: float) -> void:
	volume = v
	_volume_label.text = "%d%%" % int(v * 100.0)
	volume_changed.emit(v)


func _on_sensitivity(v: float) -> void:
	sensitivity = v
	_sens_label.text = "%.2f×" % v
	sensitivity_changed.emit(v)


func _on_debug() -> void:
	debug_info = _debug_button.button_pressed
	debug_toggled.emit(debug_info)


func _refresh() -> void:
	for i in _quality_buttons.size():
		var b: Button = _quality_buttons[i]
		b.button_pressed = i == quality
		b.add_theme_color_override("font_color", GOLD if i == quality else TEXT)
	_desc_label.text = "%s：视距 %.0f m · 渲染分辨率 %d%%%s · 车流 %d 辆 · 行人 %d 人" % [
		QUALITY_NAMES[quality], QUALITY_LOD[quality],
		int(QUALITY_SCALE[quality] * 100.0),
		"（FSR 上采样）" if QUALITY_SCALE[quality] < 0.999 else "",
		QUALITY_TRAFFIC[quality], QUALITY_PEDS[quality]
	]


## 供 main 读取当前档位对应的参数
func lod_distance() -> float:
	return QUALITY_LOD[quality]


func render_scale() -> float:
	return QUALITY_SCALE[quality]


func traffic_cap() -> int:
	return QUALITY_TRAFFIC[quality]


func ped_cap() -> int:
	return QUALITY_PEDS[quality]