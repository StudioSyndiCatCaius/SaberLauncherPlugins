// ModHack: a game cartridge being patched. Code rain behind it, a scan line sweeps down the
// cartridge and recolours the label it has passed (the "hacked" half), with a glitch split now and then.
float box(vec2 p, vec2 b, float r) {
	vec2 d = abs(p) - b + r;
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

// the cartridge as a distance (x offset lets the glitch shift a band of it)
float cart(vec2 p) {
	float body = box(p - vec2(0.0, 0.02), vec2(0.30, 0.36), 0.04);
	// notch cut from the top-right corner
	body = max(body, -box(p - vec2(0.30, 0.38), vec2(0.07, 0.07), 0.0));
	return body;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord / iResolution.xy;
	vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
	float px = 1.5 / iResolution.y;
	float t = iTime;

	// background: deep teal with falling code columns
	vec3 col = mix(vec3(0.02, 0.05, 0.07), vec3(0.03, 0.12, 0.12), uv.y);
	vec2 g = vec2(fragCoord.x / iResolution.y * 28.0, fragCoord.y / iResolution.y * 18.0);
	float column = floor(g.x);
	float speed = 1.5 + 2.5 * hash(vec2(column, 1.0));
	float row = floor(g.y + t * speed);
	float glyph = step(0.55, hash(vec2(column, row)));
	vec2 cell = fract(vec2(g.x, g.y + t * speed));
	glyph *= step(0.2, cell.x) * step(cell.x, 0.8) * step(0.15, cell.y) * step(cell.y, 0.85);
	float trail = fract(-(row) / 14.0 + hash(vec2(column, 7.0)));
	col += vec3(0.1, 0.9, 0.6) * glyph * pow(trail, 3.0) * 0.35;

	// glitch: every few seconds a band of the cartridge slips sideways, RGB split
	float gt = floor(t * 6.0);
	float glitch = step(0.82, hash(vec2(gt, 3.0))) * step(fract(t * 0.25), 0.5);
	float band = step(abs(p.y - (hash(vec2(gt, 9.0)) - 0.5) * 0.6), 0.05);
	float shift = glitch * band * (hash(vec2(gt, 5.0)) - 0.5) * 0.12;

	// patch scan line: sweeps top to bottom, the label below it is still "original"
	float scan = 0.42 - fract(t * 0.18) * 0.9;

	vec3 layer = vec3(0.0);
	float alpha = 0.0;
	for (int c = 0; c < 3; c++) {
		vec2 q = p - vec2(shift * (float(c) - 1.0) * 1.5 + shift, 0.0);
		float d = cart(q);
		// shadow
		col = mix(col, vec3(0.0), (c == 1 ? 0.35 : 0.0) * smoothstep(0.05, 0.0, cart(q + vec2(-0.02, 0.03))));
		float inside = smoothstep(px, 0.0, d);
		vec3 body = vec3(0.16, 0.17, 0.2);
		// grip ridges at the bottom
		float ridges = step(q.y, -0.24) * step(0.5, fract(q.x * 40.0)) * step(abs(q.x), 0.24);
		body *= 1.0 - 0.3 * ridges;
		// the label
		float lab = box(q - vec2(0.0, 0.08), vec2(0.23, 0.2), 0.02);
		float hacked = step(scan, q.y);
		vec3 orig = mix(vec3(0.85, 0.3, 0.25), vec3(0.95, 0.75, 0.3), smoothstep(-0.12, 0.28, q.y));
		vec3 modded = mix(vec3(0.1, 0.85, 0.6), vec3(0.45, 0.4, 1.0), smoothstep(-0.12, 0.28, q.y) + 0.2 * sin(t + q.x * 8.0));
		vec3 labcol = mix(orig, modded, hacked);
		// stripes on the label, like art
		labcol *= 0.85 + 0.15 * step(0.5, fract((q.x + q.y) * 9.0 + (hacked > 0.5 ? t * 0.6 : 0.0)));
		body = mix(body, labcol, smoothstep(px, 0.0, lab));
		// rim light
		body += vec3(0.25) * smoothstep(px * 2.0, 0.0, abs(d + 0.006) - 0.002) * step(0.0, q.y);
		vec3 tint = c == 0 ? vec3(1.0, 0.0, 0.0) : c == 1 ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0);
		layer += body * tint * inside;
		alpha = max(alpha, inside);
	}
	col = mix(col, layer, alpha);

	// the scan line itself, glowing across the cartridge
	float onCart = step(cart(p), 0.02);
	float line = exp(-abs(p.y - scan) * 120.0) * onCart;
	col += vec3(0.3, 1.0, 0.75) * line * 0.9;
	col += vec3(0.1, 0.5, 0.4) * exp(-abs(p.y - scan) * 18.0) * onCart * 0.25;

	// "+" sparks flying off the scan line
	for (int i = 0; i < 4; i++) {
		float fi = float(i);
		float life = fract(t * 0.7 + fi * 0.25);
		vec2 sp = vec2((hash(vec2(fi, floor(t * 0.7 + fi * 0.25))) - 0.5) * 0.55 + life * 0.15 * sign(fi - 1.5), scan + life * 0.2);
		vec2 dq = abs(p - sp);
		float plus = step(min(dq.x, dq.y), 0.004) * step(max(dq.x, dq.y), 0.022);
		col += vec3(0.5, 1.0, 0.8) * plus * (1.0 - life);
	}

	// vignette + faint scanlines
	col *= 1.0 - 0.35 * dot(uv - 0.5, uv - 0.5) * 2.0;
	col *= 0.94 + 0.06 * sin(fragCoord.y * 1.6);
	fragColor = vec4(col, 1.0);
}
