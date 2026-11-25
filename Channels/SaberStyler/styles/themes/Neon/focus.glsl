// Neon: a targeting reticle. Four corner brackets breathe in and out around the focused
// element, over a soft bloom that follows its chamfered shape.
#include "common.glsl"
#include "neon.glsl"

void main() {
	vec2 l = ui_local();
	vec2 hb = rect.zw * 0.5;
	float cut = neon_cut();

	float gap = 7.0 + 3.0 * sin(time * 4.0);
	vec2 b = hb + gap;
	float c = cut + gap * 0.41;
	float d = sd_chamfer(l, b, c);
	float br = clamp(1.6 - abs(d), 0.0, 1.0) * neon_corners(l, b, c, 14.0);

	float de = sd_chamfer(l, hb, cut);
	float bloom = exp(-max(de, 0.0) / 6.0) * smoothstep(0.0, 1.5, de) * 0.40;
	float line = clamp(1.0 - abs(de - 1.0), 0.0, 1.0) * 0.55;

	float a = max(br, max(bloom, line));
	vec3 col = mix(glow.rgb, vec3(1.0), br * 0.4);
	finalColor = vec4(col, clamp(a, 0.0, 1.0) * params.y);
}
