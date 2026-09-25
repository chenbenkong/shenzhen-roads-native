## 输入：按物理键位轮询（不依赖 InputMap，避免工程配置四处漂移）
## 每帧先 poll()，之后用 just()/down()/axis() 查询；滚轮由外部把事件转发进 feed()。
class_name GameInput
extends RefCounted

## 参与轮询的键位集合（只查这些，避免遍历全部键盘）
const KEYS := [
	KEY_W, KEY_A, KEY_S, KEY_D,
	KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
	KEY_SPACE, KEY_SHIFT, KEY_CTRL,
	KEY_C, KEY_F, KEY_R, KEY_H, KEY_M, KEY_T, KEY_B, KEY_G,
	KEY_E, KEY_Q, KEY_ENTER, KEY_ESCAPE, KEY_TAB, KEY_P, KEY_O, KEY_V,
]

var mouse_dx := 0.0
var mouse_dy := 0.0
var mouse_captured := false

var _down := {}
var _just := {}
var _prev_mouse := Vector2.ZERO
var _wheel := 0


func poll() -> void:
	_just.clear()
	for code in KEYS:
		var c: int = code
		var now := Input.is_physical_key_pressed(c)
		if now and not _down.get(c, false):
			_just[c] = true
		_down[c] = now

	if mouse_captured:
		var pos := DisplayServer.mouse_get_position()
		if _prev_mouse != Vector2.ZERO:
			mouse_dx = pos.x - _prev_mouse.x
			mouse_dy = pos.y - _prev_mouse.y
		else:
			mouse_dx = 0.0
			mouse_dy = 0.0
		_prev_mouse = pos
	else:
		_prev_mouse = Vector2.ZERO
		mouse_dx = 0.0
		mouse_dy = 0.0


## 滚轮：main 的 _input 把事件转发进来
func feed(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_wheel -= 1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_wheel += 1


## 取走本帧累积的滚轮量并清零
func take_wheel() -> float:
	var v := float(_wheel)
	_wheel = 0
	return v


## 本帧刚按下
func just(code: int) -> bool:
	return _just.get(code, false)


## 当前按住
func down(code: int) -> bool:
	return _down.get(code, false)


## 轴值：-1（neg 按下）… +1（pos 按下）
func axis(neg: int, pos: int) -> float:
	return (1.0 if down(pos) else 0.0) - (1.0 if down(neg) else 0.0)


func set_mouse_captured(on: bool) -> void:
	mouse_captured = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE
	_prev_mouse = Vector2.ZERO