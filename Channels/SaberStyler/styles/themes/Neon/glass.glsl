// Neon: HUD panes for panel / card / button / bar (default's files include this one).
// Chamfered corners (pill buttons become hexagons), smoked glass with scanlines and a slow
// interference band, a thin accent edge, an inner hairline and bright corner brackets.
// Focus (glow.a) lights the edge and brackets, adds an inner glow and a faint flicker.
#include "common.glsl"
#include "neon.glsl"

vec4 glass_pane() {
	vec2 px = ui_px();
	vec2 l = ui_local();
	vec2 hb = rect.zw * 0.5;
	float cut = neon_cut();
	float d = sd_chamfer(l, hb, cut);
	float cover = clamp(0.5 - d, 0.0, 1.0);
	if (cover <= 0.0) discard;

	// smoked backdrop (light UI themes: frosted white), then the panel colour
	vec3 back = behind(px);
	vec3 col = ui_light() ? mix(back, vec3(1.0), 0.6) : back * 0.25;
	col = mix(col, tint.rgb * (ui_light() ? 1.0 : 0.5), clamp(tint.a * 1.5, 0.0, 1.0));

	// scanlines every 3 px and a band of interference drifting down the pane
	col *= 1.0 - 0.08 * (0.5 + 0.5 * sin(px.y * 2.0944));
	float v = (px.y - rect.y) / max(rect.w, 1.0);
	float band = fract(v - time * 0.12) - 0.5;
	col += accent.rgb * 0.05 * exp(-band * band * 140.0);

	float f = clamp(glow.a * 1.5, 0.0, 1.0);
	vec3 ec = mix(accent.rgb, glow.rgb, f);
	float flick = 1.0 - f * 0.08 * step(0.7, neon_hash(floor(time * 20.0)));

	// glow creeping in from the rim when focused
	col += ec * glow.a * 0.22 * exp(d / 9.0);

	// thin outer edge and a faint hairline 5 px inside it
	float edge = clamp(1.0 - abs(d + 0.8), 0.0, 1.0);
	col = mix(col, ec, edge * (0.40 + 0.50 * f) * flick);
	float inner = clamp(1.0 - abs(d + 5.0), 0.0, 1.0);
	col = mix(col, ec, inner * (0.10 + 0.15 * f));

	// corner brackets: 2.5 px thick along the cut and both edges
	float br = clamp(1.0 - abs(d + 1.9) / 1.4, 0.0, 1.0) * neon_corners(l, hb, cut, 12.0);
	col = mix(col, mix(ec, vec3(1.0), 0.45 * f), br * (0.65 + 0.35 * f) * flick);

	return vec4(col, cover * params.y);
}
