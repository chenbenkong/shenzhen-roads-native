// 静态世界主着色器：建筑 / 道路 / 地面 / 桥面
// 顶点 CUSTOM0.r = 图集层索引（RGBA8 → 0..1，取整还原 0..17）
// 图集 alpha 在立面层是「夜间亮窗掩码」，其余层恒为 1（用层号判断抑制自发光）
shader_type spatial;
render_mode cull_back, diffuse_lambert, depth_draw_opaque;

uniform sampler2DArray atlas : source_color, filter_linear_mipmap, repeat_enable;
uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform float lamp_energy : hint_range(0.0, 6.0) = 1.15;
uniform float water_flow : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	float layer = round(UV2.x);
	vec2 uv = UV;
	// 水面：两层反向缓慢流动，制造波光（层 13 是水）
	if (abs(layer - 13.0) < 0.5 && water_flow > 0.001) {
		float t = TIME * 0.014;
		uv += vec2(t, t * 0.6);
	}
	vec4 tex = texture(atlas, vec3(uv, layer));
	ALBEDO = tex.rgb;
	// 粗糙度按表面类型区分：沥青与水面要有反光（夜里路灯/车灯能拉出高光），
	// 立面与草地保持粗糙，避免整座城市像塑料
	float rough = 0.92;
	if (abs(layer - 14.0) < 0.5) {
		rough = 0.64;        // 沥青
	} else if (abs(layer - 13.0) < 0.5) {
		rough = 0.20;        // 水面
	} else if (abs(layer - 11.0) < 0.5) {
		rough = 0.78;        // 人行道方砖
	} else if (layer < 10.5) {
		rough = 0.85;        // 建筑立面 / 屋面
	}
	ROUGHNESS = rough;
	// 注意：Godot 的 SPECULAR 默认 0.5，之前设成 0.04 等于关掉全部高光，画面发闷
	SPECULAR = 0.5;
	// 亮窗自发光：仅立面层（0..7）使用 alpha 掩码
	float is_facade = step(layer, 7.5);
	// 夜间地面泛光：朝上的面在夜里受城市灯光影响（很弱的暖色自发光），避免地面死黑。
	// 强度宁小勿大 —— 给多了路面会变成一片土黄色，夜景感全丢；水面略强（反射天空与灯）
	float is_asphalt = step(13.5, layer) * step(layer, 14.5);
	float is_water = step(12.5, layer) * step(layer, 13.5);
	float bounce = is_water * 0.055 + is_asphalt * 0.030 + (1.0 - is_asphalt) * (1.0 - is_water) * 0.020;
	EMISSION = vec3(1.0, 0.86, 0.62) * tex.a * is_facade * night * lamp_energy
		+ vec3(1.0, 0.78, 0.52) * night * bounce * UV2.y;
}