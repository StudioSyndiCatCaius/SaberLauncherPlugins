// Saber Recomper thumbnail: a pixel grid "compiling" into a glowing chip.
// Saber provides iResolution, iTime, iMouse and rounds the corners.

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord / iResolution.xy;
	vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;

	vec3 col = mix(vec3(0.09, 0.12, 0.23), vec3(0.17, 0.09, 0.28), uv.x);

	// scrolling CHIP-8 style pixels
	vec2 g = floor(fragCoord / (iResolution.y / 18.0));
	float on = step(0.72, hash(g + floor(iTime * 2.0 + g.y * 0.3)));
	vec2 f = fract(fragCoord / (iResolution.y / 18.0));
	float cell = step(0.12, f.x) * step(0.12, f.y);
	col += vec3(0.25, 0.45, 0.9) * on * cell * 0.35 * (1.0 - smoothstep(0.0, 0.45, abs(p.x)) * 0.6);

	// chip
	vec2 d = abs(p) - vec2(0.2, 0.2);
	float box = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
	float chip = smoothstep(0.01, 0.0, box);
	col = mix(col, vec3(0.08, 0.1, 0.18), chip);
	float edge = smoothstep(0.012, 0.0, abs(box));
	col += vec3(0.45, 0.7, 1.0) * edge * (0.8 + 0.2 * sin(iTime * 3.0));
	// pins
	vec2 q = abs(p);
	float pins = step(q.y, 0.17) * step(0.2, q.x) * step(q.x, 0.27) * step(0.5, fract(p.y * 18.0 + 0.25));
	pins += step(q.x, 0.17) * step(0.2, q.y) * step(q.y, 0.27) * step(0.5, fract(p.x * 18.0 + 0.25));
	col = mix(col, vec3(0.7, 0.78, 0.9), clamp(pins, 0.0, 1.0) * 0.8);
	// glow
	col += vec3(0.3, 0.5, 1.0) * 0.04 / (abs(box) + 0.05) * (0.6 + 0.4 * sin(iTime * 1.5));

	fragColor = vec4(col, 1.0);
}
