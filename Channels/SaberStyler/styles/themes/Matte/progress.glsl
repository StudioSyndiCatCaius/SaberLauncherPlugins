// Matte: a chunky bar with an ink border; the fill is solid with darker diagonal stripes.
// Unknown progress (params.w < 0) scrolls the stripes along the whole bar. tint = fill,
// glow = track.
#include "common.glsl"
#include "matte.glsl"

void main() {
	vec2 px = ui_px();
	vec2 hb = rect.zw * 0.5;
	float d = sd_round(ui_local(), hb, min(3.0, min(hb.x, hb.y)));
	float cover = clamp(0.5 - d, 0.0, 1.0);
	if (cover <= 0.0) discard;

	float f = params.w;
	float fill;
	float stripes;
	if (f < 0.0) {
		fill = 1.0;
		stripes = m_hatch(12.0, 40.0);
	} else {
		fill = clamp(rect.x + rect.z * clamp(f, 0.0, 1.0) - px.x + 0.5, 0.0, 1.0);
		stripes = m_hatch(10.0, 0.0);
	}
	vec3 on = mix(tint.rgb, tint.rgb * 0.72, stripes);
	if (f < 0.0) on = mix(glow.rgb * 0.4 + tint.rgb * 0.15, tint.rgb, stripes);
	vec3 track = ui_light() ? mix(glow.rgb, vec3(1.0), 0.7) : vec3(0.06, 0.06, 0.08);
	vec3 col = mix(track, on, fill);

	float border = clamp(min(d + 1.5, -d) + 0.5, 0.0, 1.0);
	col = mix(col, m_ink(), border * 0.75);
	finalColor = vec4(col, cover * params.y);
}
