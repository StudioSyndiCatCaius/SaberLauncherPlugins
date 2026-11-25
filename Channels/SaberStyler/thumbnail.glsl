// Saber Styler: a paint swatch fan over a slowly shifting colour wash.
float box(vec2 p, vec2 b, float r) {
	vec2 d = abs(p) - b + r;
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

mat2 rot(float a) { float c = cos(a), s = sin(a); return mat2(c, -s, s, c); }

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord / iResolution.xy;
	vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
	float px = 1.5 / iResolution.y;
	float t = iTime;

	vec3 col = 0.5 + 0.5 * cos(6.2831 * (vec3(0.0, 0.33, 0.67) + uv.x * 0.35 + uv.y * 0.2 + t * 0.04));
	col = mix(vec3(0.06, 0.05, 0.1), col, 0.35);

	// the fan: six swatches around a pivot, opening and closing slowly
	vec2 pivot = vec2(0.0, -0.32);
	float open = 0.55 + 0.12 * sin(t * 0.8);
	for (int i = 0; i < 6; i++) {
		float fi = float(i);
		float a = (fi - 2.5) * open * 0.36;
		vec2 q = rot(a) * (p - pivot) - vec2(0.0, 0.3);
		float d = box(q, vec2(0.075, 0.27), 0.03);
		vec3 sw = 0.55 + 0.45 * cos(6.2831 * (fi / 6.0 + vec3(0.0, 0.33, 0.67) + t * 0.03));
		float shade = 0.85 + 0.15 * smoothstep(-0.27, 0.27, q.y);
		vec3 card = mix(vec3(0.97), sw * shade, step(-0.16, q.y)); // white label strip at the bottom
		col = mix(col, vec3(0.0), 0.25 * smoothstep(0.03, 0.0, d - 0.01)); // soft shadow
		col = mix(col, card, smoothstep(px, 0.0, d));
		col = mix(col, vec3(0.1), 0.35 * smoothstep(px, 0.0, abs(d) - 0.002));
	}
	// rivet
	float r = length(p - pivot - vec2(0.0, 0.08));
	col = mix(col, vec3(0.85, 0.8, 0.7), smoothstep(px, 0.0, r - 0.018));

	// sparkles
	for (int i = 0; i < 5; i++) {
		float fi = float(i);
		vec2 sp = vec2(sin(fi * 2.4 + t * 0.3) * 0.75, 0.3 + 0.12 * sin(fi * 1.3 + t * 0.5));
		vec2 dq = abs(p - sp);
		float star = 0.0004 / (dq.x * dq.y + 0.0002) * exp(-length(dq) * 25.0) * (0.5 + 0.5 * sin(t * 2.0 + fi * 1.7));
		col += vec3(1.0, 0.95, 0.85) * min(star, 1.0) * 0.6;
	}
	fragColor = vec4(col, 1.0);
}
