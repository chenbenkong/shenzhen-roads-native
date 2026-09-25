## city.bin 读取器 —— 二进制格式 v1（与 Web 版共用同一份数据文件）
##
## 目录：16 字节头（magic 'SZO1' | version | sectionCount）
##       随后 sectionCount × 32 字节：name[16] | offset | byteLength | elemCount | elemSize
## 记录式小节（bmeta/rmeta/gpoly/emeta）的 elemCount 是「记录数」，需按记录逐字段解码；
## 顶点类小节（bvert/rvert/gvert/npos）以扁平元素计，可直接批量转换。
class_name CityBin
extends RefCounted

const MAGIC := 0x534F5A31  # 'SZO1'（小端）

class Section:
	var name: String
	var offset: int
	var byte_length: int
	var count: int
	var elem_size: int

var bytes: PackedByteArray
var sections: Dictionary = {}


static func load_from(path: String) -> CityBin:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("无法打开 %s（错误码 %d）" % [path, FileAccess.get_open_error()])
		return null
	var bin := CityBin.new()
	bin.bytes = f.get_buffer(f.get_length())
	f.close()
	bin._parse()
	return bin


func _parse() -> void:
	if bytes.size() < 16:
		push_error("city.bin 数据过短")
		return
	if bytes.decode_u32(0) != MAGIC:
		push_error("city.bin 魔数不匹配")
		return
	var version := bytes.decode_u32(4)
	if version != 1:
		push_error("city.bin 版本 %d 不受支持" % version)
		return
	var count := bytes.decode_u32(8)
	for i in count:
		var base := 16 + i * 32
		var name := ""
		for c in 16:
			var code := bytes[base + c]
			if code == 0:
				break
			name += char(code)
		var s := Section.new()
		s.name = name
		s.offset = bytes.decode_u32(base + 16)
		s.byte_length = bytes.decode_u32(base + 20)
		s.count = bytes.decode_u32(base + 24)
		s.elem_size = bytes.decode_u32(base + 28)
		sections[s.name] = s


func section(name: String) -> Section:
	var s: Section = sections.get(name)
	if s == null:
		push_error("city.bin 缺少数据段 %s" % name)
	return s


## 小端切片：把某段字节拷出来（用于批量数值转换）
func slice_of(name: String) -> PackedByteArray:
	var s := section(name)
	return bytes.slice(s.offset, s.offset + s.byte_length)


## 有符号 16 位数组（如量化坐标）
func i16(name: String) -> PackedInt32Array:
	var s := section(name)
	var n := s.byte_length / 2
	var out := PackedInt32Array()
	out.resize(n)
	for i in n:
		out[i] = bytes.decode_s16(s.offset + i * 2)
	return out


## 无符号 16 位数组
func u16(name: String) -> PackedInt32Array:
	var s := section(name)
	var n := s.byte_length / 2
	var out := PackedInt32Array()
	out.resize(n)
	for i in n:
		out[i] = bytes.decode_u16(s.offset + i * 2)
	return out


## 无符号 32 位数组（用 64 位承载，u32 可超 int32 范围）
func u32(name: String) -> PackedInt64Array:
	var s := section(name)
	var n := s.byte_length / 4
	var out := PackedInt64Array()
	out.resize(n)
	for i in n:
		out[i] = bytes.decode_u32(s.offset + i * 4)
	return out


## 无符号 8 位数组（直接切片，无需转换）
func u8(name: String) -> PackedByteArray:
	return slice_of(name)


## 单精度浮点数组
func f32(name: String) -> PackedFloat32Array:
	return slice_of(name).to_float32_array()


## JSON 文本段（meta）
func json_text(name: String) -> String:
	return slice_of(name).get_string_from_utf8()