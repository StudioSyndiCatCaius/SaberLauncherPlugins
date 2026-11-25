// Matte: dot-grid paper with a few big flat shapes (an accent circle, a tilted warn block,
// a hatched stripe) drifting very slowly, plus grain.
#include "common.glsl"
#include "matte.glsl"

void main() {
	vec2 px = ui_px() - rect.xy;
	vec3 base = tint.rgb;
	vec3 col = base;
	float t = time * 0.02;

	// accent circle, upper right
	vec2 c1 = rect.zw * vec2(0.78 + 0.02 * sin(t), 0.30 + 0.02 * cos(t * 0.8));
	float circle = clamp(rect.w * 0.28 - length(px - c1) + 0.5, 0.0, 1.0);
	col = mix(col, mix(base, accent.rgb, 0.30), circle);

	// tilted block, lower left
	vec2 p2 = px - rect.zw * vec2(0.18, 0.78);
	float ang = 0.35 + 0.05 * sin(t * 1.3);
	vec2 q = mat2(cos(ang), -sin(ang), sin(ang), cos(ang)) * p2;
	float block = clamp(0.5 - max(abs(q.x) - rect.w * 0.24, abs(q.y) - rect.w * 0.12), 0.0, 1.0);
	col = mix(col, mix(base, warn.rgb, 0.28), block);

	// hatched diagonal band crossing the middle
	float band = abs((px.x - px.y * 0.6) - rect.z * 0.55);
	col = mix(col, mix(base, m_ink(), 0.10), step(band, 60.0) * m_hatch(14.0, 0.0));

	// dot grid
	vec2 g = mod(px, 28.0) - 14.0;
	float dots = 1.0 - smoothstep(1.2, 2.2, length(g));
	col = mix(col, m_ink(), dots * 0.12);

	finalColor = vec4(m_grain(col, 0.025), params.y);
}
