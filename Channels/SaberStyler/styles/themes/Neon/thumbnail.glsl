// Neon theme preview: a chamfered HUD pane with scanlines over a grid horizon, and a breathing reticle.
float chamfer(vec2 p, vec2 b, float c) {
	vec2 q = abs(p) - b;
	float box = max(q.x, q.y);
	return max(box, (abs(p.x) + abs(p.y)) - (b.x + b.y - c));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord / iResolution.xy;
	vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
	float t = iTime;
	vec3 cyan = vec3(0.1, 0.9, 1.0), pink = vec3(1.0, 0.25, 0.75);

	// grid horizon
	vec3 col = mix(vec3(0.01, 0.0, 0.05), vec3(0.08, 0.0, 0.14), uv.y);
	if (p.y < -0.05) {
		float z = 0.12 / (-p.y + 0.001);
		vec2 g = vec2(p.x * z * 4.0, z * 2.0 + t * 0.8);
		vec2 l = abs(fract(g) - 0.5) / fwidth(g);
		float line = 1.0 - min(min(l.x, l.y), 1.0);
		col += pink * line * clamp(-p.y * 4.0, 0.0, 1.0) * 0.8;
	}
	col += pink * 0.25 * exp(-abs(p.y + 0.05) * 30.0);

	// pane
	float d = chamfer(p - vec2(0.0, 0.05), vec2(0.36, 0.2), 0.07);
	if (d < 0.0) {
		col = mix(col, vec3(0.02, 0.05, 0.09), 0.85);
		col += cyan * 0.05 * step(0.5, fract(fragCoord.y * 0.25));
	}
	col += cyan * (smoothstep(0.004, 0.0, abs(d)) + 0.25 * exp(-abs(d) * 60.0));

	// reticle
	vec2 r = p - vec2(0.0, 0.05);
	float s = 0.12 + 0.015 * sin(t * 3.0);
	vec2 a = abs(r);
	float br = max(abs(max(a.x, a.y) - s), -min(a.x, a.y) + s * 0.55);
	col += pink * smoothstep(0.006, 0.0, br);

	fragColor = vec4(col, 1.0);
}
