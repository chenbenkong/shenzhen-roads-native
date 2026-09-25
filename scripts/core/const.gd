## 全局常量：高度分层、分块尺寸、纹理层定义（与 Web 版完全一致的世界约定）
## 世界坐标单位 = 米（数据已按 0.6 缩放），Y 轴向上。
class_name C
extends RefCounted

# ---- 高度分层（米）：避免 z-fighting 的层叠约定 ----
const Y_SEA := 0.0
const Y_LAND := 0.05
const Y_WATER := 0.10
const Y_GRASS := 0.10
const Y_ROAD := 0.16
const Y_MARKING := 0.19
const Y_SIDEWALK := 0.19
const Y_BRIDGE := 6.5

# ---- 世界分块与量化 ----
const CHUNK_SIZE := 640.0
const Q := 4.0  # 数据量化：每米 4 单位（0.25m 精度）

# ---- 纹理层索引（顺序 = 图集生成顺序）----
enum L {
	FACADE_RESIDENTIAL,  # 0
	FACADE_OFFICE,        # 1
	FACADE_COMMERCIAL,    # 2
	FACADE_PODIUM,        # 3
	FACADE_BRICK,         # 4
	FACADE_GLASS,         # 5
	FACADE_TILE,          # 6
	FACADE_CONCRETE,      # 7
	ROOF_A,               # 8
	ROOF_B,               # 9
	ROOF_C,               # 10
	PAVEMENT,             # 11
	GRASS,                # 12
	WATER,                # 13
	ASPHALT,              # 14
	MARKING,              # 15
	CANOPY,               # 16
	GLOW,                 # 17
}

const LAYER_COUNT := 18

# 每层贴图在世界中的尺寸（米 / 一次重复），几何生成时 uv = 米 ÷ 该值
# 注：PackedFloat32Array 构造不算常量表达式，只能声明为静态变量（仍然全局唯一）
static var LAYER_TILE := PackedFloat32Array([
	4, 4, 4, 4, 4, 4, 4, 4,
	8, 8, 8,
	6, 10, 16,
	8, 1, 4, 4,
])

# ---- 道路等级速度（m/s，与数据 kindSpeed 对应）----
static var KIND_SPEED := PackedFloat32Array([9, 6.5, 11, 14, 19])

# ---- 视觉距离（米）----
const VIEW_FAR := 9000.0
const LOAD_RADIUS := 1900.0
const LOD_DISTANCE := 900.0