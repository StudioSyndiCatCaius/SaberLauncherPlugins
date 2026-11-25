// Neon: a night horizon. Glowing accent line, a warm haze above it, a perspective grid
// floor scrolling toward the viewer, a striped sun, and twinkling specks in the sky.
#include "common.glsl"

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
	vec2 uv = (ui_px() - rect.xy) / max(rect.zw, vec2(1.0)); // 0..1, y down
	float aspect = rect.z / max(rect.w, 1.0);
	float hz = 0.60;
	vec3 base = tint.rgb;
	vec3 col = base;

	// sky: deepens upward, warm haze near the horizon
	float sky = clamp(1.0 - uv.y / hz, 0.0, 1.0);
	col = mix(col, base * 0.55, sky * 0.6);
	col += warn.rgb * 0.18 * exp(-(hz - uv.y) * 7.0) * step(uv.y, hz);

	// a big soft disc sinking behind the horizon
	vec2 sp = vec2((uv.x - 0.5) * aspect, uv.y - (hz - 0.12));
	float sun = smoothstep(0.24, 0.22, length(sp)) * step(uv.y, hz);
	// solid top half, cut into stripes toward the horizon
	float bands = uv.y < hz - 0.12 ? 1.0 : step(0.35, fract((uv.y - time * 0.01) * 38.0));
	col = mix(col, mix(warn.rgb, accent.rgb, clamp((uv.y - (hz - 0.34)) / 0.34, 0.0, 1.0)), sun * bands * 0.55);

	// horizon line
	col += accent.rgb * (0.55 * exp(-abs(uv.y - hz) * 220.0) + 0.25 * exp(-abs(uv.y - hz) * 22.0));

	// grid floor
	if (uv.y > hz) {
		float y = uv.y - hz;
		float z = 0.10 / y;
		vec2 g = vec2((uv.x - 0.5) * aspect * z * 2.2, z + time * 0.45);
		vec2 cell = abs(fract(g) - 0.5);
		vec2 w = fwidth(g);
		vec2 lines = 1.0 - clamp((0.5 - cell) / max(w * 1.2, vec2(1e-4)), 0.0, 1.0);
		float line = max(lines.x, lines.y);
		float fade = clamp(y * 5.0, 0.0, 1.0) * clamp(1.0 - z * 0.02, 0.0, 1.0);
		col = mix(col, base * 0.6, 0.5);
		col += accent.rgb * line * fade * 0.75;
	}

	// dust
	vec2 cellp = floor(ui_px() / 3.0);
	float star = step(0.9985, hash(cellp));
	col += vec3(star) * 0.5 * sky * (0.5 + 0.5 * sin(time * 2.0 + hash(cellp) * 6.28));

	finalColor = vec4(col, params.y);
}
