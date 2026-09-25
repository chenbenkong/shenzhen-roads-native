// 静态世界主着色器：建筑 / 道路 / 地面 / 桥面
// 顶点 CUSTOM0.r = 图集层索引（RGBA8 → 0..1，取整还原 0..17）
// 图集 alpha 在立面层是「夜间亮窗掩码」，其余层恒为 1（用层号判断抑制自发光）
shader_type spatial;
render_mode cull_back, diffuse_lambert, depth_draw_opaque;

uniform sampler2DArray atlas : source_color, filter_linear_mipmap, repeat_enable;
uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform float lamp_energy : hint_range(0.0, 6.0) = 2.2;
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
	ROUGHNESS = 0.92;
	SPECULAR = 0.04;
	// 亮窗自发光：仅立面层（0..7）使用 alpha 掩码
	float is_facade = step(layer, 7.5);
	EMISSION = vec3(1.0, 0.86, 0.62) * tex.a * is_facade * night * lamp_energy;
}