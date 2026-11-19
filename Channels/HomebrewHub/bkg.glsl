// Homebrew Hub background: a slow-scrolling dot-matrix (handheld LCD) field in dark greens
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord / iResolution.xy;
	float t = iTime;
	vec3 top = vec3(0.114, 0.231, 0.165);
	vec3 bot = vec3(0.043, 0.090, 0.063);
	vec3 col = mix(bot, top, uv.y);

	// LCD dots, drifting slowly
	float cell = 14.0;
	vec2 p = fragCoord + vec2(t * 6.0, t * 3.0);
	vec2 g = fract(p / cell) - 0.5;
	vec2 id = floor(p / cell);
	float wave = 0.5 + 0.5 * sin(id.x * 0.35 + id.y * 0.22 + t * 0.8);
	wave *= 0.5 + 0.5 * sin(length(id - vec2(40.0, 20.0)) * 0.12 - t * 0.6);
	float px = smoothstep(0.32, 0.22, max(abs(g.x), abs(g.y)));
	col += vec3(0.35, 0.65, 0.35) * px * wave * 0.07;

	// soft glow + vignette
	col += vec3(0.25, 0.5, 0.3) * 0.08 * exp(-6.0 * length(uv - vec2(0.75, 0.85)));
	col *= 1.0 - 0.35 * pow(length(uv - 0.5) * 1.3, 2.0);
	fragColor = vec4(col, 1.0);
}
