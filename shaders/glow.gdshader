// 光晕：路灯 / 车灯 / 招牌的加色光斑（不写深度、不受光照）
shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2DArray atlas : source_color, filter_linear_mipmap, repeat_enable;
uniform float strength : hint_range(0.0, 4.0) = 1.0;

void fragment() {
	float layer = round(UV2.x);
	vec4 tex = texture(atlas, vec3(UV, layer));
	ALBEDO = tex.rgb * strength;
	ALPHA = tex.a * strength;
}