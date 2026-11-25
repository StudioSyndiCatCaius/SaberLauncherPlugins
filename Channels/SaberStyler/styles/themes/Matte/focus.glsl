// Matte: a solid 4 px accent outline hugging the focused element, with a hatched copy of its
// shape offset down-right behind it, like a printed sticker. Static.
#include "common.glsl"
#include "matte.glsl"

void main() {
	float d = m_dist();
	float ring = clamp(min(d, 4.0 - d) + 0.5, 0.0, 1.0);
	float d2 = sd_round(ui_local() - vec2(10.0), rect.zw * 0.5 + 2.0, m_rad());
	float back = clamp(0.5 - d2, 0.0, 1.0) * step(4.0, d) * m_hatch(7.0, 0.0) * 0.75;
	finalColor = vec4(glow.rgb, max(ring, back) * params.y);
}
