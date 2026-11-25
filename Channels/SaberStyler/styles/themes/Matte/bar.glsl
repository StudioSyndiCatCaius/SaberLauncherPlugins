// Matte header / footer: solid grainy strips with a thick accent rule where they meet the
// page (the rect runs off the screen, so only that inner edge shows) and an ink line beside it.
#include "common.glsl"
#include "matte.glsl"

void main() {
	float d = ui_dist(0.0);
	float cover = clamp(0.5 - d, 0.0, 1.0);
	if (cover <= 0.0) discard;
	vec3 col = m_grain(mix(behind(ui_px()), tint.rgb, 0.97), 0.03);
	float rule = clamp(min(d + 3.0, -d) + 0.5, 0.0, 1.0);
	float ink = clamp(1.0 - abs(d + 5.0), 0.0, 1.0);
	col = mix(col, m_ink(), ink * 0.35);
	col = mix(col, accent.rgb, rule);
	finalColor = vec4(col, cover * params.y);
}
