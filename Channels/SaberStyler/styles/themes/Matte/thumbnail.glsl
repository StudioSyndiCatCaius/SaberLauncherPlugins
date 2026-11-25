// Matte theme preview: dot-grid paper, an inked pane with a hard offset block shadow and a hatched focus.
float box(vec2 p, vec2 b, float r) {
	vec2 d = abs(p) - b + r;
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
	float px = 1.0 / iResolution.y;
	float t = iTime;
	vec3 paper = vec3(0.93, 0.9, 0.84), ink = vec3(0.1, 0.09, 0.08), accent = vec3(0.95, 0.42, 0.25);

	vec3 col = paper - 0.04 * hash(floor(fragCoord));
	vec2 g = fract(p * 18.0) - 0.5;
	col = mix(col, ink, 0.25 * smoothstep(0.09, 0.06, length(g)));

	// flat shapes
	col = mix(col, vec3(0.35, 0.6, 0.85), smoothstep(px, 0.0, length(p - vec2(0.55, 0.28)) - 0.12));
	col = mix(col, vec3(0.98, 0.8, 0.3), smoothstep(px, 0.0, box(p - vec2(-0.6, -0.3), vec2(0.1), 0.0)));

	// pane: block shadow, fill, ink border
	vec2 c = p - vec2(0.0, 0.02);
	float sh = box(c - vec2(0.025, -0.025), vec2(0.34, 0.2), 0.02);
	col = mix(col, ink, smoothstep(px, 0.0, sh));
	float d = box(c, vec2(0.34, 0.2), 0.02);
	col = mix(col, vec3(0.99, 0.97, 0.93), smoothstep(px, 0.0, d));
	col = mix(col, ink, smoothstep(px * 1.5, 0.0, abs(d) - 0.006));

	// a "button" inside with a hatched focus copy behind it
	vec2 b = c - vec2(0.0, -0.08);
	float off = 0.012 + 0.006 * sin(t * 2.0);
	float hb = box(b - vec2(off, -off), vec2(0.18, 0.045), 0.01);
	float hatch = step(0.5, fract((fragCoord.x + fragCoord.y) * 0.15));
	col = mix(col, accent, hatch * smoothstep(px, 0.0, hb));
	float bd = box(b, vec2(0.18, 0.045), 0.01);
	col = mix(col, accent, smoothstep(px, 0.0, bd));
	col = mix(col, ink, smoothstep(px * 1.5, 0.0, abs(bd) - 0.005));
	// a heading bar
	col = mix(col, ink, smoothstep(px, 0.0, box(c - vec2(-0.12, 0.1), vec2(0.18, 0.018), 0.005)));

	fragColor = vec4(col, 1.0);
}
