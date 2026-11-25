// Matte: a hard offset block shadow, no blur. Down-right, further for focused panes (params.y
// is larger for them); dark ink on light UI themes, a deep accent tone on dark ones.
#include "common.glsl"
#include "matte.glsl"

void main() {
	float o = 3.0 + 3.0 * params.y;
	float d = sd_round(ui_local() - vec2(o, o), rect.zw * 0.5, m_rad());
	float cover = clamp(0.5 - d, 0.0, 1.0);
	vec3 col = ui_light() ? vec3(0.07, 0.07, 0.09) : accent.rgb * 0.42;
	finalColor = vec4(col, cover * clamp(params.y, 0.0, 1.0) * 0.92);
}
