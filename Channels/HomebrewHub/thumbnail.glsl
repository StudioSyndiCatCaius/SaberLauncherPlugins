// Homebrew Hub thumbnail: a 4-shade Game Boy LCD scene (scrolling parallax hills, clouds, stars)
// with a bobbing cartridge in the middle, rendered at a low pixel resolution and dithered.

const vec3 C0 = vec3(0.059, 0.220, 0.059); // darkest
const vec3 C1 = vec3(0.188, 0.384, 0.188);
const vec3 C2 = vec3(0.545, 0.675, 0.059);
const vec3 C3 = vec3(0.608, 0.737, 0.059); // lightest

float hash(float n) { return fract(sin(n) * 43758.5453); }

float noise(float x) {
	float i = floor(x), f = fract(x);
	return mix(hash(i), hash(i + 1.0), f * f * (3.0 - 2.0 * f));
}

float bayer4(vec2 p) {
	vec2 q = mod(p, 4.0);
	int i = int(q.x) + int(q.y) * 4;
	float m[16] = float[16](0., 8., 2., 10., 12., 4., 14., 6., 3., 11., 1., 9., 15., 7., 13., 5.);
	return (m[i] + 0.5) / 16.0;
}

float box(vec2 p, vec2 b, float r) {
	vec2 d = abs(p) - b + r;
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

// 0 = darkest .. 3 = lightest (fractional values get dithered)
float scene(vec2 px, vec2 res) {
	vec2 uv = px / res;
	float t = iTime;

	// sky: lighter toward the top, with drifting clouds
	float shade = mix(2.2, 3.0, uv.y);
	float cx = px.x + t * 6.0;
	float cl = noise(cx * 0.05 + 3.0) * 0.6 + noise(cx * 0.13) * 0.4;
	if (uv.y > 0.68 && uv.y < 0.68 + cl * 0.18) shade = 3.0;

	// far hills
	float h1 = 0.42 + 0.12 * noise(px.x * 0.035 + t * 0.25) + 0.05 * noise(px.x * 0.11);
	if (uv.y < h1) shade = 2.0;
	// near hills
	float h2 = 0.26 + 0.10 * noise(px.x * 0.06 + t * 0.7 + 10.0);
	if (uv.y < h2) shade = 1.0;
	// ground stripes
	if (uv.y < 0.12) shade = mod(floor((px.x + t * 30.0) / 6.0), 2.0) < 1.0 ? 0.0 : 0.6;

	// cartridge
	vec2 c = px - vec2(res.x * 0.5, res.y * 0.52 + sin(t * 2.0) * 2.0);
	vec2 cs = vec2(res.y * 0.30, res.y * 0.36);
	float body = box(c, cs, 2.0);
	// corner notch (top right) like a DMG cart
	if (c.x > cs.x - 5.0 && c.y > cs.y - 5.0 && (c.x - cs.x + 5.0) + (c.y - cs.y + 5.0) > 5.0) body = 1.0;
	if (body < 0.0) {
		shade = body > -1.5 ? 0.0 : 2.0;
		// ridges on top
		if (c.y > cs.y * 0.72 && abs(c.x) < cs.x * 0.7 && mod(c.x, 3.0) < 1.0) shade = 1.0;
		// label
		vec2 l = c - vec2(0.0, -cs.y * 0.08);
		vec2 ls = vec2(cs.x * 0.78, cs.y * 0.55);
		float lab = box(l, ls, 2.0);
		if (lab < 0.0) {
			shade = lab > -1.0 ? 0.0 : 3.0;
			// little scrolling game inside the label
			vec2 q = l + ls;
			float gh = 3.0 + 3.0 * noise(q.x * 0.3 + t * 3.0);
			if (lab < -1.0 && q.y < gh) shade = 1.0;
			vec2 hero = q - vec2(ls.x * 0.6, gh + 2.0 + abs(sin(t * 4.0)) * 5.0);
			if (lab < -1.0 && abs(hero.x) < 1.6 && abs(hero.y) < 1.6) shade = 0.0;
		}
		// arrow at the bottom
		vec2 a = c - vec2(0.0, -cs.y * 0.82);
		if (a.y < 0.0 && a.y > -3.0 && abs(a.x) < 3.0 + a.y) shade = 0.0;
	}
	// shadow under the cart
	vec2 s = (px - vec2(res.x * 0.5, res.y * 0.08)) / vec2(cs.x * 1.1, 2.5);
	if (dot(s, s) < 1.0) shade = min(shade, 0.0);

	// twinkling sparkles around the cart
	for (int i = 0; i < 6; i++) {
		float fi = float(i);
		vec2 sp = vec2(res.x * (0.12 + 0.76 * hash(fi * 7.1)), res.y * (0.45 + 0.45 * hash(fi * 3.3)));
		float tw = sin(t * 3.0 + fi * 2.1);
		if (tw > 0.3) {
			vec2 d = abs(px - sp);
			if ((d.x < 0.5 && d.y < 2.5) || (d.y < 0.5 && d.x < 2.5)) shade = 3.0;
		}
	}
	return shade;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	float scale = max(2.0, floor(iResolution.y / 90.0));
	vec2 res = floor(iResolution.xy / scale);
	vec2 px = floor(fragCoord / scale);

	float s = scene(px, res);
	float lvl = clamp(floor(s + bayer4(px)), 0.0, 3.0);
	vec3 col = lvl < 0.5 ? C0 : lvl < 1.5 ? C1 : lvl < 2.5 ? C2 : C3;

	// LCD pixel grid + slight vignette
	vec2 cell = fract(fragCoord / scale);
	float grid = (cell.x < 0.12 || cell.y < 0.12) ? 0.9 : 1.0;
	vec2 uv = fragCoord / iResolution.xy - 0.5;
	col *= grid * (1.0 - dot(uv, uv) * 0.5);
	fragColor = vec4(col, 1.0);
}
