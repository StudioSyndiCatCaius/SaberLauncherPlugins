// GOG channel thumbnail: purple glow, drifting glowing boxes, and the word "GOG" drawn with
// distance fields (plain rounded letters, not GOG's logo artwork).

float sd_segment(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a, ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}

// "O": a ring
float letter_o(vec2 p, float r, float th) {
	return abs(length(p) - r) - th;
}

// "G": a ring open at the upper right, plus the bar into the middle
float letter_g(vec2 p, float r, float th) {
	float ang = atan(p.y, p.x);
	float gap0 = 0.0, gap1 = 0.95;
	float ring = abs(length(p) - r) - th;
	if (ang > gap0 && ang < gap1) {
		ring = length(p - r * vec2(cos(gap1), sin(gap1))) - th; // rounded end of the arc
	}
	float bar = sd_segment(p, vec2(r * 0.12, 0.0), vec2(r, 0.0)) - th;
	return min(ring, bar);
}

float word_gog(vec2 p) {
	float r = 0.125, th = 0.034, step = 0.33;
	float d = letter_g(p - vec2(-step, 0.0), r, th);
	d = min(d, letter_o(p, r, th));
	d = min(d, letter_g(p - vec2(step, 0.0), r, th));
	return d;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord / iResolution.xy;
	vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
	float px = 1.5 / iResolution.y;

	vec3 col = mix(vec3(0.07, 0.02, 0.15), vec3(0.32, 0.10, 0.52), uv.y + 0.15 * sin(iTime * 0.5 + uv.x * 3.0));
	for (int i = 0; i < 8; i++) {
		float fi = float(i);
		vec2 c = vec2(fract(fi * 0.37 + iTime * 0.03 * (1.0 + fi * 0.2)) * 2.4 - 1.2, sin(fi * 2.1 + iTime * 0.4) * 0.35);
		vec2 d = abs(p - c) - vec2(0.06 + 0.02 * mod(fi, 3.0));
		float box = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
		col += vec3(0.6, 0.4, 1.0) * 0.012 / (abs(box) + 0.01);
	}
	col *= 1.0 - 0.3 * dot(uv - 0.5, uv - 0.5);

	// the word: soft shadow, purple glow, white letters with a slow shimmer
	vec2 tp = p - vec2(0.0, 0.01 * sin(iTime * 1.3));
	float shadow = word_gog(tp - vec2(0.012, -0.018));
	col = mix(col, vec3(0.03, 0.0, 0.08), smoothstep(0.03, -0.01, shadow) * 0.55);
	float d = word_gog(tp);
	col += vec3(0.75, 0.55, 1.0) * 0.010 / (max(d, 0.0) + 0.012) * 0.6;
	float shimmer = 0.88 + 0.12 * sin(iTime * 2.0 - tp.x * 9.0);
	col = mix(col, vec3(1.0, 0.97, 1.0) * shimmer, smoothstep(px, -px, d));

	fragColor = vec4(col, 1.0);
}
