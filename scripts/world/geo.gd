## 几何构建器：静态世界专用（建筑 / 道路 / 地面 / 道具）
##
## 顶点属性：POSITION(F32×3) + NORMAL(F32×3) + TEX_UV(F32×2) + TEX_UV2(F32×2)
##  - NORMAL：Godot 直接吃 Vector3，比 Web 版的 8 位压缩精度更高（墙面全竖直、屋面全朝上）
##  - UV2：x = 纹理层索引（0..17），y = 是否朝上。
##    注：Godot 的 Compatibility（OpenGL）渲染器不支持在 fragment 读 CUSTOM0，
##    所以层索引走 UV2 这条一定可用的通道（着色器里 round(UV2.x) 取层）。
##
## 用法：push(...) 写顶点拿到索引 → tri/quad 连接 → to_mesh() / add_to() 得到 ArrayMesh
class_name GeoBuilder
extends RefCounted

var positions := PackedVector3Array()
var normals := PackedVector3Array()
var uvs := PackedVector2Array()
var uv2 := PackedVector2Array()  # x = layer, y = up
var indices := PackedInt32Array()


func size() -> int:
	return positions.size()


func is_empty() -> bool:
	return indices.is_empty()


## 写入一个顶点并返回索引。
## nx/nz 为水平法线分量（竖直墙面用）；up > 0.5 表示朝上（地表 / 屋面 / 路面）
func push(x: float, y: float, z: float, u: float, v: float, layer: int, nx: float, nz: float, up: float) -> int:
	var vi := positions.size()
	positions.append(Vector3(x, y, z))
	uvs.append(Vector2(u, v))
	if up > 0.5:
		normals.append(Vector3(0.0, 1.0, 0.0))
	else:
		var l := sqrt(nx * nx + nz * nz)
		if l > 1e-5:
			nx /= l
			nz /= l
		else:
			nx = 0.0
			nz = 1.0
		normals.append(Vector3(nx, 0.0, nz))
	uv2.append(Vector2(float(layer), 1.0 if up > 0.5 else 0.0))
	return vi


func tri(a: int, b: int, c: int) -> void:
	indices.append(a)
	indices.append(b)
	indices.append(c)


func quad(a: int, b: int, c: int, d: int) -> void:
	indices.append(a)
	indices.append(b)
	indices.append(c)
	indices.append(a)
	indices.append(c)
	indices.append(d)


## 把自己作为一个 surface 追加到已有 mesh（一块地形的多个材质合成一个 MeshInstance3D）
func add_to(mesh: ArrayMesh, mat: Material) -> bool:
	if indices.is_empty():
		return false
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = indices
	var idx := mesh.get_surface_count()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(idx, mat)
	return true


## 产出 ArrayMesh
func to_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if indices.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## 清空（复用同一个 builder 构建下一块，避免反复分配）
func reset() -> void:
	positions.clear()
	normals.clear()
	uvs.clear()
	uv2.clear()
	indices.clear()

# ============================================================================
# 确定性随机（与 Web 版同一套哈希，保证世界细节每次一致）
# ============================================================================


static func hash2(x: int, y: int) -> int:
	var n := (x * 0x27D4EB2D) ^ (y * 0x165667B1)
	n = n & 0xFFFFFFFF
	var t := (n ^ (n >> 15)) * 0x2545F491
	t = t & 0xFFFFFFFF
	return (t ^ (t >> 13)) & 0xFFFFFFFF


## [0,1) 随机数
static func rand01(x: int, y: int, salt: int = 0) -> float:
	var sx := (x * 73856093 + salt * 19349663) & 0xFFFFFFFF
	var sy := (y * 83492791 + salt * 2971215073) & 0x7FFFFFFF
	return float(hash2(sx, sy)) / 4294967296.0