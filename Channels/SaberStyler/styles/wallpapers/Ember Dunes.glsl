// Ember Dunes: layered dunes under a dusk sky, sparks drifting up.
float hash(float n) { return fract(sin(n) * 43758.5453); }

float noise(float x) {
	float i = floor(x), f = fract(x);
	return mix(hash(i), hash(i + 1.0), f * f * (3.0 - 2.0 * f));
}

float ridge(float x, float seed) {
	return 0.6 * noise(x * 1.3 + seed) + 0.3 * noise(x * 3.1 + seed * 2.0) + 0.1 * noise(x * 7.0 + seed);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord / iResolution.xy;
	float aspect = iResolution.x / iResolution.y;
	float t = iTime;

	vec3 col = mix(vec3(0.95, 0.45, 0.2), vec3(0.12, 0.05, 0.2), pow(uv.y, 0.7));
	vec2 sun = vec2(0.7 * aspect, 0.42);
	float sd = length(vec2(uv.x * aspect, uv.y) - sun);
	col += vec3(1.0, 0.6, 0.3) * (smoothstep(0.08, 0.075, sd) * 0.8 + 0.25 * exp(-sd * 6.0));

	for (int i = 0; i < 4; i++) {
		float fi = float(i);
		float x = uv.x * aspect * (1.0 + fi * 0.4) + t * 0.01 * (fi + 1.0);
		float h = 0.38 - fi * 0.08 + ridge(x, fi * 13.0) * (0.12 + fi * 0.02);
		float depth = fi / 3.0;
		vec3 dune = mix(vec3(0.45, 0.18, 0.2), vec3(0.08, 0.03, 0.06), depth);
		float edge = smoothstep(h + 0.002, h, uv.y);
		dune += vec3(0.6, 0.3, 0.15) * smoothstep(0.03, 0.0, h - uv.y) * (1.0 - depth) * 0.5;
		col = mix(col, dune, edge);
	}

	for (int i = 0; i < 40; i++) {
		float fi = float(i);
		float life = fract(t * (0.05 + 0.04 * hash(fi)) + hash(fi * 7.1));
		vec2 sp = vec2(hash(fi * 3.3) * aspect + sin(t * 0.7 + fi) * 0.03, life * 1.1 - 0.05);
		float d = length(vec2(uv.x * aspect, uv.y) - sp);
		col += vec3(1.0, 0.55, 0.2) * (1.0 - life) * 0.00012 / (d * d + 0.0004);
	}
	fragColor = vec4(col, 1.0);
}
