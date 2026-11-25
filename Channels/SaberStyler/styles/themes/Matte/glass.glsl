// Matte: flat paper panes for panel / card / button / bar (default's files include this one).
// Opaque, grainy, small corners, a 2 px ink border. Focus (glow.a) tints the pane and turns
// the border into a thicker accent line. No refraction, no rim lighting.
#include "common.glsl"
#include "matte.glsl"

vec4 glass_pane() {
	vec2 px = ui_px();
	float d = m_dist();
	float cover = clamp(0.5 - d, 0.0, 1.0);
	if (cover <= 0.0) discard;

	vec3 col = mix(behind(px), tint.rgb, 0.96);
	col = m_grain(col, 0.035);

	float f = clamp(glow.a * 1.6, 0.0, 1.0);
	col = mix(col, glow.rgb, glow.a * 0.18);

	float w = 2.0 + 1.5 * f;
	float border = clamp(min(d + w, -d) + 0.5, 0.0, 1.0);
	col = mix(col, mix(m_ink(), glow.rgb, f), border * mix(0.40, 1.0, f));

	return vec4(col, cover * params.y);
}
