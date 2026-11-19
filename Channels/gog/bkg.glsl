// GOG background: slow purple aurora bands over a deep violet gradient
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord / iResolution.xy;
	vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
	float t = iTime * 0.15;
	vec3 col = mix(vec3(0.071, 0.024, 0.141), vec3(0.169, 0.055, 0.302), uv.y);

	for (int i = 0; i < 3; i++) {
		float fi = float(i);
		float y = 0.15 * sin(p.x * (1.5 + fi * 0.7) + t * (1.0 + fi * 0.4) + fi * 2.0)
		        + 0.06 * sin(p.x * 4.0 - t * 2.0 + fi) + 0.18 - fi * 0.17;
		float band = exp(-pow((p.y - y) * (9.0 - fi * 2.0), 2.0));
		vec3 tint = mix(vec3(0.55, 0.25, 0.95), vec3(0.85, 0.35, 0.75), fi * 0.5);
		col += tint * band * 0.16;
	}
	// faint stars
	vec2 sc = floor(fragCoord / 3.0);
	float h = fract(sin(dot(sc, vec2(12.9898, 78.233))) * 43758.5453);
	col += step(0.9985, h) * (0.4 + 0.4 * sin(iTime * 2.0 + h * 100.0)) * 0.6;

	col *= 1.0 - 0.3 * pow(length(uv - 0.5) * 1.3, 2.0);
	fragColor = vec4(col, 1.0);
}
