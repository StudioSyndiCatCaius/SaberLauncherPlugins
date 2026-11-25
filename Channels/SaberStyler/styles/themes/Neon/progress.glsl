// Neon: a segmented LED meter. Lit segments run from the fill colour toward the warn colour
// with a hot core; unknown progress (params.w < 0) is a block of 4 lit segments sweeping
// back and forth. tint = fill, glow = track.
#include "common.glsl"
#include "neon.glsl"

void main() {
	vec2 px = ui_px();
	vec2 l = ui_local();
	vec2 hb = rect.zw * 0.5;
	float d = sd_chamfer(l, hb, min(hb.y, 3.0));
	float cover = clamp(0.5 - d, 0.0, 1.0);
	if (cover <= 0.0) discard;

	float seg = 7.0;
	float gap = 2.0;
	float x = px.x - rect.x;
	float idx = floor(x / seg);
	float n = max(floor(rect.z / seg), 1.0);
	float inside = step(x - idx * seg, seg - gap);

	float f = params.w;
	float lit;
	if (f < 0.0) {
		float pos = floor((0.5 + 0.5 * sin(time * 2.6)) * (n - 4.0));
		lit = step(pos, idx) * step(idx, pos + 3.0);
	} else {
		lit = step(idx + 0.5, clamp(f, 0.0, 1.0) * n);
	}

	float u = idx / n;
	vec3 on = mix(tint.rgb, warn.rgb, u * 0.7);
	on = mix(on, vec3(1.0), (1.0 - abs(l.y) / max(hb.y, 1.0)) * 0.35);
	vec3 off = ui_light() ? vec3(0.74, 0.76, 0.80) : tint.rgb * 0.14;
	vec3 col = mix(off, on, lit);
	float a = inside * mix(0.85, tint.a, lit);
	finalColor = vec4(col, a * cover * params.y);
}
