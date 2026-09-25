## 程序化城市纹理图集（原生版）
## ---------------------------------------------------------------------------
## 与 Web 版 atlas.ts 视觉设计一致，但改为直接在 PackedByteArray 上光栅化
## （Godot 没有 Canvas2D，浏览器那套绘图 API 不可用）。
##
## 关键约定：
##  - 每层 128×128，共 18 层，按 C.L 枚举顺序生成 → 组成 Texture2DArray。
##  - 固定种子伪随机，每次生成结果一致。
##  - 所有图案在 tile 边界环绕绘制（rect/vline/hline 内部自动取模），无接缝。
##  - alpha 通道语义：
##      立面 0..7 → 夜间窗光掩码（亮窗 255，其余 0；RGB 保留 albedo）
##      树冠 16   → 叶簇掩码（配合 alphaTest）
##      光晕 17   → 径向衰减
##      其余      → 255
##  - 风格：低饱和、偏灰调的风格化写实（城市灰）。
class_name Atlas
extends RefCounted

const SIZE := 128
const SEED := 0x1F2E3D4C
const LAYER_COUNT := 18

# 画布：RGBA8，长度 SIZE*SIZE*4
var px := PackedByteArray()
var _rs := 0  # 伪随机状态


func _init() -> void:
	px.resize(SIZE * SIZE * 4)


## 生成全部图集，返回 18 张 Image（FORMAT_RGBA8）
func build() -> Array:
	var layers: Array = []
	for layer in LAYER_COUNT:
		seed(SEED + layer * 0x9E3779B1)
		_draw_layer(layer)
		var img := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, px.duplicate())
		# mipmap 必须在 Image 上生成（Texture2DArray 自身没有 generate_mipmaps）
		img.generate_mipmaps()
		layers.append(img)
	return layers


func _draw_layer(layer: int) -> void:
	match layer:
		C.L.FACADE_RESIDENTIAL: _facade_residential()
		C.L.FACADE_OFFICE: _facade_office()
		C.L.FACADE_COMMERCIAL: _facade_commercial()
		C.L.FACADE_PODIUM: _facade_podium()
		C.L.FACADE_BRICK: _facade_brick()
		C.L.FACADE_GLASS: _facade_glass()
		C.L.FACADE_TILE: _facade_tile()
		C.L.FACADE_CONCRETE: _facade_concrete()
		C.L.ROOF_A: _roof_a()
		C.L.ROOF_B: _roof_b()
		C.L.ROOF_C: _roof_c()
		C.L.PAVEMENT: _pavement()
		C.L.GRASS: _grass()
		C.L.WATER: _water()
		C.L.ASPHALT: _asphalt()
		C.L.MARKING: _marking()
		C.L.CANOPY: _canopy()
		C.L.GLOW: _glow()

# ============================================================================
# 伪随机与颜色工具
# ============================================================================


## mulberry32：固定种子，保证图集每次生成一致
func seed(s: int) -> void:
	_rs = s & 0xFFFFFFFF


func rnd() -> float:
	_rs = (_rs + 0x6D2B79F5) & 0xFFFFFFFF
	var t := _rs
	t = (t ^ (t >> 15)) * (t | 1) & 0xFFFFFFFF
	t = (t ^ (t + (t ^ (t >> 7)) * (t | 61) & 0xFFFFFFFF)) & 0xFFFFFFFF
	return float((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0


func rndi(n: int) -> int:
	return int(rnd() * n) % maxi(1, n)


## amt > 0 向白提亮，amt < 0 整体压暗
static func shade(c: Color, amt: float) -> Color:
	if amt >= 0.0:
		return Color(c.r + (1.0 - c.r) * amt, c.g + (1.0 - c.g) * amt, c.b + (1.0 - c.b) * amt, c.a)
	var k := 1.0 + amt
	return Color(c.r * k, c.g * k, c.b * k, c.a)


## 灰度抖动，制造斑驳感
func tint(c: Color, amount: float) -> Color:
	var d := (rnd() * 2.0 - 1.0) * amount
	return Color(c.r + d, c.g + d, c.b + d, c.a)


static func rgb(r: int, g: int, b: int) -> Color:
	return Color8(r, g, b)


static func rgba(r: int, g: int, b: int, a: float) -> Color:
	var c := Color8(r, g, b)
	c.a = a
	return c

# ============================================================================
# 光栅化原语（全部支持 tile 环绕）
# ============================================================================


## 单像素 source-over 混合（alpha 为 0 直接跳过，省一半时间）
func _blend(o: int, c: Color) -> void:
	var a := c.a
	if a <= 0.003:
		return
	if a >= 0.997:
		px[o] = int(c.r * 255.0)
		px[o + 1] = int(c.g * 255.0)
		px[o + 2] = int(c.b * 255.0)
		px[o + 3] = 255
		return
	var ia := 1.0 - a
	px[o] = int(px[o] * ia + c.r * 255.0 * a)
	px[o + 1] = int(px[o + 1] * ia + c.g * 255.0 * a)
	px[o + 2] = int(px[o + 2] * ia + c.b * 255.0 * a)
	px[o + 3] = maxi(px[o + 3], int(a * 255.0))


func clear() -> void:
	px.fill(0)


func fill(c: Color) -> void:
	rect(0, 0, SIZE, SIZE, c)


## 矩形填充（自动环绕；坐标可为负、可超出）
func rect(x: int, y: int, w: int, h: int, c: Color) -> void:
	if w <= 0 or h <= 0:
		return
	for yy in range(y, y + h):
		var ry := yy % SIZE
		if ry < 0:
			ry += SIZE
		var row := ry * SIZE * 4
		for xx in range(x, x + w):
			var rx := xx % SIZE
			if rx < 0:
				rx += SIZE
			_blend(row + rx * 4, c)


## 竖线（以 x 为中线，thick 为宽度）
func vline(x: int, y: int, h: int, thick: int, c: Color) -> void:
	rect(x - thick / 2, y, maxi(1, thick), h, c)


## 横线（以 y 为中线）
func hline(y: int, x: int, w: int, thick: int, c: Color) -> void:
	rect(x, y - thick / 2, w, maxi(1, thick), c)


## 竖向线性渐变（top → bottom），带中间色
func vgrad(x: int, y: int, w: int, h: int, top: Color, mid: Color, bottom: Color) -> void:
	if w <= 0 or h <= 0:
		return
	for i in h:
		var f := float(i) / maxf(1.0, float(h - 1))
		var c: Color
		if f < 0.55:
			c = top.lerp(mid, f / 0.55)
		else:
			c = mid.lerp(bottom, (f - 0.55) / 0.45)
		rect(x, y + i, w, 1, c)


## 径向渐变（中心 c0 → 边缘 c1）
func rgrad(cx: float, cy: float, r: float, c0: Color, c1: Color) -> void:
	if r <= 0.0:
		return
	var r2 := r * r
	var x0 := int(floor(cx - r))
	var x1 := int(ceil(cx + r))
	var y0 := int(floor(cy - r))
	var y1 := int(ceil(cy + r))
	for yy in range(y0, y1):
		var ry := yy % SIZE
		if ry < 0:
			ry += SIZE
		var dy := float(yy) + 0.5 - cy
		var row := ry * SIZE * 4
		for xx in range(x0, x1):
			var dx := float(xx) + 0.5 - cx
			var d2 := dx * dx + dy * dy
			if d2 > r2:
				continue
			var f := sqrt(d2 / r2)
			var col := c0.lerp(c1, f)
			var rx := xx % SIZE
			if rx < 0:
				rx += SIZE
			_blend(row + rx * 4, col)


## 实心圆（叶隙、风机等）
func disc(cx: float, cy: float, r: float, c: Color) -> void:
	if r <= 0.0:
		return
	var r2 := r * r
	for yy in range(int(floor(cy - r)), int(ceil(cy + r))):
		var ry := yy % SIZE
		if ry < 0:
			ry += SIZE
		var dy := float(yy) + 0.5 - cy
		var row := ry * SIZE * 4
		for xx in range(int(floor(cx - r)), int(ceil(cx + r))):
			var dx := float(xx) + 0.5 - cx
			if dx * dx + dy * dy > r2:
				continue
			var rx := xx % SIZE
			if rx < 0:
				rx += SIZE
			_blend(row + rx * 4, c)


## 颗粒噪声 / 污渍斑块
func noise(count: int, min_size: float, max_size: float, colors: Array, a_min: float, a_max: float) -> void:
	for i in count:
		var s := int(min_size + rnd() * (max_size - min_size))
		var x := int(rnd() * SIZE)
		var y := int(rnd() * SIZE)
		var c: Color = colors[rndi(colors.size())]
		var col := c
		col.a = a_min + rnd() * (a_max - a_min)
		rect(x, y, maxi(1, s), maxi(1, s), col)


## 立面 alpha 掩码：整层 alpha 归零，仅亮窗矩形处置 255（RGB 完整保留）
func mask_alpha(lit: Array) -> void:
	for i in range(3, px.size(), 4):
		px[i] = 0
	for r: Rect2i in lit:
		for yy in range(maxi(0, r.position.y), mini(SIZE, r.position.y + r.size.y)):
			var o := (yy * SIZE + maxi(0, r.position.x)) * 4 + 3
			for xx in range(maxi(0, r.position.x), mini(SIZE, r.position.x + r.size.x)):
				px[o] = 255
				o += 4


## alpha 二值化（树冠叶隙），透明处顺带清 RGB
func threshold_alpha(t: int) -> void:
	var i := 0
	while i < px.size():
		if px[i + 3] >= t:
			px[i + 3] = 255
		else:
			px[i + 3] = 0
			px[i] = 0
			px[i + 1] = 0
			px[i + 2] = 0
		i += 4


## 把 RGB 全量置为某色但保留 alpha（亮灯窗用）
func paint_keep_alpha(c: Color, area: Rect2i) -> void:
	for yy in range(maxi(0, area.position.y), mini(SIZE, area.position.y + area.size.y)):
		var o := (yy * SIZE + maxi(0, area.position.x)) * 4
		for xx in range(maxi(0, area.position.x), mini(SIZE, area.position.x + area.size.x)):
			px[o] = int(c.r * 255.0)
			px[o + 1] = int(c.g * 255.0)
			px[o + 2] = int(c.b * 255.0)
			o += 4

# ============================================================================
# 通用开窗（凹进阴影 → 外框 → 玻璃渐变 → 窗台）
# ============================================================================


func window_box(x: int, y: int, w: int, h: int, wall: Color, glass_top: Color, glass_bottom: Color, frame: int, sill: bool) -> Rect2i:
	rect(x - 2, y - 2, w + 4, h + 4, shade(wall, -0.2))
	rect(x - frame, y - frame, w + frame * 2, h + frame * 2, shade(wall, 0.16))
	vgrad(x, y, w, h, glass_top, shade(glass_top, -0.18), glass_bottom)
	if sill:
		hline(y + h + frame + 2, x - frame - 1, w + frame * 2 + 2, 3, shade(wall, 0.24))
		hline(y - frame - 1, x - frame, w + frame * 2, 2, shade(wall, -0.35))
	return Rect2i(x, y, w, h)


## 给一组亮窗涂暖黄光（在 mask_alpha 之前调用）
func light_windows(lit: Array) -> void:
	for r: Rect2i in lit:
		vgrad(r.position.x, r.position.y, r.size.x, r.size.y, rgb(255, 230, 190), rgb(255, 214, 156), rgb(226, 178, 120))

# ============================================================================
# 0..7 立面
# ============================================================================


## 0 住宅：米黄涂料墙 + 2 个凹进方窗，亮灯率 ~35%
func _facade_residential() -> void:
	var wall := rgb(181, 173, 157)
	clear()
	fill(wall)
	noise(340, 1, 3, [shade(wall, -0.12), shade(wall, 0.07), rgb(152, 144, 130)], 0.1, 0.26)
	for i in 7:
		var x := int(i * (SIZE / 7.0) + rnd() * 8.0)
		rect(x, 0, 2 + rndi(5), SIZE, rgba(102, 98, 90, 0.05 + rnd() * 0.06))
	hline(0, 0, SIZE, 3, rgb(140, 133, 120))
	var lit: Array = []
	for b in 2:
		var cx := 32 + b * 64
		var r := window_box(cx - 18, 32, 36, 48, wall, rgb(76, 87, 98), rgb(52, 61, 70), 2, true)
		rect(r.position.x + 3, r.position.y + 3, int(r.size.x * 0.4), int(r.size.y * 0.35), rgba(190, 202, 212, 0.12))
		if rnd() < 0.35:
			lit.append(r)
	light_windows(lit)
	mask_alpha(lit)


## 1 办公：玻璃幕墙竖梃密排，蓝灰渐变，亮灯率 ~45%
func _facade_office() -> void:
	var frame := rgb(43, 48, 54)
	clear()
	vgrad(0, 0, SIZE, SIZE, rgb(128, 150, 168), rgb(92, 110, 126), rgb(56, 68, 80))
	# 幕墙金属反射：斜向高光条（用竖直细条近似，斜条在 128px 下差别极小）
	for i in 3:
		var x := int(10 + i * 44 + rnd() * 8.0)
		vgrad(x, 0, 9, SIZE, rgba(212, 224, 234, 0.1), rgba(212, 224, 234, 0.04), rgba(212, 224, 234, 0.1))
	var cols := 7
	var rows := 2
	var cw := SIZE / cols
	var ch := SIZE / rows
	var panes: Array = []
	for r in rows:
		for cc in cols:
			panes.append(Rect2i(cc * cw + 1, r * ch + 1, cw - 2, ch - 2))
	for i in cols:
		vline(i * cw, 0, SIZE, 3, frame)
	for j in rows:
		hline(j * ch, 0, SIZE, 3, frame)
	var lit: Array = []
	for p: Rect2i in panes:
		if rnd() < 0.45:
			lit.append(p)
	light_windows(lit)
	mask_alpha(lit)


## 2 商业：金属板墙 + 横向招牌色带 + 小窗，亮灯率 ~30%
func _facade_commercial() -> void:
	var wall := rgb(164, 164, 159)
	clear()
	fill(wall)
	for j in 8:
		hline(j * 16 + 8, 0, SIZE, 1, rgba(133, 133, 128, 0.45))
	noise(240, 1, 3, [shade(wall, -0.1), shade(wall, 0.06)], 0.08, 0.2)
	# 招牌带
	rect(0, 42, SIZE, 36, rgb(44, 43, 42))
	var blocks := [rgb(156, 58, 48), rgb(170, 105, 52), rgb(62, 92, 120), rgb(140, 132, 60)]
	var bx := 3
	while bx < SIZE - 6:
		var bw := 14 + rndi(18)
		rect(bx, 46, bw, 28, blocks[rndi(blocks.size())])
		var sx := bx + 3
		while sx < bx + bw - 4:
			var seg := 3 + rndi(4)
			rect(sx, 60, seg, 7, rgba(232, 228, 220, 0.5))
			sx += seg + 3
		bx += bw + 3 + rndi(6)
	var lit: Array = []
	var centers := [22, 64, 106]
	for i in centers.size():
		var r := window_box(centers[i] - 12, 12, 24, 22, wall, rgb(70, 80, 90), rgb(48, 56, 64), 2, false)
		if rnd() < 0.3:
			lit.append(r)
	for i in centers.size():
		var r := window_box(centers[i] - 15, 88, 30, 28, wall, rgb(72, 82, 92), rgb(50, 58, 66), 2, true)
		if rnd() < 0.3:
			lit.append(r)
	light_windows(lit)
	mask_alpha(lit)


## 3 裙楼/底商：大玻璃橱窗 + 门洞 + 遮阳篷条纹，亮灯率 ~70%
func _facade_podium() -> void:
	var wall := rgb(148, 145, 139)
	clear()
	fill(wall)
	noise(200, 1, 3, [shade(wall, -0.1), shade(wall, 0.06)], 0.08, 0.2)
	# 顶部招牌带
	rect(0, 10, SIZE, 22, rgb(46, 44, 44))
	var blocks := [rgb(158, 62, 50), rgb(178, 118, 56), rgb(58, 90, 122)]
	var bx := 4
	while bx < SIZE - 8:
		var bw := 20 + rndi(22)
		rect(bx, 13, bw, 16, blocks[rndi(blocks.size())])
		var sx := bx + 4
		while sx < bx + bw - 5:
			rect(sx, 18, 5, 6, rgba(236, 232, 224, 0.55))
			sx += 9
		bx += bw + 4
	# 遮阳篷：暗红 / 米白相间
	var sw := SIZE / 8.0
	for i in 8:
		var c := rgb(108, 50, 44) if i % 2 == 0 else rgb(214, 206, 186)
		rect(int(i * sw), 36, int(sw + 1), 14, c)
	rect(0, 50, SIZE, 4, rgba(40, 38, 36, 0.3))
	# 橱窗
	var win_y := 56
	var win_h := 66
	var cols := 3
	var cw := SIZE / cols
	rect(0, win_y, SIZE, win_h, rgb(56, 54, 52))
	var panes: Array = []
	for i in cols:
		var p := Rect2i(int(i * cw + 1), win_y + 1, int(cw - 2), win_h - 2)
		panes.append(p)
		vgrad(p.position.x, p.position.y, p.size.x, p.size.y, rgb(116, 104, 80), rgb(94, 84, 65), rgb(72, 64, 50))
	for i in cols + 1:
		vline(int(i * cw), win_y, win_h, 3, rgb(44, 42, 40))
	hline(win_y, 0, SIZE, 3, rgb(44, 42, 40))
	# 门洞（第二格）
	var door_x := int(cw + cw / 2.0 - 12)
	rect(door_x, win_y + 6, 24, win_h - 12, rgb(38, 36, 34))
	rect(door_x + 2, win_y + 8, 20, win_h - 18, rgb(62, 58, 52))
	rect(door_x + 15, win_y + int(win_h * 0.5), 2, 12, rgb(176, 170, 156))
	rect(0, win_y + win_h, SIZE, SIZE - (win_y + win_h), rgb(70, 68, 64))
	var lit: Array = []
	for p: Rect2i in panes:
		if rnd() < 0.7:
			lit.append(p)
	for r: Rect2i in lit:
		vgrad(r.position.x, r.position.y, r.size.x, r.size.y, rgb(255, 238, 194), rgb(255, 226, 168), rgb(222, 186, 130))
	mask_alpha(lit)


## 4 砖砌：红棕砖 + 错缝 + 窄长窗，亮灯率 ~30%
func _facade_brick() -> void:
	var brick := rgb(146, 82, 63)
	var mortar := rgb(176, 168, 156)
	clear()
	fill(mortar)
	var bw := 16
	var bh := 8
	for row in SIZE / bh:
		var y := row * bh
		var off := 0 if row % 2 == 0 else -bw / 2
		var x := off
		while x < SIZE:
			rect(x, y, bw - 1, bh - 1, tint(brick, 0.055))
			x += bw
	noise(260, 1, 3, [rgb(104, 58, 44), rgb(124, 108, 96)], 0.08, 0.2)
	var lit: Array = []
	for b in 2:
		var cx := 32 + b * 64
		var r := window_box(cx - 11, 38, 22, 58, rgb(150, 96, 78), rgb(68, 76, 86), rgb(44, 50, 58), 3, true)
		if rnd() < 0.3:
			lit.append(r)
	light_windows(lit)
	mask_alpha(lit)


## 5 深色玻璃：近黑深蓝玻璃 + 细竖梃，亮灯率 ~25%
func _facade_glass() -> void:
	clear()
	vgrad(0, 0, SIZE, SIZE, rgb(46, 60, 76), rgb(30, 40, 52), rgb(20, 27, 36))
	for i in 4:
		var x := int(4 + i * 32 + rnd() * 6.0)
		vgrad(x, 0, 8, SIZE, rgba(160, 182, 200, 0.07), rgba(160, 182, 200, 0.02), rgba(160, 182, 200, 0.07))
	var cols := 8
	var cw := SIZE / cols
	for i in cols:
		vline(int(i * cw), 0, SIZE, 1, rgb(14, 19, 25))
	var lit: Array = []
	for r in 4:
		for cc in cols:
			if rnd() < 0.25:
				lit.append(Rect2i(int(cc * cw + 1), r * (SIZE / 4) + 1, int(cw - 2), SIZE / 4 - 2))
	for r: Rect2i in lit:
		vgrad(r.position.x, r.position.y, r.size.x, r.size.y, rgb(255, 248, 232), rgb(242, 227, 199), rgb(228, 206, 166))
	mask_alpha(lit)


## 6 瓷砖：灰绿小瓷砖网格 + 窄窗，亮灯率 ~30%
func _facade_tile() -> void:
	var tile := rgb(146, 153, 146)
	clear()
	fill(rgb(118, 124, 118))
	var t := 8
	var y := 0
	while y < SIZE:
		var x := 0
		while x < SIZE:
			rect(x, y, t - 1, t - 1, tint(tile, 0.047))
			x += t
		y += t
	noise(200, 1, 3, [rgb(122, 128, 122), rgb(164, 170, 162)], 0.08, 0.2)
	var lit: Array = []
	for c in [30, 98]:
		var r := window_box(c - 12, 36, 24, 56, tile, rgb(74, 84, 92), rgb(50, 58, 66), 2, true)
		if rnd() < 0.3:
			lit.append(r)
	light_windows(lit)
	mask_alpha(lit)


## 7 素混凝土：浅灰大板 + 板缝 + 竖向雨痕 + 窄条窗，亮灯率 ~25%
func _facade_concrete() -> void:
	var wall := rgb(166, 166, 162)
	clear()
	fill(wall)
	noise(300, 1, 3, [shade(wall, -0.09), shade(wall, 0.06), rgb(140, 140, 136)], 0.08, 0.2)
	vline(0, 0, SIZE, 2, rgb(138, 138, 134))
	vline(64, 0, SIZE, 2, rgb(138, 138, 134))
	hline(0, 0, SIZE, 2, rgb(138, 138, 134))
	hline(64, 0, SIZE, 2, rgb(138, 138, 134))
	for i in 11:
		var x := int(rnd() * SIZE)
		rect(x, 0, 2 + rndi(4), SIZE, rgba(112, 112, 108, 0.05 + rnd() * 0.07))
	var lit: Array = []
	for i in 3:
		var r := window_box(13 + i * 44, 28, 18, 66, wall, rgb(72, 82, 92), rgb(48, 56, 64), 2, true)
		# 第一扇必亮：纯混凝土楼夜里若一盏不亮会显得整层死掉
		if i == 0 or rnd() < 0.25:
			lit.append(r)
	light_windows(lit)
	mask_alpha(lit)

# ============================================================================
# 8..10 屋面
# ============================================================================


## 8 屋面 A：混凝土屋面 + 分格缝 + 积水污渍 + 边缘泛白
func _roof_a() -> void:
	var base := rgb(146, 148, 144)
	clear()
	fill(base)
	noise(300, 1, 3, [shade(base, -0.09), shade(base, 0.06), rgb(128, 130, 126)], 0.08, 0.2)
	vline(0, 0, SIZE, 3, rgb(124, 126, 122))
	vline(64, 0, SIZE, 3, rgb(124, 126, 122))
	hline(0, 0, SIZE, 3, rgb(124, 126, 122))
	hline(64, 0, SIZE, 3, rgb(124, 126, 122))
	for i in 5:
		var cx := 16.0 + rnd() * (SIZE - 32.0)
		var cy := 16.0 + rnd() * (SIZE - 32.0)
		rgrad(cx, cy, 10.0 + rnd() * 20.0, rgba(96, 108, 100, 0.22), rgba(96, 108, 100, 0.0))
	rect(0, 0, SIZE, 4, rgba(236, 238, 234, 0.1))
	rect(0, SIZE - 4, SIZE, 4, rgba(236, 238, 234, 0.1))
	rect(0, 0, 4, SIZE, rgba(236, 238, 234, 0.1))
	rect(SIZE - 4, 0, 4, SIZE, rgba(236, 238, 234, 0.1))


## 9 屋面 B：屋面 + 俯视空调机组 + 管道线
func _roof_b() -> void:
	var base := rgb(140, 142, 138)
	clear()
	fill(base)
	noise(240, 1, 3, [shade(base, -0.08), shade(base, 0.06)], 0.08, 0.18)
	vline(0, 0, SIZE, 2, rgb(116, 118, 114))
	hline(0, 0, SIZE, 2, rgb(116, 118, 114))
	var units: Array = []
	for i in 7:
		var w := 16 + rndi(12)
		var h := 11 + rndi(8)
		units.append(Rect2i(rndi(SIZE - w), rndi(SIZE - h), w, h))
	for u: Rect2i in units:
		rect(u.position.x + 3, u.position.y + 3, u.size.x, u.size.y, rgba(48, 50, 48, 0.45))
	for u: Rect2i in units:
		rect(u.position.x, u.position.y, u.size.x, u.size.y, rgb(190, 194, 189))
		rect(u.position.x + 2, u.position.y + 2, u.size.x - 4, u.size.y - 4, rgb(214, 217, 212))
		var fr := mini(u.size.x, u.size.y) * 0.26
		disc(u.position.x + u.size.x * 0.5, u.position.y + u.size.y * 0.5, fr, rgba(120, 124, 120, 0.6))
	for i in 3:
		hline(10 + rndi(SIZE - 20), 0, SIZE, 3, rgba(104, 108, 104, 0.5))


## 10 屋面 C：屋面 + 太阳能板阵列 + 碎石
func _roof_c() -> void:
	var base := rgb(132, 134, 130)
	clear()
	fill(base)
	noise(240, 1, 3, [shade(base, -0.09), shade(base, 0.06)], 0.08, 0.18)
	var cell := SIZE / 4
	for r in 4:
		for c in 4:
			if rnd() < 0.15:
				continue
			var x := c * cell + 2
			var y := r * cell + 2
			var w := cell - 6
			var h := cell - 6
			rect(x, y, w, h, rgb(36, 52, 76))
			rect(x + 1, y + 1, w - 2, h - 2, rgb(46, 66, 94))
			for i in range(1, 4):
				vline(x + int(w * i / 4.0), y, h, 1, rgb(26, 38, 56))
			for j in range(1, 3):
				hline(y + int(h * j / 3.0), x, w, 1, rgb(26, 38, 56))
			rect(x + 2, y + 2, w - 4, 3, rgba(150, 190, 220, 0.1))
	noise(150, 1, 3, [rgb(110, 112, 108), rgb(160, 162, 158)], 0.2, 0.45)

# ============================================================================
# 11..15 地面 / 道路
# ============================================================================


## 11 人行道：浅灰方砖 8×8 + 深色砖缝 + 污渍
func _pavement() -> void:
	var base := rgb(166, 166, 161)
	clear()
	fill(base)
	var t := 16
	var y := 0
	while y < SIZE:
		var x := 0
		while x < SIZE:
			var blk := tint(rgb(150, 150, 145), 0.055)
			blk.a = 0.1 + rnd() * 0.13
			rect(x + 1, y + 1, t - 2, t - 2, blk)
			x += t
		y += t
	for i in 8:
		vline(i * t, 0, SIZE, 2, rgb(126, 126, 121))
		hline(i * t, 0, SIZE, 2, rgb(126, 126, 121))
	noise(220, 2, 7, [rgb(122, 120, 114), rgb(142, 140, 134)], 0.05, 0.13)


## 12 草地：深浅绿噪声 + 土黄斑块 + 细密草纹
func _grass() -> void:
	# 偏灰的橄榄绿：城市里的草地不该是荧光绿，尤其它还是分块底铺的主色
	var g1 := rgb(72, 84, 58)
	var g2 := rgb(56, 68, 46)
	var g3 := rgb(86, 98, 66)
	clear()
	fill(g1)
	for i in 9:
		rgrad(rnd() * SIZE, rnd() * SIZE, 12.0 + rnd() * 24.0, rgba(52, 62, 42, 0.5), rgba(52, 62, 42, 0.0))
	for i in 7:
		rgrad(rnd() * SIZE, rnd() * SIZE, 10.0 + rnd() * 18.0, rgba(88, 102, 68, 0.4), rgba(88, 102, 68, 0.0))
	for i in 4:
		rgrad(rnd() * SIZE, rnd() * SIZE, 7.0 + rnd() * 12.0, rgba(136, 120, 74, 0.26), rgba(136, 120, 74, 0.0))
	for i in 700:
		var x := rndi(SIZE)
		var y := rndi(SIZE)
		var c := g2 if rnd() < 0.5 else g3
		c.a = 0.12 + rnd() * 0.22
		rect(x, y, 1, 2 + rndi(2), c)


## 13 水：深青蓝 + 柔和波纹
func _water() -> void:
	var light := rgb(42, 88, 102)
	clear()
	vgrad(0, 0, SIZE, SIZE, light, rgb(30, 62, 74), rgb(24, 50, 62))
	for i in 14:
		rect(0, rndi(SIZE), SIZE, 1 + rndi(3), Color(light.r, light.g, light.b, 0.05 + rnd() * 0.08))
	for i in 44:
		rect(rndi(SIZE), rndi(SIZE), 6 + rndi(20), 1, rgba(86, 130, 140, 0.04 + rnd() * 0.06))
	noise(300, 1, 2, [rgb(22, 44, 54), rgb(52, 98, 110)], 0.05, 0.13)


## 14 沥青：深灰噪点 + 车辙
func _asphalt() -> void:
	var base := rgb(51, 54, 58)
	clear()
	fill(base)
	noise(900, 1, 2, [rgb(40, 42, 46), rgb(64, 67, 72), rgb(72, 74, 78), rgb(34, 36, 40)], 0.25, 0.6)
	for i in 3:
		var x := int(14 + i * 44 + rnd() * 6.0)
		var w := 15 + rndi(8)
		vgrad(x, 0, w, SIZE, rgba(150, 152, 155, 0.0), rgba(150, 152, 155, 0.11), rgba(150, 152, 155, 0.0))


## 15 标线：纯白
func _marking() -> void:
	clear()
	fill(Color.WHITE)

# ============================================================================
# 16..17 树冠 / 光晕
# ============================================================================


## 16 树冠：重叠叶簇，形状外与叶隙 alpha=0
func _canopy() -> void:
	clear()
	var greens := [rgb(64, 96, 44), rgb(52, 80, 36), rgb(78, 110, 54), rgb(44, 70, 34)]
	# 中心铺满 tile，让树冠面片整体有叶、边缘不规则
	var clusters := [
		Vector3(40, 38, 36), Vector3(88, 40, 34), Vector3(64, 66, 38),
		Vector3(30, 76, 30), Vector3(96, 80, 30), Vector3(56, 100, 32),
		Vector3(100, 108, 24), Vector3(20, 106, 24), Vector3(76, 14, 26),
		Vector3(16, 18, 24),
	]
	for v: Vector3 in clusters:
		var base: Color = greens[rndi(greens.size())]
		rgrad(v.x, v.y, v.z, shade(base, -0.26), shade(base, 0.2))
	# 叶隙：挖掉小块（alpha 清 0 + RGB 清 0）
	for i in 30:
		_erase_disc(rnd() * SIZE, rnd() * SIZE, 2.0 + rnd() * 4.5)
	threshold_alpha(128)


## 擦除圆（把 alpha 与 RGB 一起清掉，替代 Canvas 的 destination-out）
func _erase_disc(cx: float, cy: float, r: float) -> void:
	var r2 := r * r
	for yy in range(int(floor(cy - r)), int(ceil(cy + r))):
		var ry := yy % SIZE
		if ry < 0:
			ry += SIZE
		var dy := float(yy) + 0.5 - cy
		var row := ry * SIZE * 4
		for xx in range(int(floor(cx - r)), int(ceil(cx + r))):
			var dx := float(xx) + 0.5 - cx
			if dx * dx + dy * dy > r2:
				continue
			var rx := xx % SIZE
			if rx < 0:
				rx += SIZE
			var o := row + rx * 4
			px[o] = 0
			px[o + 1] = 0
			px[o + 2] = 0
			px[o + 3] = 0


## 17 光晕：暖白径向渐变（中心不透明 → 边缘全透明）
func _glow() -> void:
	clear()
	# 半径 64 且居中，边缘 alpha 恰好为 0，天然无缝
	rgrad(64.0, 64.0, 64.0, Color(1.0, 0.965, 0.878, 1.0), Color(1.0, 0.91, 0.745, 0.0))