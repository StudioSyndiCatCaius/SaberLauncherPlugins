// Tidepool: slow caustic light rippling over deep teal water (two layers of drifting cell edges).
vec2 hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

// distance between the nearest two moving cell points: 0 on the cell edges
float cells(vec2 p, float t) {
	vec2 g = floor(p), f = fract(p);
	float d1 = 8.0, d2 = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 o = vec2(x, y);
			vec2 h = 0.5 + 0.45 * sin(t + 6.2831 * hash2(g + o));
			float d = length(o + h - f);
			if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
		}
	}
	return d2 - d1;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord / iResolution.xy;
	vec2 p = fragCoord / iResolution.y * 3.5;
	float t = iTime * 0.35;
	p += 0.25 * sin(p.yx * 1.7 + t); // the water surface bends the light

	float a = 1.0 - smoothstep(0.0, 0.22, cells(p, t));
	float b = 1.0 - smoothstep(0.0, 0.18, cells(p * 1.6 + 3.1, t * 1.3));
	float light = pow(a, 3.0) * 0.6 + pow(b, 3.0) * 0.3;

	vec3 deep = mix(vec3(0.0, 0.06, 0.1), vec3(0.0, 0.22, 0.26), uv.y);
	vec3 col = deep + vec3(0.45, 0.85, 0.8) * light;
	col *= 0.7 + 0.3 * smoothstep(1.1, 0.2, length(uv - vec2(0.5, 0.65)));
	fragColor = vec4(col, 1.0);
}
