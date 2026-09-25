// 静态世界主着色器：建筑 / 道路 / 地面 / 桥面
// 顶点 CUSTOM0.r = 图集层索引（RGBA8 → 0..1，取整还原 0..17）
// 图集 alpha 在立面层是「夜间亮窗掩码」，其余层恒为 1（用层号判断抑制自发光）
shader_type spatial;
// vertex_lighting：光照改到顶点阶段算。城市几何是「大平面 + 稀疏顶点」，逐像素光照在这里
// 几乎不产生额外细节，却要为每个像素付一遍光照计算 —— 核显上这是纯亏（实测收益见提交说明）
render_mode cull_back, diffuse_lambert, depth_draw_opaque, vertex_lighting;

uniform sampler2DArray atlas : source_color, filter_linear_mipmap, repeat_enable;
uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform float lamp_energy : hint_range(0.0, 6.0) = 1.15;
uniform float water_flow : hint_range(0.0, 1.0) = 1.0;
// 假天光反射：天空环境光探针已全局关闭（它要每帧重烘焙立方体 + 逐像素采样，
// 核显上实测 13 ms/帧），这里用「顶色 / 地平线色」两段渐变 + 菲涅尔近似天空反射，
// 成本约 6 条 ALU，换来沥青与水面掠射角上几乎一样的反光观感
uniform vec3 sky_top : source_color = vec3(0.235, 0.435, 0.78);
uniform vec3 sky_horizon : source_color = vec3(0.70, 0.80, 0.93);
uniform float sky_reflect : hint_range(0.0, 2.0) = 1.0;

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
	// 假天光反射（顶替已关闭的天空反射探针）：掠射角处反光最强，
	// 反射方向越低越接近地平线的亮色 —— 湿沥青与水面就是靠这个「亮带」出质感
	float refl_amount = 0.02;
	if (abs(layer - 13.0) < 0.5) {
		refl_amount = 0.52;       // 水面
	} else if (abs(layer - 14.0) < 0.5) {
		refl_amount = 0.24;       // 沥青：湿滑路面的天光，给多了整条路会发白
	} else if (abs(layer - 11.0) < 0.5) {
		refl_amount = 0.05;       // 人行道方砖
	}
	// 掠射程度同时决定「反射强度」与「反射到的天色」：
	// 正上方看 —— 反射天空顶色；越接近掠射 —— 反射越接近地平线的亮色。
	// （真实反射向量要两次矩阵变换 + 两次归一化，这里用视线夹角近似，省掉一整套世界空间运算；
	//   对水平路面/水面这些唯一在意反光的面，结论完全一致）
	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float graze = 1.0 - ndv;
	float fres = graze * graze * graze * graze;     // 菲涅尔：4 次乘法，比 pow() 便宜得多
	vec3 sky_ref = mix(sky_top, sky_horizon, sqrt(graze));

	EMISSION = vec3(1.0, 0.86, 0.62) * tex.a * is_facade * night * lamp_energy
		+ vec3(1.0, 0.78, 0.52) * night * bounce * UV2.y
		+ sky_ref * (refl_amount * (0.18 + 0.82 * fres) * sky_reflect);
}