// 带镂空的静态世界：树冠 / 路灯玻璃 / 旗面等（alpha scissor，比 discard 便宜）
// 树冠是交叉面片，必须双面可见
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, depth_draw_opaque;

uniform sampler2DArray atlas : source_color, filter_linear_mipmap, repeat_enable;
uniform float alpha_threshold : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	float layer = round(UV2.x);
	vec4 tex = texture(atlas, vec3(UV, layer));
	ALBEDO = tex.rgb;
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_threshold;
	ROUGHNESS = 0.95;
	SPECULAR = 0.0;
}